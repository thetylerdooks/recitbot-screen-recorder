import AVFoundation
import CoreMedia
import CoreVideo
import RecitbotCore

/// The camera, as frames of exactly `size` pixels (BGRA): the centre of the camera image at the bubble's aspect (square,
/// or 16:9 for the rectangle), scaled to the bubble. Mirroring happens in the bubble (it can change mid-recording
/// without restarting the camera). parity: AgentRecorder.cs CameraFeed + WindowsFfmpegBackend.CameraProcess
/// (macOS: an AVCaptureSession instead of an ffmpeg process; 640x480 first, the device default as the retry).
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Dev only (--test-camera): a moving test pattern instead of the camera.
    nonisolated(unsafe) static var testCamera = false
    let device: AVCaptureDevice?
    let name: String
    let size: ISize
    let queue = DispatchQueue(label: "com.recitbot.camera", qos: .userInteractive)
    private let gate = NSLock()
    private var front: [UInt8], back: [UInt8]
    private var fresh = false
    private var count = 0
    private var stopped = false
    private var session: AVCaptureSession?
    private var observer: NSObjectProtocol?
    private var lastError = ""
    private var sized = true
    private var testTimer: DispatchSourceTimer?
    var onFrame: (@Sendable () -> Void)?
    var onFailed: (@Sendable (String) -> Void)?

    init(device: AVCaptureDevice?, name: String, size: ISize) {
        self.device = device
        self.name = name
        self.size = size
        let buf = [UInt8](repeating: 0, count: size.width * size.height * 4)
        front = buf
        back = buf
    }

    /// Frames read from the camera since start (the bubble's redraw stats).
    var frames: Int { gate.lock(); defer { gate.unlock() }; return count }

    func start() {
        queue.async { self.open(sized: true) }
    }

    /// 640x480 keeps the camera's work small; some cameras refuse it, so retry with the device default.
    private func open(sized: Bool) {
        if stopped { return }
        self.sized = sized
        if CameraFeed.testCamera { startTestPattern(); return }
        guard let device = device else { fail("no camera"); return }
        do {
            let s = AVCaptureSession()
            s.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw CaptureError("camera busy") }
            s.addInput(input)
            let preset: AVCaptureSession.Preset = sized ? .vga640x480 : .high
            if s.canSetSessionPreset(preset) { s.sessionPreset = preset } else if sized { throw CaptureError("640x480 not supported") }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            guard s.canAddOutput(out) else { throw CaptureError("camera output unavailable") }
            s.addOutput(out)
            s.commitConfiguration()
            session = s
            observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { [weak self] note in
                guard let me = self else { return }
                let why = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "runtime error"
                me.queue.async { me.lost(why) }
            }
            s.startRunning()
            if !s.isRunning { throw CaptureError(lastError.isEmpty ? "camera did not start" : lastError) }
            // -video_size 640x480 -framerate 30 (the sized try only, like the C#): cap the camera at 30 fps when the
            // format allows it, after startRunning (the preset picks the format when the session starts). The
            // default-size retry keeps the device's own rate.
            if sized && device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }),
               (try? device.lockForConfiguration()) != nil {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }
        } catch {
            lastError = Agent.message(error)
            teardown()
            Log.write("webcam: camera " + (sized ? "640x480" : "default size") + " failed: " + lastError)
            if sized { open(sized: false) } else { fail(lastError) }
        }
    }

    /// On queue: the session stopped with an error.
    private func lost(_ why: String) {
        if stopped { return }
        lastError = why
        let got = frames > 0
        teardown()
        if got { fail("camera stopped: " + why); return }
        Log.write("webcam: camera " + (sized ? "640x480" : "default size") + " failed: " + why)
        if sized { open(sized: false) } else { fail(why) }
    }

    private func fail(_ why: String) { if !stopped { onFailed?(why) } }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if let s = session, s.isRunning { s.stopRunning() }
        session = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        scale(base.assumingMemoryBound(to: UInt8.self), sw, sh, stride)
        publish()
    }

    /// crop='min(iw,ih*W/H)':'min(ih,iw*H/W)' (centred), then scale to W x H.
    private func scale(_ src: UnsafePointer<UInt8>, _ sw: Int, _ sh: Int, _ stride: Int) {
        let w = size.width, h = size.height
        let cw = min(sw, sh * w / max(1, h)), ch = min(sh, sw * h / max(1, w))
        let x0 = (sw - cw) / 2, y0 = (sh - ch) / 2
        back.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let sy = y0 + min(ch - 1, (2 * y + 1) * ch / (2 * h))
                let row = sy * stride
                for x in 0..<w {
                    let sx = x0 + min(cw - 1, (2 * x + 1) * cw / (2 * w))
                    let s = row + sx * 4, o = (y * w + x) * 4
                    dst[o] = src[s]; dst[o + 1] = src[s + 1]; dst[o + 2] = src[s + 2]; dst[o + 3] = 255
                }
            }
        }
    }

    private func publish() {
        gate.lock()
        swap(&front, &back)
        fresh = true
        count += 1
        gate.unlock()
        onFrame?()
    }

    /// A 30 fps pattern whose colours change in every frame (testsrc2 + hue rotation), through the same bubble.
    private func startTestPattern() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let started = Clock.now()
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in
            guard let self = self, !self.stopped else { return }
            let s = Clock.now() - started
            let w = self.size.width, h = self.size.height
            let hue = s / 4 - (s / 4).rounded(.down)
            self.back.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        let band = (x * 8 / max(1, w) + Int(s * 30)) % 8
                        let v = Double(band) / 8 + hue
                        let o = (y * w + x) * 4
                        dst[o] = UInt8(Int(v * 255) & 0xFF)
                        dst[o + 1] = UInt8(Int((1 - v) * 255) & 0xFF)
                        dst[o + 2] = UInt8(y * 255 / max(1, h))
                        dst[o + 3] = 255
                    }
                }
            }
            self.publish()
        }
        t.resume()
        testTimer = t
    }

    /// Copies the newest frame into dst. Returns false when nothing new arrived.
    func copyLatest(_ dst: inout [UInt8]) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if !fresh { return false }
        fresh = false
        if dst.count != front.count { dst = front } else { dst.withUnsafeMutableBufferPointer { d in front.withUnsafeBufferPointer { s in d.baseAddress!.update(from: s.baseAddress!, count: s.count) } } }
        return true
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.testTimer?.cancel()
            self.testTimer = nil
            self.teardown()
        }
    }
}
