import AVFoundation
import CoreMedia
import CoreVideo
import RecitbotCore

/// The end-to-end mix, headless (no TCC: synthetic frames through the real VideoEncoder, synthetic WAVs, no capture):
/// the capture MP4 exactly as ScreenCapture writes it (h264_videotoolbox, odd 1726x1080 like a 16:10 display scaled to
/// 1080p), then AudioMux.run for mic + system, mic only, system only, and mic + system from a trimmed keyframe; the
/// no-audio path (the capture file itself) is checked readable. Part of --selftest; --muxtest runs it alone.
enum MuxTest {
    static let width = 1726, height = 1080, fps = 30, seconds = 3.0

    static func group(_ t: SelfTest) {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-muxtest-" + String(getpid()))
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func path(_ n: String) -> String { return (dir as NSString).appendingPathComponent(n) }

        let capture = path("capture.mp4")
        let keys: [(Double, CMTime)]
        do { keys = try encode(capture) } catch { t.check("mux capture encode", false, Agent.message(error)); return }
        t.check("mux capture encode", FileManager.default.fileExists(atPath: capture))
        let probe = inspect(capture)
        t.check("mux no audio: capture readable", probe.video == 1 && probe.audio == 0 && abs(probe.seconds - seconds) < 0.2, probe.describe)

        let mic = path("mic.wav"), sys = path("sys.wav")
        do { try wav(mic, channels: 1, hz: 440); try wav(sys, channels: 2, hz: 660) } catch { t.check("mux wavs", false, Agent.message(error)); return }
        let whole = [AudioMath.SliceOp(delayMs: 0, start: 0, duration: seconds)]
        let trimKey = keys.first { $0.0 > 0.05 }
        let cases: [(String, String?, String?, (Double, CMTime)?)] = [
            ("mic + system", mic, sys, nil), ("mic only", mic, nil, nil), ("system only", nil, sys, nil), ("mic + system trimmed", mic, sys, trimKey),
        ]
        for (name, m, s, trim) in cases {
            let out = path("out.mp4"), outWav = path("out.wav")
            let plan = MixPlan(micMuted: m != nil ? [Span(1.0, 1.2)] : [], micSlices: m != nil ? whole : nil, sysSlices: s != nil ? whole : nil)
            let trimSecs = trim?.0 ?? 0
            do {
                try AudioMux.run(video: capture, videoSeconds: seconds, trim: trim?.1 ?? .zero, plan: plan, micWav: m, sysWav: s, outVideo: out, outWav: outWav)
                let r = inspect(out)
                // Transcripts are mic-only: a WAV of the mix's length with a mic, none at all without one.
                let hasWav = FileManager.default.fileExists(atPath: outWav)
                let wavSecs = hasWav ? Double(Recorder.fileSize(outWav) - 44) / 32000.0 : 0
                let wavOk = m != nil ? hasWav && abs(wavSecs - seconds) < 0.1 : !hasWav
                t.check("mux " + name, r.video == 1 && r.audio == 1 && abs(r.seconds - (seconds - trimSecs)) < 0.2 && r.audioFrames > 0 && wavOk,
                        r.describe + ", transcription " + (hasWav ? NetFormat.fixed(wavSecs, 3) + " s" : "none") + ", trim " + NetFormat.fixed(trimSecs, 3))
            } catch {
                t.check("mux " + name, false, Agent.message(error))
            }
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.removeItem(atPath: outWav)
        }
        t.check("mux trim keyframe found", trimKey != nil, "keyframes \(keys.map { $0.0 })")
    }

    /// --muxtest: only this group.
    static func run() -> Int32 {
        let t = SelfTest()
        group(t)
        print("muxtest: \(t.passed) passed, \(t.failed) failed")
        return t.failed == 0 ? 0 : 1
    }

    /// `seconds` of moving gray frames through the capture's own encoder and writer; its early keyframes.
    static func encode(_ out: String) throws -> [(Double, CMTime)] {
        let enc = try VideoEncoder(path: out, width: width, height: height, fps: fps)
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let base = CMTime(value: 1_000_000, timescale: 600) // capture pts are host time, not zero
        for n in 0..<Int(seconds * Double(fps)) {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let p = pb else {
                throw CaptureError("pixel buffer")
            }
            CVPixelBufferLockBaseAddress(p, [])
            memset(CVPixelBufferGetBaseAddress(p), Int32((n * 3) & 0xFF), CVPixelBufferGetDataSize(p))
            CVPixelBufferUnlockBaseAddress(p, [])
            enc.encode(p, CMTimeAdd(base, CMTime(value: CMTimeValue(n * 20), timescale: 600)))
        }
        guard enc.finish() else { throw CaptureError("encoder: " + (enc.error ?? "finish failed")) }
        return enc.keyframes
    }

    /// A 48 kHz PCM16 sine WAV, `seconds` long.
    static func wav(_ path: String, channels: Int, hz: Double) throws {
        let w = try WavWriter(path: path, rate: 48000, channels: channels)
        let frames = Int(seconds * 48000)
        var s = [Int16](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = Int16(sin(2 * .pi * hz * Double(i) / 48000) * 8000)
            for c in 0..<channels { s[i * channels + c] = v }
        }
        try w.write(s)
        try w.finish()
    }

    struct Probe {
        var video = 0, audio = 0, seconds = 0.0, audioFrames = 0, error = ""
        var describe: String {
            return "video tracks \(video), audio tracks \(audio), \(NetFormat.fixed(seconds, 3)) s, audio buffers \(audioFrames)" + (error.isEmpty ? "" : ", " + error)
        }
    }

    /// Track counts, duration and whether the audio track decodes.
    static func inspect(_ file: String) -> Probe {
        let asset = AVURLAsset(url: URL(fileURLWithPath: file))
        let done = Event(), box = Box<Probe>()
        Task.detached {
            var p = Probe()
            do {
                p.video = try await asset.loadTracks(withMediaType: .video).count
                let a = try await asset.loadTracks(withMediaType: .audio)
                p.audio = a.count
                p.seconds = CMTimeGetSeconds(try await asset.load(.duration))
                if let at = a.first {
                    let r = try AVAssetReader(asset: asset)
                    let o = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    r.add(o)
                    if r.startReading() { while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { p.audioFrames += 1 } } }
                    if let e = r.error { p.error = Agent.message(e) }
                }
            } catch { p.error = Agent.message(error) }
            box.value = p
            done.set()
        }
        if !done.wait(30) { return Probe(error: "inspect timed out") }
        return box.value ?? Probe(error: "inspect failed")
    }
}
