import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import RecitbotCore
import ScreenCaptureKit
import VideoToolbox

/// H.264 through VideoToolbox into an MP4 (AVAssetWriter, stream copy of the encoded frames). The encoder settings
/// mirror the Windows ffmpeg chain: ~3.5 Mbps average, peaks capped at 4.5 Mbps over a 9000 kbit (2 s) buffer, a GOP of
/// 2 s, no B-frames, and a keyframe on every max(1, round(fps/10))-th frame for the first 2 s (VideoChain.EarlyKeys:
/// the mix may cut the head off at one of them, AudioMath.StartTrim). +faststart = shouldOptimizeForNetworkUse.
/// parity: WindowsFfmpegBackend.StartScreen encoder half + VideoChain.EarlyKeys/EncoderOptions (output never exceeds
/// 1920x1080 here, so the >1080p bitrate step never applies).
final class VideoEncoder: @unchecked Sendable {
    static let averageBitRate = 3_500_000, maxRateBytesPer2s = 9_000_000 / 8
    let path: String, width: Int, height: Int, fps: Int
    let every: Int
    private var session: VTCompressionSession?
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let gate = NSLock()
    private var submitted = 0
    private var firstPTS = CMTime.invalid
    private var lastOut = CMTime.invalid
    private var outFrames = 0
    private var outBytes: Int64 = 0
    private var keys: [(Double, CMTime)] = []
    private var writeError: String?
    private var finished = false

    init(path: String, width: Int, height: Int, fps: Int) throws {
        self.path = path
        self.width = width
        self.height = height
        self.fps = fps
        every = EarlyKeys.every(fps)
        try? FileManager.default.removeItem(atPath: path)
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let session = s else { throw CaptureError("h264 encoder unavailable (\(st))") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: VideoEncoder.averageBitRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: VideoEncoder.maxRateBytesPer2s), NSNumber(value: 2.0)] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    var frames: Int { gate.lock(); defer { gate.unlock() }; return outFrames }
    var bytes: Int64 { gate.lock(); defer { gate.unlock() }; return outBytes }
    var error: String? { gate.lock(); defer { gate.unlock() }; return writeError }
    /// Keyframe times (seconds from the first frame) in the first 2 s, with their exact media times.
    var keyframes: [(Double, CMTime)] { gate.lock(); defer { gate.unlock() }; return keys }

    /// One frame (in presentation order, strictly increasing pts).
    func encode(_ pb: CVPixelBuffer, _ pts: CMTime) {
        gate.lock()
        guard let s = session, !finished else { gate.unlock(); return }
        if !firstPTS.isValid { firstPTS = pts }
        let n = submitted
        submitted += 1
        let t = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
        gate.unlock()
        // ffmpeg: -force_key_frames "expr:lt(t,2)*not(mod(n,every))"
        let props: CFDictionary? = EarlyKeys.forced(n, t, every) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sb in
            self?.output(status, sb)
        }
    }

    private func output(_ status: OSStatus, _ sb: CMSampleBuffer?) {
        gate.lock()
        defer { gate.unlock() }
        guard status == noErr, let sb = sb, writeError == nil else {
            if status != noErr && writeError == nil { writeError = "encoder error \(status)" }
            return
        }
        if input == nil {
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { writeError = "writer cannot add the video track"; return }
            writer.add(i)
            guard writer.startWriting() else { writeError = "writer: " + (writer.error.map { Agent.message($0) } ?? "cannot start"); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            input = i
        }
        guard let i = input else { return }
        var waited = 0
        while !i.isReadyForMoreMediaData && waited < 200 && writer.status == .writing { usleep(1000); waited += 1 }
        if !i.append(sb) {
            writeError = "writer: " + (writer.error.map { Agent.message($0) } ?? "append failed")
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        lastOut = pts
        outFrames += 1
        outBytes += Int64(CMSampleBufferGetTotalSampleSize(sb))
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
        let notSync = (atts?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false
        let rel = CMTimeSubtract(pts, firstPTS)
        let secs = CMTimeGetSeconds(rel)
        if !notSync && secs <= 2.0 { keys.append((secs, rel)) }
    }

    /// Flushes the encoder and closes the file. False when nothing usable was written.
    func finish() -> Bool {
        gate.lock()
        if finished { gate.unlock(); return writer.status == .completed }
        finished = true
        let s = session
        gate.unlock()
        if let s = s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        gate.lock()
        session = nil
        let i = input
        gate.unlock()
        guard let inp = i, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            return false
        }
        inp.markAsFinished()
        let done = Event()
        writer.finishWriting { done.set() }
        if !done.wait(15) { Log.write("capture: writer did not finish in time"); return false }
        if writer.status != .completed {
            gate.lock()
            writeError = "writer: " + (writer.error.map { Agent.message($0) } ?? "not completed")
            gate.unlock()
            return false
        }
        return true
    }
}

/// What one capture segment records. parity: AgentRecorder.cs CaptureSpec
struct CaptureSpec {
    var monitor: MonitorInfo
    var display: SCDisplay
    var filter: SCContentFilter
    var video = ""
    var fps = 30
    var maxSeconds = 1
    var maxBytes: Int64 = 0
    /// Window recordings: the part of the monitor to show (monitor-relative points), letterboxed into output.
    var region: WindowView?
    var output = ISize(2, 2)
}

/// One ScreenCaptureKit stream into one VideoEncoder: frames from the recorded display (this app's windows excluded,
/// except the webcam bubble), paced to a constant `fps` like ddagrab (the last frame is repeated while the screen is
/// still), black while a recorded window is hidden, system audio to SystemAudio. Stops on stop(), after maxSeconds of
/// video (ffmpeg -t), at maxBytes (-fs) or when the stream fails. Timing: t0 = the first frame's capture time on the
/// shared clock, last = the video's length (FfProgress.T0 / Last). parity: StartScreen + the screen ffmpeg process.
final class ScreenSegment: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let spec: CaptureSpec
    let encoder: VideoEncoder
    let system: SystemAudio?
    let queue = DispatchQueue(label: "com.recitbot.screen", qos: .userInteractive)
    private var stream: SCStream?
    private var config = SCStreamConfiguration()
    private var pacer: DispatchSourceTimer?
    // queue state
    private var lastBuffer: CVPixelBuffer?
    private var black: CVPixelBuffer?
    private var blank = false
    private var firstPTS = CMTime.invalid, lastPTS = CMTime.invalid
    private var stopping = false
    private let gate = NSLock()
    private var failure: String?
    let firstFrame = Event()
    let exited = Event()
    var onFirstFrame: (() -> Void)?
    var launched = Clock.now()
    var exitedAt = Double.nan

    /// Kept alive here: SCStreamConfiguration.backgroundColor is unowned(unsafe).
    static let blackColor = CGColor(gray: 0, alpha: 1)

    init(spec: CaptureSpec, system: SystemAudio?) throws {
        self.spec = spec
        self.system = system
        encoder = try VideoEncoder(path: spec.video, width: spec.output.width, height: spec.output.height, fps: spec.fps)
        super.init()
        let c = SCStreamConfiguration()
        c.width = spec.output.width
        c.height = spec.output.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = true
        c.queueDepth = 6
        c.backgroundColor = ScreenSegment.blackColor
        c.preservesAspectRatio = true
        if let r = spec.region {
            c.sourceRect = CGRect(x: r.crop.x, y: r.crop.y, width: r.crop.width, height: r.crop.height)
            blank = r.blank
        }
        if system != nil {
            c.capturesAudio = true
            c.sampleRate = SystemAudio.rate
            c.channelCount = SystemAudio.channels
            c.excludesCurrentProcessAudio = true
        }
        config = c
    }

    /// Why the capture ended on its own (nil after a normal stop).
    var failed: String? { gate.lock(); defer { gate.unlock() }; return failure }

    /// FfProgress.Valid / T0 / Last.
    var valid: Bool { return queue.sync { firstPTS.isValid } }
    var t0: Double { return queue.sync { CMTimeGetSeconds(firstPTS) } }
    var last: Double {
        return queue.sync { firstPTS.isValid && lastPTS.isValid ? CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS)) + 1.0 / Double(spec.fps) : 0 }
    }

    /// Starts the stream (waits for ScreenCaptureKit, at most 10 s).
    func start() throws {
        launched = Clock.now()
        let s = SCStream(filter: spec.filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if let sys = system { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sys.queue) }
        stream = s
        let done = Event(), err = Box<Error>()
        s.startCapture { e in err.value = e; done.set() }
        if !done.wait(10) { throw CaptureError("screen capture did not start") }
        if let e = err.value { throw CaptureError(Agent.message(e)) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(spec.fps)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.pace() }
        t.resume()
        pacer = t
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if type == .audio { system?.feed(sampleBuffer); return }
        guard type == .screen, !stopping else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[SCStreamFrameInfo.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastBuffer = pb
        submit(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// The constant frame rate: repeats the last frame (or black) when nothing new came for 1.5 frame intervals.
    private func pace() {
        guard !stopping, lastBuffer != nil || blank, lastPTS.isValid else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if CMTimeGetSeconds(CMTimeSubtract(now, lastPTS)) >= 1.5 / Double(spec.fps) { submit(now) }
    }

    /// Encodes the current picture at pts (on queue).
    private func submit(_ pts: CMTime) {
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 { return }
        guard let pb = blank ? blackBuffer() : lastBuffer else { return }
        let first = !firstPTS.isValid
        if first { firstPTS = pts }
        if CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS)) >= Double(spec.maxSeconds) { requestStop(); return }
        lastPTS = pts
        encoder.encode(pb, pts)
        if first { firstFrame.set(); onFirstFrame?() }
        if spec.maxBytes > 0 && encoder.bytes >= spec.maxBytes { requestStop() }
        if let e = encoder.error { setFailure(e); requestStop() }
    }

    private func blackBuffer() -> CVPixelBuffer? {
        if let b = black { return b }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, spec.output.width, spec.output.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb) == kCVReturnSuccess,
              let b = pb else { return nil }
        CVPixelBufferLockBaseAddress(b, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(b) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(b, plane) {
                memset(base, plane == 0 ? 16 : 128, CVPixelBufferGetBytesPerRowOfPlane(b, plane) * CVPixelBufferGetHeightOfPlane(b, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        black = b
        return b
    }

    private func setFailure(_ why: String) {
        gate.lock()
        if failure == nil { failure = why }
        gate.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        setFailure(Agent.message(error))
        Log.write("capture stopped: " + Agent.message(error))
        queue.async { self.finishUp(capturing: false) }
    }

    /// A window view change (WindowFollower): the crop as sourceRect, or black.
    func apply(_ v: WindowView) {
        queue.async {
            if self.stopping { return }
            self.blank = v.blank
            if v.blank { return }
            let c = self.config
            c.sourceRect = CGRect(x: v.crop.x, y: v.crop.y, width: v.crop.width, height: v.crop.height)
            self.stream?.updateConfiguration(c) { e in if let e = e { Log.write("window: crop not applied: " + Agent.message(e)) } }
        }
    }

    /// Another content filter (the bubble appeared, or the recorded window moved to another display).
    func apply(_ filter: SCContentFilter) {
        let f = Box(filter)
        queue.async {
            if self.stopping { return }
            guard let filter = f.value else { return }
            self.stream?.updateContentFilter(filter) { e in if let e = e { Log.write("capture: filter not applied: " + Agent.message(e)) } }
        }
    }

    /// Graceful stop ("q"): the stream stops, the encoder is flushed and the MP4 closed. Safe to call any time.
    func requestStop() {
        queue.async { self.finishUp(capturing: true) }
    }

    private func finishUp(capturing: Bool) {
        if stopping { return }
        stopping = true
        pacer?.cancel()
        pacer = nil
        let s = stream
        DispatchQueue.global(qos: .userInitiated).async {
            if capturing, let s = s {
                let done = Event()
                s.stopCapture { _ in done.set() }
                done.wait(5)
            }
            // The video covers the recording up to the stop: a still screen's last frame is repeated at the end.
            self.queue.sync {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if self.lastPTS.isValid, let pb = self.blank ? self.blackBuffer() : self.lastBuffer,
                   CMTimeGetSeconds(CMTimeSubtract(now, self.lastPTS)) >= 1.0 / Double(self.spec.fps),
                   CMTimeGetSeconds(CMTimeSubtract(now, self.firstPTS)) < Double(self.spec.maxSeconds) {
                    self.lastPTS = now
                    self.encoder.encode(pb, now)
                }
                self.lastBuffer = nil
            }
            if !self.encoder.finish(), let e = self.encoder.error { self.setFailure(e) }
            self.exitedAt = Clock.now()
            self.exited.set()
        }
    }

    func waitForExit() { exited.wait() }
}

/// Content filters for one display: this app's windows (pill, controls, menus) excluded, the listed windows (the webcam
/// bubble) kept. parity: Native.ExcludeFromCapture on the pill/controls/menus; the bubble is a normal captured window.
enum CaptureFilter {
    static func make(_ display: SCDisplay, _ content: SCShareableContent, keep windowNumbers: [Int]) -> SCContentFilter {
        let me = getpid()
        let apps = content.applications.filter { $0.processID == me }
        let keep = content.windows.filter { w in w.owningApplication?.processID == me && windowNumbers.contains(Int(w.windowID)) }
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: keep)
    }

    /// A fresh filter once the window server lists the windows to keep (retries for about a second).
    static func refreshed(_ displayID: CGDirectDisplayID, keep windowNumbers: [Int]) -> SCContentFilter? {
        for attempt in 0..<4 {
            if attempt > 0 { usleep(300_000) }
            guard let content = try? MacCatalog.shareable(onScreenOnly: true),
                  let d = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let found = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }.count
            if found == windowNumbers.count || attempt == 3 { return make(d, content, keep: windowNumbers) }
        }
        return nil
    }
}
