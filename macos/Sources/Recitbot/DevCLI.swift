import AppKit
import AVFoundation
import RecitbotCore

/// The dev CLI's recorder host: no server; status lines go to stdout and the finished files stay in a folder.
/// parity: AgentRecorder.cs Program.LocalHost
final class LocalHost: RecorderHost, @unchecked Sendable {
    let outDir: String
    let done = Event()
    var ok = false
    let cfg = Config() // dir stays nil: UI preference writes are skipped
    let mac = MacCatalog()
    var workDir: String { return (outDir as NSString).appendingPathComponent("tmp") }

    init(outDir: String) { self.outDir = outDir }

    func sendStatus(_ id: String?, _ status: String, _ error: String?) {
        print("{\"status\":" + Json.esc(status) + (error != nil ? ",\"error\":" + Json.esc(error) : "") + "}")
        fflush(stdout)
        if status == "failed" { done.set() }
    }

    func deliver(id: String, video: String, audio: String, hasTranscript: Bool, hasSystemAudio: Bool, token: String?, duration: Double, partBytes: Int64) throws {
        let v = (outDir as NSString).appendingPathComponent(id + ".mp4")
        try? FileManager.default.removeItem(atPath: v)
        try FileManager.default.copyItem(atPath: video, toPath: v)
        // has_audio = a transcription WAV was kept (the server's has_audio: the mic only).
        let wav = hasTranscript && FileManager.default.fileExists(atPath: audio)
        if wav {
            let a = (outDir as NSString).appendingPathComponent(id + ".wav")
            try? FileManager.default.removeItem(atPath: a)
            try FileManager.default.copyItem(atPath: audio, toPath: a)
        }
        print("{\"status\":\"done\",\"video\":" + Json.esc(v) + ",\"duration_s\":" + NetFormat.fixed(duration, 1)
              + ",\"has_audio\":" + (wav ? "true" : "false") + ",\"has_system_audio\":" + (hasSystemAudio ? "true" : "false") + "}")
        fflush(stdout)
        ok = true
        done.set()
    }
}

/// Dev modes that record or show UI (they need the app's main loop). parity: Program.RecordLocal / StartLatency /
/// WebcamPreview / ListDevices
enum DevCLI {
    static func arg(_ args: [String], _ name: String) -> String? { return Program.arg(args, name) }
    static func has(_ args: [String], _ name: String) -> Bool { return args.contains(name) }

    /// Runs `work` on a background thread while the main thread runs the AppKit loop (the pill and bubble live there);
    /// exits with work's code.
    static func runApp(_ work: @escaping @Sendable () -> Int32) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
        }
        Thread { exit(work()) }.start()
        MainActor.assumeIsolated { NSApplication.shared.run() }
        exit(0)
    }

    static func outDir(_ args: [String]) -> String {
        let d = DataDir.fullPath(arg(args, "--out") ?? ".")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        Log.pathName = (d as NSString).appendingPathComponent("agent.log")
        return d
    }

    /// Dev check: --list-devices. Prints the inventory report the agent would send.
    static func listDevices() -> Int32 {
        _ = MainActor.assumeIsolated { NSApplication.shared }
        print(MacCatalog().inventory(requestId: "cli").json)
        return Program.exitOk
    }

    static func stamp(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    /// Dev check: --record-local SECONDS --out DIR [--window ID|WORDS | --monitor Q] [--webcam] [--camera Q]
    /// [--size small|medium|large|PCT] [--shape circle|rect] [--mic [NAME]] [--system-audio] [--toggle mic@5,sys@6.5]
    /// [--test-camera] [--no-front]. Records exactly as a server command would (pill, bubble, window following, audio
    /// mixing) but keeps the MP4 (and the transcription WAV) in DIR instead of uploading; writes no config. --toggle
    /// presses the pill's mic / PC-sound toggles at those seconds after capture starts. Lines on stdin: "stop",
    /// "toggle mic", "toggle sys". Prints JSON status lines.
    static func recordLocal(_ args: [String]) -> Never {
        let seconds = NetParse.int32(arg(args, "--record-local") ?? "") ?? 10
        let host = LocalHost(outDir: outDir(args))
        host.mac.noFront = has(args, "--no-front")
        CameraFeed.testCamera = has(args, "--test-camera")
        host.cfg.encoder = arg(args, "--encoder")
        host.cfg.videoPath = VideoPath.normalize(arg(args, "--video-path"))
        let mic = arg(args, "--mic"), size = arg(args, "--size"), shape = arg(args, "--shape")
        let pct = NetParse.int32(size ?? "") ?? 0
        var o = StartOpts()
        o.window = arg(args, "--window")
        o.monitor = arg(args, "--monitor")
        o.mic = has(args, "--mic")
        o.micDevice = mic != nil && !mic!.hasPrefix("--") ? mic : nil
        o.systemAudio = has(args, "--system-audio")
        o.cam.on = has(args, "--webcam")
        o.cam.camera = arg(args, "--camera")
        o.cam.px = max(0, WebcamSize.pxForName(size))
        o.cam.pct = max(0, min(100, pct))
        o.cam.shape = shape == "rect" || shape == "circle" ? shape : nil
        let id = "local" + stamp("yyyyMMddHHmmss")
        let rec = Recorder(host: host)
        let toggles = Toggles.parse(arg(args, "--toggle"))
        rec.onRecording = {
            let started = Clock.now()
            for t in toggles {
                let wait = t.1 - (Clock.now() - started)
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                print("{\"toggle\":" + Json.esc(t.0) + ",\"at_s\":" + NetFormat.upTo(t.1, 3) + "}")
                fflush(stdout)
                rec.toggle(t.0)
            }
        }
        let stdinReader = Thread {
            while let line = readLine() {
                let l = NetParse.trim(line)
                if l == "stop" { rec.stop(id: id) } else if l == "toggle mic" { rec.toggle(Toggles.mic) } else if l == "toggle sys" { rec.toggle(Toggles.sys) }
            }
        }
        stdinReader.start()
        Log.write("record-local " + String(seconds) + " s, window " + (o.window ?? "-") + ", monitor " + (o.monitor ?? "-"))
        let opts = o
        runApp {
            rec.start(id: id, maxSeconds: seconds, opts: opts, uploadToken: "", received: .nan)
            host.done.wait()
            var i = 0
            while i < 50 && rec.busy { usleep(100_000); i += 1 } // temp files cleaned up
            return host.ok ? 0 : 1
        }
    }

    /// Start-latency test: --start-latency RUNS --out DIR [--seconds S] [--monitor Q] [--webcam] [--camera Q] [--mic [NAME]]
    /// [--system-audio] [--test-camera]. Makes RUNS short recordings one after another in one process, like the agent
    /// does, and reads each one's start timing. Prints a JSON line per run, then the command -> first frame median and
    /// max. Exit 1 when a run fails, the median is 1.0 s or more or the max 1.5 s or more.
    static func startLatency(_ args: [String]) -> Never {
        let runsArg = NetParse.int32(arg(args, "--start-latency") ?? "") ?? 5
        let runs = runsArg < 1 ? 5 : runsArg
        let secondsArg = NetParse.int32(arg(args, "--seconds") ?? "") ?? 3
        let seconds = secondsArg < 1 ? 3 : secondsArg
        let host = LocalHost(outDir: outDir(args))
        CameraFeed.testCamera = has(args, "--test-camera")
        let mic = arg(args, "--mic")
        let rec = Recorder(host: host)
        let lastBox = Box<StartTimes>()
        let timed = Event()
        rec.onTimed = { t in lastBox.value = t; timed.set() }
        var base = StartOpts()
        base.monitor = arg(args, "--monitor")
        base.mic = has(args, "--mic")
        base.micDevice = mic != nil && !mic!.hasPrefix("--") ? mic : nil
        base.systemAudio = has(args, "--system-audio")
        base.cam.on = has(args, "--webcam")
        base.cam.camera = arg(args, "--camera")
        let opts = base
        Log.write("start-latency " + String(runs) + " runs of " + String(seconds) + " s")
        runApp {
            _ = host.mac.audioVideo()
            var firsts: [Double] = []
            var allOk = true
            for i in 0..<runs {
                usleep(2_000_000) // idle first, as an agent waiting for its next command
                host.done.reset()
                host.ok = false
                timed.reset()
                lastBox.value = nil
                rec.start(id: "latency" + String(i + 1) + "-" + stamp("HHmmss"), maxSeconds: seconds, opts: opts, uploadToken: "", received: .nan)
                host.done.wait()
                timed.wait(10)
                var k = 0
                while k < 100 && rec.busy { usleep(100_000); k += 1 }
                let ff = lastBox.value?.ms("t_first_frame") ?? .nan
                let ok = host.ok && !ff.isNaN
                allOk = allOk && ok
                if ok { firsts.append(ff) }
                print("{\"run\":" + String(i + 1) + ",\"ok\":" + (ok ? "true" : "false") + ",\"timing\":" + Json.esc(lastBox.value?.line() ?? "") + "}")
                fflush(stdout)
            }
            firsts.sort()
            let c = firsts.count
            let median = c == 0 ? Double.nan : c % 2 == 1 ? firsts[c / 2] : (firsts[c / 2 - 1] + firsts[c / 2]) / 2
            let maxMs = c == 0 ? Double.nan : firsts[c - 1]
            let pass = allOk && median < 1000 && maxMs < 1500
            let summary = "{\"runs\":" + String(runs) + ",\"cmd_to_first_frame_ms\":[" + firsts.map { NetFormat.fixed($0, 0) }.joined(separator: ",") + "],\"median_ms\":"
                + (c == 0 ? "null" : NetFormat.fixed(median, 0)) + ",\"max_ms\":" + (c == 0 ? "null" : NetFormat.fixed(maxMs, 0))
                + ",\"target\":\"median < 1000, max < 1500\",\"pass\":" + (pass ? "true" : "false") + "}"
            print(summary)
            Log.write("start-latency " + summary)
            return pass ? 0 : 1
        }
    }

    /// Dev check: --webcam-preview SECONDS [--camera NAME|ID] [--size small|medium|large] [--px N] [--shape circle|rect]
    /// [--monitor ID|INDEX|primary] [--no-mirror] [--test-camera]. Shows the bubble without a server or recording and
    /// without writing any config. Prints a JSON result line including the bubble's screen rectangle.
    static func webcamPreview(_ args: [String]) -> Never {
        let seconds = NetParse.int32(arg(args, "--webcam-preview") ?? "") ?? 10
        CameraFeed.testCamera = has(args, "--test-camera")
        let catalog = MacCatalog()
        var px = WebcamSize.pxForName(arg(args, "--size"))
        if let n = NetParse.int32(arg(args, "--px") ?? "") { px = WebcamSize.clampPx(n) }
        let cfg = Config()
        cfg.webcamPx = px > 0 ? px : WebcamSize.defaultPx
        cfg.mirror = !has(args, "--no-mirror")
        let devs = catalog.audioVideo()
        if devs.cameras.isEmpty && !CameraFeed.testCamera { print("{\"ok\":false,\"error\":\"no camera\"}"); exit(1) }
        let cams = devs.cameras.isEmpty ? [AvDevice(id: DeviceMatch.stableId("cam", "test"), name: "Test camera", path: "test")] : devs.cameras
        let cam = DeviceMatch.av(cams, arg(args, "--camera")) ?? cams[0]
        let monitors = catalog.monitors()
        guard let mon = DeviceMatch.monitor(monitors, arg(args, "--monitor")) ?? DeviceMatch.monitor(monitors, "primary") else {
            print("{\"ok\":false,\"error\":\"no monitor\"}")
            exit(1)
        }
        let rect = arg(args, "--shape") == "rect"
        runApp {
            if !CameraFeed.testCamera && !Permissions.allowed(.video) {
                print("{\"ok\":false,\"error\":\"camera permission is off\"}")
                return 1
            }
            let started = Clock.now()
            let b: WebcamBubble = onMain {
                let b = WebcamBubble(cfg: cfg, cameras: cams, camera: cam, px: cfg.webcamPx, rect: rect, homeBounds: mon.bounds, homeWork: mon.workArea)
                b.startCamera()
                return b
            }
            let shown = b.shownEvent.wait(10)
            let firstMs = shown ? Int64((Clock.now() - started) * 1000) : -1
            if shown { usleep(UInt32(max(0, seconds)) * 1_000_000) }
            let r: IRect = onMain { b.bounds }
            let isRect: Bool = onMain { b.isRect }
            onMain { b.shutdown() }
            let err = b.lastError.value
            print("{\"ok\":" + (shown ? "true" : "false") + ",\"camera\":" + Json.esc(cam.name) + ",\"first_frame_ms\":" + String(firstMs)
                  + ",\"monitor\":" + String(mon.index) + ",\"x\":" + String(r.x) + ",\"y\":" + String(r.y) + ",\"side\":" + String(r.width)
                  + ",\"w\":" + String(r.width) + ",\"h\":" + String(r.height) + ",\"shape\":" + Json.esc(isRect ? "rect" : "circle")
                  + ",\"dpi_awareness\":\"points\"" + (err.isEmpty ? "" : ",\"error\":" + Json.esc(err)) + "}")
            return shown ? 0 : 1
        }
    }

    /// Dev check: --pill-preview SECONDS [--monitor ID|INDEX|primary] [--sources mic,sys|none] [--toggle mic,sys]
    /// [--hover mic|sys|stop] (also as --popup-preview, kit-install's name). Shows the control pill without a server or
    /// recording (no config written, no permission needed: monitors come from CoreGraphics/NSScreen, nothing is captured):
    /// --toggle presses those toggles once shown (their own code path), --hover shows that button's hover state and
    /// tooltip without moving the mouse. Prints a JSON line once shown (rectangles, capture mode, panel flags, whether the
    /// frontmost app changed), "stop" if Stop fires, and a last line when it closes. The C#'s --shot / --shot-excluded
    /// screenshots are not offered: grabbing the screen would need the Screen Recording permission.
    /// parity: AgentRecorder.cs Program.PillPreview (wes-8b83b0f)
    static func pillPreview(_ args: [String]) -> Never {
        let flag = has(args, "--pill-preview") ? "--pill-preview" : "--popup-preview"
        let seconds = NetParse.int32(arg(args, flag) ?? "") ?? 10
        let monitors = MacCatalog().monitors()
        guard let mon = DeviceMatch.monitor(monitors, arg(args, "--monitor")) ?? DeviceMatch.monitor(monitors, "primary") else {
            print("{\"error\":\"no monitor\"}")
            exit(1)
        }
        let sources = arg(args, "--sources") ?? "mic,sys", toggles = arg(args, "--toggle") ?? "", hover = arg(args, "--hover") ?? ""
        runApp {
            let stopped = Event()
            let front: pid_t = onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
            let p: ControlPill = onMain {
                let p = ControlPill(cfg: Config(), target: mon, monitors: monitors)
                p.stopClicked = { print("stop"); fflush(stdout); stopped.set() }
                p.show()
                p.setSources(mic: sources.contains("mic"), system: sources.contains("sys"))
                for t in toggles.split(separator: ",").map(String.init) where t == PillLayout.mic || t == PillLayout.sys { p.toggle(t) }
                if hover == PillLayout.mic || hover == PillLayout.sys || hover == PillLayout.stop { p.previewHover(hover) }
                return p
            }
            let shown: String = onMain { p.previewState(mon, front) }
            print("{\"shown\":true," + shown + "}")
            fflush(stdout)
            let wasStopped = stopped.wait(Double(max(0, seconds)))
            let closing: String = onMain { p.previewState(mon, front) }
            print("{\"closing\":true,\"stopped\":" + (wasStopped ? "true" : "false") + "," + closing + "}")
            fflush(stdout)
            onMain { p.close() }
            return 0
        }
    }
}

extension ControlPill {
    /// --pill-preview's state fields. Window styles become the panel's flags; "foreground" is the frontmost app.
    func previewState(_ mon: MonitorInfo, _ frontBefore: pid_t) -> String {
        let r = pillBounds, s = layout.stopButton, w = mon.workArea
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        func b(_ v: Bool) -> String { return v ? "true" : "false" }
        var f: [String] = []
        f.append("\"monitor\":" + Json.esc(mon.id))
        f.append("\"x\":\(r.x),\"y\":\(r.y),\"w\":\(r.width),\"h\":\(r.height),\"dpi\":\(dpi)")
        f.append("\"work_area\":[\(w.x),\(w.y),\(w.width),\(w.height)]")
        f.append("\"stop\":[\(windowAt.x + s.x),\(windowAt.y + s.y),\(s.width),\(s.height)]")
        f.append("\"capture_mode\":" + Json.esc(captureMode))
        f.append("\"noactivate\":" + b(panel.styleMask.contains(.nonactivatingPanel)))
        f.append("\"can_become_key\":" + b(panel.canBecomeKey))
        f.append("\"level\":\(panel.level.rawValue)")
        f.append("\"is_key\":" + b(panel.isKeyWindow))
        f.append("\"app_active\":" + b(NSApp.isActive))
        f.append("\"foreground_unchanged\":" + b(front == frontBefore))
        f.append("\"mic_on\":" + b(micOn))
        f.append("\"sys_on\":" + b(sysOn))
        return f.joined(separator: ",")
    }
}

extension DevCLI {
    /// C#'s ControlDpis: 100 %, 125 %, 150 %, 175 %, 200 %.
    static let controlDpis = [96, 120, 144, 168, 192]

    /// --controls-shots DIR: offscreen renders of the control pill and the webcam controls at every tested scale, for
    /// review. Same file names, states and `<file> WxH` lines as C#. Nothing is shown and no permission is needed. The
    /// layout is the 96-dpi design in points drawn at dpi/96 pixels per point (macOS scales whole points; Windows lays out
    /// at each DPI). parity: AgentRecorder.cs Program.ControlsShots
    static func controlsShots(_ args: [String]) -> Int32 {
        let dir = DataDir.fullPath(arg(args, "--controls-shots") ?? ".")
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data(("--controls-shots: " + Config.message(error) + "\n").utf8))
            return 1
        }
        return MainActor.assumeIsolated { () -> Int32 in
            _ = NSApplication.shared
            let mon = MonitorInfo()
            mon.bounds = IRect(0, 0, 1920, 1080)
            mon.workArea = mon.bounds
            let pill = ControlPill(cfg: Config(), target: mon, monitors: [mon])
            let pillStates: [(name: String, a: Bool, m: Bool, s: Bool, hover: String?)] = [
                ("on", true, true, true, nil), ("muted", true, false, false, nil),
                ("hover-mic", true, true, false, PillLayout.mic), ("no-sources", false, false, false, PillLayout.sys),
            ]
            let stripStates: [(px: Int, mirror: Bool, rect: Bool)] = [
                (WebcamSize.minPx, true, false), (WebcamSize.defaultPx, false, true), (WebcamSize.maxPx, true, true),
            ]
            let strip = StripView(frame: NSRect(origin: .zero, size: NSSize(width: ControlLayout(96).size.width, height: ControlLayout(96).size.height)))
            var failed = false
            for dpi in controlDpis {
                let pct = dpi * 100 / 96
                for st in pillStates {
                    pill.shotState(micAvailable: st.a, micOn: st.m, sysAvailable: st.a, sysOn: st.s, hover: st.hover)
                    let file = (dir as NSString).appendingPathComponent("pill-" + String(pct) + "pct-" + st.name + ".png")
                    if !savePng(pill.view, dpi, file) { failed = true }
                }
                for st in stripStates {
                    strip.shot = (st.px, st.mirror, st.rect)
                    let file = (dir as NSString).appendingPathComponent("controls-" + String(pct) + "pct-" + String(st.px) + "px-mirror-"
                        + (st.mirror ? "on" : "off") + "-" + (st.rect ? "rect" : "circle") + ".png")
                    if !savePng(strip, dpi, file) { failed = true }
                }
            }
            pill.close()
            return failed ? 1 : 0
        }
    }

    /// The view drawn into a transparent bitmap of round(points * dpi/96) pixels, written as PNG; prints `<file> WxH`.
    @MainActor
    static func savePng(_ view: NSView, _ dpi: Int, _ file: String) -> Bool {
        let b = view.bounds
        let w = Int(NetFormat.round(Double(b.width) * Double(dpi) / 96)), h = Int(NetFormat.round(Double(b.height) * Double(dpi) / 96))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = b.size
        view.needsDisplay = true
        view.cacheDisplay(in: b, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: file))) != nil
        else {
            FileHandle.standardError.write(Data(("--controls-shots: cannot write " + file + "\n").utf8))
            return false
        }
        print(file + " " + String(w) + "x" + String(h))
        return true
    }
}
