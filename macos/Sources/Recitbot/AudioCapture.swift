import AVFoundation
import CoreMedia
import RecitbotCore

/// ManualResetEvent.
final class Event: @unchecked Sendable {
    private let cond = NSCondition()
    private var isSet = false

    func set() { cond.lock(); isSet = true; cond.broadcast(); cond.unlock() }
    func reset() { cond.lock(); isSet = false; cond.unlock() }
    var signaled: Bool { cond.lock(); defer { cond.unlock() }; return isSet }

    /// True when set within `seconds`.
    @discardableResult
    func wait(_ seconds: Double) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        cond.lock()
        defer { cond.unlock() }
        while !isSet { if !cond.wait(until: until) { return isSet } }
        return true
    }

    func wait() { cond.lock(); while !isSet { cond.wait() }; cond.unlock() }
}

/// PCM out of CoreMedia audio sample buffers.
enum AudioBuffers {
    /// Interleaved float frames with `channels` channels (mono <-> stereo mapped), the buffer's rate and frame count.
    static func floats(_ sb: CMSampleBuffer, channels: Int) -> (samples: [Float], frames: Int, rate: Int)? {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdP.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        let srcCh = Int(asbd.mChannelsPerFrame)
        if frames <= 0 || srcCh <= 0 || asbd.mFormatID != kAudioFormatLinearPCM { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        if !(isFloat && bits == 32) && !(!isFloat && bits == 16) { return nil }
        let abl = AudioBufferList.allocate(maximumBuffers: max(1, srcCh))
        defer { free(abl.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: max(1, srcCh)), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        if status != noErr { return nil }
        var out = [Float](repeating: 0, count: frames * channels)
        func value(_ ch: Int, _ i: Int) -> Float {
            let b = nonInterleaved ? ch : 0
            if b >= abl.count { return 0 }
            guard let data = abl[b].mData else { return 0 }
            let idx = nonInterleaved ? i : i * srcCh + ch
            let bytes = Int(abl[b].mDataByteSize)
            if isFloat {
                if (idx + 1) * 4 > bytes { return 0 }
                return data.assumingMemoryBound(to: Float.self)[idx]
            }
            if (idx + 1) * 2 > bytes { return 0 }
            return Float(data.assumingMemoryBound(to: Int16.self)[idx]) / 32768
        }
        for i in 0..<frames {
            if channels == 1 {
                out[i] = srcCh == 1 ? value(0, i) : (value(0, i) + value(1, i)) / 2
            } else {
                for c in 0..<channels { out[i * channels + c] = value(min(c, srcCh - 1), i) }
            }
        }
        _ = block
        return (out, frames, Int(asbd.mSampleRate.rounded()))
    }

    /// A sample buffer's presentation time on the shared clock (host time seconds, Clock.now()).
    static func hostSeconds(_ sb: CMSampleBuffer, from clock: CMClock?) -> Double {
        var pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if let c = clock, c !== CMClockGetHostTimeClock() { pts = CMSyncConvertTime(pts, from: c, to: CMClockGetHostTimeClock()) }
        return CMTimeGetSeconds(pts)
    }
}

/// System audio: ScreenCaptureKit's audio output (what plays in the speakers or headset, this process excluded),
/// written to a 48 kHz stereo 16-bit WAV that covers the whole recording without gaps. Sample 0 is startTime on the
/// shared clock; every packet goes where its timestamp says, and silence fills the rest (nothing playing). Muted spans
/// are written as zeros. parity: AgentRecorder.cs LoopbackCapture (macOS mixes every output device for us, so there are
/// no device switches or losses to handle; the counters stay 0).
final class SystemAudio: @unchecked Sendable {
    static let rate = 48000, channels = 2
    let timeline: PcmTimeline
    /// The SCStream audio output and the silence filler both run here.
    let queue = DispatchQueue(label: "com.recitbot.system-audio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var announced = false, stopped = false
    let switches = 0, losses = 0

    init(path: String) { timeline = PcmTimeline(path: path, rate: SystemAudio.rate, channels: SystemAudio.channels) }

    var pathName: String { return timeline.pathName }
    var startTime: Double { return timeline.startTime }
    var seconds: Double { return timeline.seconds }
    var mutes: MuteLog { return timeline.mutes }

    func start() throws {
        try timeline.open(start: Clock.now())
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        // Keep the file continuous, 100 ms behind real time so packets (which arrive a little late) land in place.
        t.setEventHandler { [weak self] in self?.timeline.padTo(Clock.now() - 0.1) }
        t.resume()
        timer = t
    }

    /// One ScreenCaptureKit audio buffer (on `queue`).
    func feed(_ sb: CMSampleBuffer) {
        if stopped { return }
        guard let pcm = AudioBuffers.floats(sb, channels: SystemAudio.channels) else { return }
        if !announced {
            announced = true
            Log.write("system audio: capturing \"system output\" (" + String(pcm.rate) + " Hz, " + String(SystemAudio.channels) + " ch)")
        }
        timeline.place(pcm.samples, frames: pcm.frames, srcRate: pcm.rate, at: AudioBuffers.hostSeconds(sb, from: nil))
    }

    /// Mute or unmute from now on (frames at or after this instant are written as zeros).
    func setMuted(_ muted: Bool) { timeline.mutes.set(muted, Clock.now() - timeline.startTime) }

    /// Stops, pads to now and finalizes the WAV header. Safe to call twice.
    func stop() {
        queue.sync {
            if stopped { return }
            stopped = true
            timer?.cancel()
            timer = nil
            timeline.padTo(Clock.now())
            do {
                try timeline.finish()
                Log.write("system audio: " + NetFormat.fixed(seconds, 1) + " s written, " + String(switches) + " device switches, "
                          + String(losses) + " losses, " + String(timeline.mutes.allSpans().count) + " muted spans")
            } catch {
                Log.write("system audio: wav not finalized: " + Config.message(error))
            }
        }
    }
}

/// The mic, for the whole recording, to a 48 kHz mono 16-bit WAV whose sample 0 is its first packet (t0 on the shared
/// clock). Muting zeroes it live; Recorder also silences the spans exactly when it mixes. parity: WindowsFfmpegBackend
/// .StartMic + the mic's FfProgress (macOS: an AVCaptureSession of its own instead of an ffmpeg process).
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let name: String
    let timeline: PcmTimeline
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.recitbot.mic", qos: .userInitiated)
    private let gate = NSLock()
    private var failure: String?
    private var stopped = false
    private var observer: NSObjectProtocol?

    init(device: AVCaptureDevice, path: String) throws {
        name = device.localizedName
        timeline = PcmTimeline(path: path, rate: 48000, channels: 1)
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CaptureError("cannot use " + name) }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CaptureError("cannot read " + name) }
        session.addOutput(output)
        session.commitConfiguration()
        try timeline.open(start: .nan)
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let e = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.fail(e?.localizedDescription ?? "runtime error")
        }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    private func fail(_ why: String) {
        gate.lock()
        if failure == nil { failure = why }
        gate.unlock()
    }

    /// Why the session stopped on its own (nil while running).
    var failed: String? { gate.lock(); defer { gate.unlock() }; return failure }
    /// The first packet has arrived (FfProgress.Valid).
    var valid: Bool { return timeline.started }
    var t0: Double { return timeline.startTime }
    var seconds: Double { return timeline.seconds }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if stopped { return }
        guard let pcm = AudioBuffers.floats(sampleBuffer, channels: 1) else { return }
        timeline.place(pcm.samples, frames: pcm.frames, srcRate: pcm.rate, at: AudioBuffers.hostSeconds(sampleBuffer, from: session.synchronizationClock))
    }

    /// Live mute (volume@mic on Windows).
    func setMuted(_ muted: Bool) {
        let now = Clock.now()
        queue.async { self.timeline.setMuted(muted, now: now) }
    }

    /// For the log: "t0 T, lag start/end 0/0 ms, out_time O s" (FfProgress.Describe; packets carry their own capture
    /// time here, so there is no pipeline lag to report).
    func describe() -> String {
        return "t0 " + NetFormat.fixed(t0, 3) + ", lag start/end 0/0 ms, out_time " + NetFormat.fixed(seconds, 3) + " s"
    }

    /// Stops the session and finalizes the WAV. Safe to call twice.
    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if session.isRunning { session.stopRunning() }
        queue.sync {
            if stopped { return }
            stopped = true
            do { try timeline.finish() } catch { Log.write("mic: wav not finalized: " + Config.message(error)) }
        }
    }
}
