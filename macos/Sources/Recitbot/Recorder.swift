import AVFoundation
import CoreGraphics
import CoreMedia
import RecitbotCore
import ScreenCaptureKit

/// Camera / microphone permission (TCC). Asked at most once, when a recording first needs it (Windows has no such
/// gate); waits up to 30 s for the answer.
enum Permissions {
    static func allowed(_ type: AVMediaType) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined:
            let done = Event(), ok = Box<Bool>()
            AVCaptureDevice.requestAccess(for: type) { g in ok.value = g; done.set() }
            done.wait(30)
            return ok.value == true
        default: return false
        }
    }
}

/// One recording at a time: control pill first, then the screen capture, then the upload. A window recording that
/// moves to another monitor continues there (the same stream switches displays: one segment, nothing to join).
/// parity: AgentRecorder.cs Recorder (wes-8b83b0f: start timing, mic start trim, late-audio delay).
final class Recorder: RecorderControl, @unchecked Sendable {
    let agent: RecorderHost
    private let gate = NSLock()
    private var segment: ScreenSegment?
    private var micCap: MicCapture?
    private var pill: RecordingPill?
    private var bubble: WebcamBubble?
    private var currentId: String?
    /// Bumped by closeBubble: a bubble still opening for an earlier recording closes itself instead of showing.
    private var bubbleGen = 0
    private var stopRequested = false
    private var sys: SystemAudio?
    private var micMutes: MuteLog?
    private var follower: WindowFollower?
    private var recMonitor: MonitorInfo?
    /// The control pill (ControlPill on the main thread, driven through PillHost).
    var makePill: () -> RecordingPill = { PillHost() }
    /// Fired once the capture is running (the dev CLI times its scripted toggles from here).
    var onRecording: (@Sendable () -> Void)?
    /// Fired when a recording's "start timing" line is logged (the start-latency test reads it).
    var onTimed: (@Sendable (StartTimes) -> Void)?
    /// Fired once a recording is over: uploaded (or failed), its files gone and busy false again. The agent runs a
    /// deferred update from here (SelfUpdater.runDeferred). parity: AgentRecorder.cs Recorder.Finished
    var onFinished: (@Sendable () -> Void)?

    init(host: RecorderHost) { agent = host }

    /// Longest recording any account may ask for: 4 h (the Worker holds each account to its own limit; its
    /// max_seconds still governs). parity: AgentRecorder.cs Recorder.MaxSeconds
    static let maxSeconds = RecordingLength.maxSeconds

    /// The video's size cap (less room for the AAC track): Free, up to 300 s, gets 250 MiB; with the chunked upload,
    /// longer recordings get up to 8 GiB (4 h). No part size: 250 MiB. parity: AgentRecorder.cs Recorder.VideoCap
    static func videoCap(_ partBytes: Int64, _ maxSeconds: Int, _ hasAudio: Bool) -> Int64 {
        return VideoCap.bytes(partBytes, maxSeconds, hasAudio)
    }

    var busy: Bool { gate.lock(); defer { gate.unlock() }; return currentId != nil }
    var current: String? { gate.lock(); defer { gate.unlock() }; return currentId }

    /// received = when the start command arrived (Clock.now), the zero of the start timing.
    func start(id: String?, maxSeconds: Int, opts: StartOpts, uploadToken: String?, received: Double) {
        let times = StartTimes(received.isNaN ? Clock.now() : received)
        gate.lock()
        if currentId != nil { gate.unlock(); agent.sendStatus(id, "failed", "BUSY"); return }
        currentId = id ?? ""
        gate.unlock()
        times.onLogged = { [weak self] t in self?.onTimed?(t) }
        let t = Thread { self.run(id ?? "", RecordingLength.clamp(maxSeconds), opts, uploadToken, times) }
        t.name = "recording"
        t.start()
    }

    func stop(id: String?) {
        gate.lock()
        if (id ?? "") != currentId { gate.unlock(); return }
        stopRequested = true
        let s = segment
        gate.unlock()
        s?.requestStop()
    }

    /// The recorded window is now mostly on another monitor: the same stream continues there (unless a stop is under way).
    private func switchMonitor(_ m: MonitorInfo) {
        gate.lock()
        if stopRequested || currentId == nil { gate.unlock(); return }
        let s = segment, f = follower, keep = keepWindows()
        gate.unlock()
        guard let seg = s, let fol = f else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let filter = CaptureFilter.refreshed(m.displayID, keep: keep) else {
                Log.write("window: monitor " + String(m.index) + " is not capturable; the video stays black there")
                return
            }
            let view = fol.viewOn(m)
            seg.apply(filter)
            seg.apply(view)
            self.gate.lock(); self.recMonitor = m; self.gate.unlock()
            fol.attach(seg, m, view)
            Log.write("window: moved to monitor " + String(m.index) + " (" + m.label + "); recording continues there")
        }
    }

    /// A toggle on the pill (or toggle below): mute/unmute one source without stopping. System audio is zeroed by the
    /// capture itself from this instant; the mic is zeroed live too and its spans again exactly when the audio is mixed.
    private func setMute(_ source: String, _ muted: Bool) {
        let now = Clock.now()
        gate.lock()
        let s = sys, m = micMutes, mc = micCap
        gate.unlock()
        if source == Toggles.sys { s?.setMuted(muted); return }
        guard let ml = m, ml.set(muted, now) else { return }
        mc?.setMuted(muted)
    }

    /// Presses a pill toggle through the pill itself (same code path as a click). Used by --record-local --toggle.
    func toggle(_ source: String) {
        gate.lock()
        let p = pill
        gate.unlock()
        p?.toggle(source)
    }

    private func setPillSources(_ mic: Bool, _ system: Bool) {
        gate.lock()
        let p = pill
        gate.unlock()
        p?.setSources(mic: mic, system: system)
    }

    private static func startSystemAudio(_ path: String) -> SystemAudio? {
        let c = SystemAudio(path: path)
        do {
            try c.start()
            return c
        } catch {
            Log.write("system audio: not recorded (" + Agent.message(error) + ")")
            return nil
        }
    }

    /// The bubble's window: the one window of this app the capture keeps (under gate).
    private func keepWindows() -> [Int] {
        guard let b = bubble else { return [] }
        let n = b.windowNumber
        return n > 0 ? [n] : []
    }

    private func run(_ id: String, _ maxSeconds: Int, _ o: StartOpts, _ uploadToken: String?, _ times: StartTimes) {
        let dir = agent.workDir
        let video = (dir as NSString).appendingPathComponent(id + ".mp4"), audio = (dir as NSString).appendingPathComponent(id + ".wav")
        var temps: [String] = []
        var fol: WindowFollower?
        var system: SystemAudio?
        var mic: MicCapture?
        let screenUp = Event() // the capture has its first frame (or failed): the camera may open
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // macOS: nothing can be recorded without Screen Recording. The agent never gets here without it (a start
            // waits in ScreenWait until it is on); the dev CLI fails.
            if !MacCatalog.screenAllowed() { throw CaptureError(ScreenOnboarding.deniedError) }
            let catalog = agent.mac
            let monitors = catalog.monitors()
            var win: WindowInfo?
            let mon: MonitorInfo
            if let wq = o.window {
                // Only a window from this Mac's own live list is recorded (found again by its id). If it is gone, fail
                // instead of recording a whole monitor the user did not ask for.
                guard let w = DeviceMatch.window(catalog.windows(monitors), wq) else { throw CaptureError("WINDOW_NOT_FOUND") }
                Log.write("window " + w.id + " (" + w.app + "): " + catalog.bringToFront(w))
                let st = catalog.probe(w)
                if !st.alive { throw CaptureError("WINDOW_NOT_FOUND") }
                w.bounds = st.bounds
                guard let m = WindowTrack.mostlyOn(monitors, w.bounds) else { throw CaptureError("WINDOW_OFF_SCREEN") }
                win = w
                mon = m
            } else {
                var m = DeviceMatch.monitor(monitors, o.monitor)
                if m == nil {
                    m = DeviceMatch.monitor(monitors, "primary")
                    Log.write("monitor \"" + (o.monitor ?? "") + "\" is not in the inventory; recording the primary")
                }
                guard let mm = m else { throw CaptureError("NO_MONITOR") }
                mon = mm
            }
            gate.lock(); recMonitor = mon; gate.unlock()
            try showPill(mon, monitors)
            Log.write("pill shown")
            times.mark("t_pill")
            let encoder = "h264_videotoolbox"
            times.mark("t_encoder")
            let av = o.mic || o.cam.on ? catalog.cachedAudioVideo() : nil
            // The camera takes 1-2 s to open, so it opens on its own thread and the screen capture does not wait: the
            // bubble is in the video from the moment it appears. It is optional: any camera problem is logged and the
            // recording goes on without it.
            if o.cam.on, let av = av {
                times.expectBubble()
                startBubble(av.cameras, o.cam, mon, win.map { IRect.intersect($0.bounds, mon.bounds) }, times, screenUp)
            }
            var micDev: AvDevice?
            if o.mic, let av = av {
                if let q = o.micDevice {
                    micDev = DeviceMatch.av(av.mics, q)
                    if micDev == nil { Log.write("mic \"" + q + "\" is not in the inventory; using the default") }
                }
                if micDev == nil { micDev = av.mics.first { $0.isDefault } ?? av.mics.first }
                if micDev == nil { Log.write("mic requested but no audio input device found") }
                if micDev != nil && !Permissions.allowed(.audio) {
                    Log.write("mic requested but Microphone permission is off for Recitbot; recording without it")
                    micDev = nil
                }
            }
            // System audio starts before the screen capture so its WAV can cover the video's first frame (it delivers
            // nothing until something plays: the mix then delays it).
            if o.systemAudio {
                system = Recorder.startSystemAudio((dir as NSString).appendingPathComponent(id + ".sys.wav"))
                if let s = system { temps.append(s.pathName) }
            }
            let mutes = MuteLog()
            // The mic starts with the screen and covers the whole recording. The screen does not wait for it: a mic can
            // take ~1 s to deliver its first packet, and the mix cuts the video's head off up to the mic's first sample
            // (AudioMath.startTrim). Checked once the screen is up.
            let micWav = (dir as NSString).appendingPathComponent(id + ".mic.wav")
            let micLaunched = Clock.now()
            if let d = micDev {
                temps.append(micWav)
                do {
                    guard let dev = MacCatalog.device(d) else { throw CaptureError("device gone") }
                    let m = try MicCapture(device: dev, path: micWav)
                    m.start()
                    mic = m
                } catch {
                    Log.write("mic " + d.name + " failed to start (" + Agent.message(error) + "); recording without it")
                }
            }
            gate.lock(); sys = system; micMutes = mic != nil ? mutes : nil; micCap = mic; gate.unlock()
            setPillSources(mic != nil, system != nil)

            let content = try MacCatalog.shareable(onScreenOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == mon.displayID }) else { throw CaptureError("NO_MONITOR") }
            gate.lock(); let keep = keepWindows(); gate.unlock()
            var spec = CaptureSpec(monitor: mon, display: display, filter: CaptureFilter.make(display, content, keep: keep))
            spec.fps = agent.cfg.fps
            let src = mon.pixelSize
            let scale = Double(mon.dpi) / 96
            if let w = win {
                var view = WindowTrack.view(w.bounds, false, true, mon.bounds, WindowView())
                // Even size: a window that fits 1920x1080 is then recorded 1:1 (no pad, no resampling).
                view.crop.width &= ~1
                view.crop.height &= ~1
                spec.region = view
                spec.output = WindowTrack.outputSize(ISize(Int(Double(view.crop.width) * scale) & ~1, Int(Double(view.crop.height) * scale) & ~1))
                let f = WindowFollower(catalog: catalog, win: w, monitors: monitors)
                f.onMonitorChanged = { [weak self] m in self?.switchMonitor(m) }
                f.onClosed = { [weak self] in if let cur = self?.current { self?.stop(id: cur) } }
                f.onMoved = { [weak self] from, to in
                    guard let self = self else { return }
                    self.gate.lock(); let bb = self.bubble; self.gate.unlock()
                    if let b = bb { onMainAsync { b.followWindow(from, to) } }
                }
                fol = f
                gate.lock(); follower = f; gate.unlock()
                f.start()
                let c = view.crop
                E2e.write("window-capture.json", "{\"monitor_x\":\(mon.bounds.x),\"monitor_y\":\(mon.bounds.y),\"crop_x\":\(c.x),\"crop_y\":\(c.y),"
                          + "\"crop_w\":\(c.width),\"crop_h\":\(c.height),\"out_w\":\(spec.output.width),\"out_h\":\(spec.output.height)}")
            } else {
                spec.output = WindowTrack.outputSize(src)
            }
            let clock = Clock.now()
            var recorded = 0.0
            let cap = Recorder.videoCap(o.partBytes, maxSeconds, mic != nil || system != nil)
            var videos: [String] = []
            var segs: [Segment] = []
            var keyframes: [(Double, CMTime)] = []
            spec.maxSeconds = maxSeconds
            spec.maxBytes = cap
            spec.video = (dir as NSString).appendingPathComponent(id + ".s0.mp4")
            temps.append(spec.video)
            times.mark("t_ffmpeg_launch")
            let seg: ScreenSegment
            do {
                seg = try ScreenSegment(spec: spec, system: system)
                seg.onFirstFrame = { times.mark("t_first_frame"); screenUp.set() }
                try seg.start()
            } catch {
                Log.write("capture failed (" + Agent.message(error) + ")")
                throw CaptureError("CAPTURE_FAILED")
            }
            gate.lock()
            segment = seg
            let stopNow = stopRequested
            gate.unlock()
            if stopNow { seg.requestStop() } // Stop arrived while the capture was starting
            if let f = fol, let r = spec.region { f.attach(seg, mon, r) }
            // The first frame, at most 2 s (FailedEarly).
            _ = seg.firstFrame.wait(2)
            let b = mon.bounds
            var region = ""
            if let r = spec.region {
                let c = r.crop
                region = ", window crop \(c.width)x\(c.height)+\(c.x)+\(c.y) -> \(spec.output.width)x\(spec.output.height)"
            }
            Log.write("video path: screencapturekit (\(src.width)x\(src.height) -> \(spec.output.width)x\(spec.output.height))")
            Log.write("capture started (screencapturekit display \(mon.displayID) \(b.width)x\(b.height)+\(b.x)+\(b.y), " + encoder
                      + ", monitor \(mon.index) " + mon.label + region + ")")
            let cr = spec.region?.crop ?? IRect(0, 0, b.width, b.height)
            E2e.write("capture.json", "{\"monitor_x\":\(b.x),\"monitor_y\":\(b.y),\"monitor_w\":\(b.width),\"monitor_h\":\(b.height),\"crop_x\":\(cr.x),"
                      + "\"crop_y\":\(cr.y),\"crop_w\":\(cr.width),\"crop_h\":\(cr.height),\"fast\":true,\"encoder\":" + Json.esc(encoder)
                      + ",\"path\":\"screencapturekit\"}")
            screenUp.set()
            times.mark("t_started")
            agent.sendStatus(id, "recording", nil)
            if let r = onRecording { DispatchQueue.global().async { r() } }
            if let m = mic, let d = micDev, !Recorder.micRunning(d, m, micLaunched) {
                m.stop()
                mic = nil
                gate.lock(); micCap = nil; micMutes = nil; gate.unlock()
                setPillSources(false, system != nil)
            }
            seg.waitForExit()
            recorded = Clock.now() - clock
            gate.lock(); segment = nil; gate.unlock()
            fol?.detach()
            if let e = seg.failed { Log.write("capture ended: " + e) }
            let size = Recorder.fileSize(spec.video)
            if size >= 1024 {
                videos.append(spec.video)
                keyframes = seg.encoder.keyframes
                if seg.valid {
                    segs.append(Segment(seg.t0, seg.last))
                    Log.write("timing: segment 0 t0 " + NetFormat.fixed(seg.t0, 3) + ", lag start/end 0/0 ms, out_time " + NetFormat.fixed(seg.last, 3)
                              + " s, " + String(size) + " bytes")
                } else {
                    segs.append(Segment(seg.launched, (seg.exitedAt.isNaN ? Clock.now() : seg.exitedAt) - seg.launched)) // segClock
                    Log.write("no ffmpeg progress for segment 0; audio timing estimated from the launch")
                }
            }
            fol?.stop()
            system?.stop()
            gate.lock(); micCap = nil; gate.unlock()
            mic?.stop()
            let micSpans = mutes.allSpans()
            closePill()
            if videos.isEmpty { throw CaptureError("CAPTURE_FAILED") }
            let hasMic = mic != nil && Recorder.fileSize(micWav) > 1024, hasSys = system != nil && system!.seconds > 0
            let untrimmed = AudioMath.length(segs)
            if !hasMic && !hasSys {
                try join(videos, video)
            } else {
                let silentVideo = (dir as NSString).appendingPathComponent(id + ".v.mp4")
                temps.append(silentVideo)
                try join(videos, silentVideo)
                if hasMic && !(mic?.valid ?? false) { Log.write("no ffmpeg progress for the mic; its timing estimated from the launch") }
                // The WAV's own length (its samples at 48 kHz mono s16) against the mic's: a mic whose clock runs off
                // 48 kHz shows here as a difference that grows with the recording's length.
                if hasMic, let m = mic, m.valid {
                    Log.write("timing: mic " + m.describe() + ", samples " + NetFormat.fixed(Double(Recorder.fileSize(micWav) - 44) / 96000.0, 3) + " s")
                }
                let micStart = (mic?.valid ?? false) ? mic!.t0 : micLaunched
                // The video does not open before the mic: when the mic's first sample came after the first frame, the
                // video's head is cut off at the first keyframe after it (the encoder forces one every ~100 ms early on),
                // at most AudioMath.maxTrim. System audio never trims: the mix delays it instead.
                let micAt = hasMic ? micStart : Double.nan
                let late = micAt - segs[0].wallStart
                var trim = 0.0
                if late > 0 {
                    let keys = keyframes.filter { $0.0 <= AudioMath.maxTrim + 0.5 }.map { $0.0 }
                    let r = AudioMath.startTrim(segs[0].wallStart, micAt, keys)
                    trim = r.trim
                    if trim >= AudioMath.length(segs) { trim = 0 } // a recording shorter than the trim keeps its frames
                    Log.write(r.capped
                        ? "timing: mic late " + NetFormat.fixed(late * 1000, 0) + " ms, capped; video starts at its keyframe at " + NetFormat.fixed(trim * 1000, 0)
                            + " ms, mic delayed " + NetFormat.fixed((late - trim) * 1000, 0) + " ms"
                        : "timing: mic starts " + NetFormat.fixed(late * 1000, 0) + " ms after the first frame; video starts at its keyframe at "
                            + NetFormat.fixed(trim * 1000, 0) + " ms")
                }
                let trimTime = trim > 0 ? (keyframes.first { $0.0 == trim }?.1 ?? CMTime(seconds: trim, preferredTimescale: 600_000)) : CMTime.zero
                segs = AudioMath.trimStart(segs, trim)
                if hasSys, let s = system, s.startTime > segs[0].wallStart {
                    Log.write("timing: system audio starts " + NetFormat.fixed((s.startTime - segs[0].wallStart) * 1000, 0) + " ms after the video; delayed")
                }
                try mixAudio(silentVideo, untrimmed, trimTime, hasMic ? micWav : nil, micStart, hasSys ? system : nil, micSpans, segs, video, audio)
                // The transcription WAV (16 kHz mono s16) is on the trimmed timeline: as long as the stored duration.
                if FileManager.default.fileExists(atPath: audio) {
                    Log.write("timing: trimmed length " + NetFormat.fixed(AudioMath.length(segs), 3) + " s, transcription WAV "
                              + NetFormat.fixed(Double(Recorder.fileSize(audio) - 44) / 32000.0, 3) + " s")
                }
            }
            agent.sendStatus(id, "uploading", nil)
            // Video length from the capture's own timestamps (the clock also counts the stream's start-up).
            let length = AudioMath.length(segs)
            // The transcription WAV exists only with a mic (transcripts are mic-only); system audio alone is in the video.
            try agent.deliver(id: id, video: video, audio: audio, hasTranscript: hasMic, hasSystemAudio: hasSys, token: uploadToken,
                              duration: min(length > 0 ? length : recorded, Double(maxSeconds)), partBytes: o.partBytes)
        } catch {
            let message = Agent.message(error)
            Log.write("recording failed: " + message)
            agent.sendStatus(id, "failed", String(message.utf16.count > 100 ? String(decoding: Array(message.utf16)[0..<100], as: UTF16.self) : message))
        }
        // finally
        fol?.stop()
        system?.stop()
        mic?.stop()
        gate.lock(); let s = segment; gate.unlock()
        if let s = s { s.requestStop(); s.waitForExit() }
        closePill()
        // Raw mic/system WAVs (temps) and the mixed files never outlive the recording.
        for f in [video, audio] + temps { try? FileManager.default.removeItem(atPath: f) }
        gate.lock()
        currentId = nil; segment = nil; micCap = nil; stopRequested = false; sys = nil; micMutes = nil; follower = nil; recMonitor = nil
        gate.unlock()
        times.flush()
        onFinished?()
    }

    /// Mixes mic and system audio into the video's single AAC track (and, with a mic, the mic-only transcription WAV).
    /// The mic's muted spans are silenced exactly (100 ms early, 50 ms late, on top of the live mute); the system WAV is
    /// already zero there.
    private func mixAudio(_ silentVideo: String, _ videoSeconds: Double, _ trim: CMTime, _ micWav: String?, _ micStart: Double, _ system: SystemAudio?,
                          _ micMuted: [Span], _ segs: [Segment], _ video: String, _ audio: String) throws {
        let spans = AudioMath.toTimeline(micMuted, segs, 0.1, 0.05)
        let micSlices = micWav != nil ? AudioMath.slices(segs, micStart) : nil
        let slices = system.map { AudioMath.slices(segs, $0.startTime) }
        let plan = MixPlan(micMuted: spans, micSlices: micSlices.map { AudioMath.sliceOps($0) }, sysSlices: slices.map { AudioMath.sliceOps($0) })
        let started = Clock.now()
        try AudioMux.run(video: silentVideo, videoSeconds: videoSeconds, trim: trim, plan: plan, micWav: micWav, sysWav: system?.pathName,
                         outVideo: video, outWav: audio)
        Log.write("audio mixed in " + String(Int64((Clock.now() - started) * 1000)) + " ms ("
                  + (micSlices != nil ? "mic, offset " + NetFormat.fixed(micSlices![0].start, 3) + " s" : "")
                  + (micSlices != nil && slices != nil ? " + " : "")
                  + (slices != nil ? "system audio, offset " + NetFormat.fixed(slices![0].start, 3) + " s" : "") + ", mic muted spans " + String(spans.count) + ")")
        if E2e.on {
            // Where the mutes landed in the video (seconds), for the e2e level checks. No ffmpeg filter on macOS.
            let sysWall = system.map { s in s.mutes.allSpans().map { Span($0.start + s.startTime, $0.end + s.startTime) } } ?? []
            let sysSpans = AudioMath.toTimeline(sysWall, segs, 0, 0)
            let micExact = AudioMath.toTimeline(micMuted, segs, 0, 0)
            E2e.write("audio-mix.json", "{\"filter\":\"\",\"mic_muted\":" + Json.esc(micExact.map { $0.description }.joined(separator: ","))
                      + ",\"sys_muted\":" + Json.esc(sysSpans.map { $0.description }.joined(separator: ","))
                      + ",\"sys_device\":" + Json.esc(system != nil ? "system output" : "") + ",\"sys_format\":" + Json.esc(system != nil ? "48000 Hz, 2 ch" : "")
                      + ",\"sys_switches\":0,\"sys_losses\":0}")
        }
    }

    /// Waits until the mic delivers (its first packet), at most 2 s after its launch. False when it failed instead (the
    /// recording goes on without it).
    private static func micRunning(_ d: AvDevice, _ m: MicCapture, _ launched: Double) -> Bool {
        while !m.valid && m.failed == nil && Clock.now() - launched < 2 { usleep(50_000) }
        if let f = m.failed {
            Log.write("mic " + d.name + " failed to start (" + f + "); recording without it")
            return false
        }
        Log.write("mic " + d.name + " started (own session, " + (m.valid ? "first audio " + String(Int64(NetFormat.round((m.t0 - launched) * 1000)))
            + " ms after its launch" : "no audio yet") + ")")
        return true
    }

    static func fileSize(_ path: String) -> Int64 {
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// One segment on macOS (a monitor switch keeps the same stream), so joining is a rename.
    private func join(_ parts: [String], _ output: String) throws {
        try? FileManager.default.removeItem(atPath: output)
        try FileManager.default.moveItem(atPath: parts[0], toPath: output)
    }

    // MARK: pill

    /// The pill goes on the recorded monitor (for a window, the monitor holding most of it).
    private func showPill(_ mon: MonitorInfo, _ monitors: [MonitorInfo]) throws {
        let p = makePill()
        let shown = p.show(monitor: mon, monitors: monitors, cfg: agent.cfg, onStop: { [weak self] in
            guard let self = self, let id = self.current else { return }
            DispatchQueue.global().async { self.stop(id: id) }
        }, onMute: { [weak self] source, muted in self?.setMute(source, muted) })
        if !shown { throw CaptureError("PILL_FAILED") }
        gate.lock(); pill = p; gate.unlock()
    }

    /// Closes the pill (and the bubble) however the recording ended: Stop on the pill, stop_recording, max length, a
    /// closed window or a failure. run calls it on every path.
    private func closePill() {
        closeBubble()
        gate.lock()
        let p = pill
        pill = nil
        gate.unlock()
        p?.close()
    }

    // MARK: bubble

    /// Opens the camera and shows the bubble on a thread of its own; marks t_bubble (or settles it) when done. The camera
    /// opens once screenUp is set (the capture has its first frame, or gave up) or after 3 s.
    private func startBubble(_ cameras: [AvDevice], _ cam: WebcamOpts, _ mon: MonitorInfo, _ inside: IRect?, _ times: StartTimes, _ screenUp: Event) {
        gate.lock(); let gen = bubbleGen; gate.unlock()
        let t = Thread {
            var waited = 0
            while waited < 3000 && !screenUp.wait(0.05) {
                self.gate.lock(); let stale = gen != self.bubbleGen; self.gate.unlock()
                if stale { times.bubbleSettled(); return }
                waited += 50
            }
            if self.showBubble(cameras, cam, mon, inside, gen) { times.mark("t_bubble") } else { times.bubbleSettled() }
        }
        t.name = "bubble"
        t.start()
    }

    /// Shows the webcam bubble on the recorded monitor and waits until it is on screen. Returns false when it was not
    /// shown; a bubble whose recording ended meanwhile (bubbleGen moved on) is closed instead.
    private func showBubble(_ cameras: [AvDevice], _ cam: WebcamOpts, _ mon: MonitorInfo, _ inside: IRect?, _ gen: Int) -> Bool {
        if cameras.isEmpty { Log.write("webcam: no camera found; recording without the bubble"); return false }
        let want = cam.camera != nil ? DeviceMatch.av(cameras, cam.camera) : nil
        let dev = want ?? DeviceMatch.av(cameras, agent.cfg.camera) ?? cameras[0]
        if cam.camera != nil && want == nil { Log.write("webcam: camera \"" + cam.camera! + "\" is not in the inventory, using " + dev.name) }
        if !Permissions.allowed(.video) { Log.write("webcam: Camera permission is off for Recitbot; recording without the bubble"); return false }
        // Per-recording shape/size from start_recording, else what was last chosen on this Mac.
        let rect = (cam.shape ?? agent.cfg.shape) == "rect"
        let px = cam.pct > 0 ? WebcamSize.pxForPercent(cam.pct, mon.bounds.size, 96, rect) : cam.px > 0 ? cam.px : agent.cfg.webcamPx
        gate.lock()
        if gen != bubbleGen { gate.unlock(); return false }
        gate.unlock()
        let cfg = agent.cfg
        let homeBounds = mon.bounds, homeWork = mon.workArea
        let b: WebcamBubble = onMain {
            let b = WebcamBubble(cfg: cfg, cameras: cameras, camera: dev, px: px, rect: rect, homeBounds: homeBounds, homeWork: homeWork, inside: inside)
            b.startCamera()
            return b
        }
        gate.lock()
        let current = gen == bubbleGen
        if current { bubble = b }
        gate.unlock()
        if !current { closeOwnBubble(b); return false }
        var got = 0 // 0 = waiting, 1 = shown, 2 = failed
        var waited = 0
        while waited < 8000 && got == 0 {
            gate.lock(); let stale = gen != bubbleGen; gate.unlock()
            if stale { return false } // the recording ended; closeBubble closed it
            if b.shownEvent.wait(0.1) { got = 1 } else if b.failedEvent.signaled { got = 2 }
            waited += 100
        }
        if got != 1 {
            let why = b.lastError.value
            Log.write("webcam: bubble not shown (" + (why.isEmpty ? "camera timeout" : why) + "); recording without it")
            closeOwnBubble(b)
            return false
        }
        Log.write("webcam bubble shown (" + dev.name + ", " + String(px) + " px, " + (rect ? "rect" : "circle") + ", mirror "
                  + (agent.cfg.mirror ? "on" : "off") + ")")
        // Into the video: the capture filter keeps this window from now on.
        gate.lock()
        let seg = segment, m = recMonitor, keep = keepWindows()
        gate.unlock()
        if let s = seg, let m = m, let f = CaptureFilter.refreshed(m.displayID, keep: keep) { s.apply(f) }
        return true
    }

    private func closeBubble() {
        gate.lock()
        let b = bubble
        bubble = nil
        bubbleGen += 1
        gate.unlock()
        if let b = b { onMainAsync { b.shutdown() } }
    }

    /// Closes this bubble only (a later recording may already have its own).
    private func closeOwnBubble(_ b: WebcamBubble) {
        gate.lock()
        if bubble === b { bubble = nil }
        gate.unlock()
        onMainAsync { b.shutdown() }
    }
}
