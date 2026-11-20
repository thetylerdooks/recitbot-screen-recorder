import Foundation

/// A 16-bit PCM WAV that covers a recording without gaps: sample 0 is `startTime` on the shared clock, every packet goes
/// where its timestamp says and silence fills the rest. Muted spans (seconds from startTime) are written as zeros, so
/// muted sound never reaches the disk. Not thread-safe: one serial queue feeds it (`seconds` may be read anywhere).
/// parity: AgentRecorder.cs LoopbackCapture (timeline, resampling and WAV parts; the WASAPI device loop is the
/// ScreenCaptureKit audio output on macOS). Also used for the mic, whose sample 0 is its first packet.
public final class PcmTimeline: @unchecked Sendable {
    public let rate: Int, channels: Int
    /// Smaller timestamp jitter is not corrected (20 ms).
    let tolerance: Int64
    public let pathName: String
    public let mutes = MuteLog()
    private var file: FileHandle?
    private let countGate = NSLock()
    private var writtenFrames: Int64 = 0
    public private(set) var startTime = Double.nan
    private var prev: [Float]
    private var phase: Float = 0
    private var outBuf = Data()
    private var finished = false

    public init(path: String, rate: Int = 48000, channels: Int = 2) {
        pathName = path
        self.rate = rate
        self.channels = channels
        tolerance = Int64(rate / 50)
        prev = Array(repeating: 0, count: channels)
    }

    var written: Int64 { countGate.lock(); defer { countGate.unlock() }; return writtenFrames }

    public var seconds: Double { return Double(written) / Double(rate) }
    public var started: Bool { return !startTime.isNaN }

    /// Creates the file (header placeholder). start NaN = sample 0 is the first packet's timestamp.
    public func open(start: Double) throws {
        FileManager.default.createFile(atPath: pathName, contents: nil)
        guard let f = FileHandle(forWritingAtPath: pathName) else {
            throw NSError(domain: "Recitbot", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot create " + pathName])
        }
        try f.write(contentsOf: Data(count: 44))
        file = f
        startTime = start
    }

    /// Mute or unmute from `now` (shared clock) on: frames at or after it are written as zeros.
    public func setMuted(_ muted: Bool, now: Double) {
        mutes.set(muted, started ? now - startTime : 0)
    }

    /// One packet: `frames` interleaved frames of `channels` at srcRate (nil = silence), its first frame at `at` seconds
    /// on the shared clock (nil = no timestamp: appended).
    public func place(_ samples: [Float]?, frames: Int, srcRate: Int, at: Double?) {
        if file == nil || finished { return }
        if startTime.isNaN { startTime = at ?? Clock.now() }
        let o = resample(samples, frames, srcRate)
        let n = o.count / channels
        var skip = 0
        if let at = at {
            let idx = Int64(NetFormat.round((at - startTime) * Double(rate)))
            let w = written
            if idx > w + tolerance { writeGap(idx - w) } else if idx < w - tolerance { skip = Int(min(Int64(n), w - idx)) } // already covered by silence
        }
        if n > skip { writeFrames(o, skip, n - skip) }
    }

    /// Silence up to clock time t (nothing when already there).
    public func padTo(_ t: Double) {
        if file == nil || finished || startTime.isNaN { return }
        let target = Int64(((t - startTime) * Double(rate)).rounded(.towardZero))
        let w = written
        if target > w { writeGap(target - w) }
    }

    func writeGap(_ frames: Int64) {
        var left = frames
        while left > 0 {
            let k = Int(min(left, Int64(rate)))
            writeFrames(nil, 0, k)
            left -= Int64(k)
        }
    }

    /// Linear resampling to `rate`, continuous across packets (the previous packet's last frame is kept).
    func resample(_ st: [Float]?, _ frames: Int, _ srcRate: Int) -> [Float] {
        let ch = channels
        guard let st = st else { return [Float](repeating: 0, count: ch * Int(NetFormat.round(Double(frames) * Double(rate) / Double(srcRate)))) }
        if srcRate == rate { return Array(st.prefix(frames * ch)) }
        let step = Float(srcRate) / Float(rate)
        var o: [Float] = []
        o.reserveCapacity(frames * ch * rate / max(1, srcRate) + 4)
        while phase < Float(frames - 1) {
            let i = Int(phase.rounded(.down))
            let f = phase - Float(i)
            for c in 0..<ch {
                let v0 = i < 0 ? prev[c] : st[ch * i + c]
                let v1 = st[ch * (i + 1) + c]
                o.append(v0 + (v1 - v0) * f)
            }
            phase += step
        }
        phase -= Float(frames)
        if frames > 0 { for c in 0..<ch { prev[c] = st[ch * (frames - 1) + c] } }
        return o
    }

    /// Appends frames (nil = silence) as 16-bit PCM, zeroing whatever falls in a muted span.
    func writeFrames(_ src: [Float]?, _ offset: Int, _ count: Int) {
        if count <= 0 { return }
        let ch = channels, bpf = 2 * ch
        let bytes = count * bpf
        var buf = [UInt8](repeating: 0, count: bytes)
        if let src = src {
            for i in 0..<count {
                for c in 0..<ch {
                    let v = src[ch * (offset + i) + c]
                    let s = Int(NetFormat.round(Double(max(-1, min(1, v)) * 32767)))
                    let u = UInt16(bitPattern: Int16(s))
                    buf[i * bpf + c * 2] = UInt8(u & 0xFF)
                    buf[i * bpf + c * 2 + 1] = UInt8(u >> 8)
                }
            }
            for r in AudioMath.mutedRanges(mutes.allSpans(), written, count, rate) {
                for k in (r.0 * bpf)..<((r.0 + r.1) * bpf) { buf[k] = 0 }
            }
        }
        do { try file?.write(contentsOf: Data(buf)) } catch { Log.write("wav write: " + Config.message(error)) }
        countGate.lock(); writtenFrames += Int64(count); countGate.unlock()
    }

    /// Finalizes the WAV header and closes the file. Safe to call twice.
    public func finish() throws {
        if finished { return }
        finished = true
        guard let f = file else { return }
        defer { try? f.close(); file = nil }
        try f.seek(toOffset: 0)
        try f.write(contentsOf: WavFile.header(rate: rate, channels: channels, dataBytes: Int64(written) * Int64(2 * channels)))
    }
}

/// PCM16 WAV files: the 44-byte header, a reader for the mix. parity: LoopbackCapture.Finish (same header)
public enum WavFile {
    public static func header(rate: Int, channels: Int, dataBytes: Int64) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let data = UInt32(truncatingIfNeeded: dataBytes)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ data); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * 2 * channels)); u16(UInt16(2 * channels)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(data)
        return d
    }

    /// Streams one PCM16 WAV written by PcmTimeline (44-byte header) as float frames.
    public final class Reader {
        public let rate: Int, channels: Int, frames: Int64
        let handle: FileHandle

        public init(path: String) throws {
            guard let h = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: "Recitbot", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot open " + path])
            }
            handle = h
            let head = try h.read(upToCount: 44) ?? Data()
            guard head.count == 44, String(decoding: head[0..<4], as: UTF8.self) == "RIFF" else {
                throw NSError(domain: "Recitbot", code: 3, userInfo: [NSLocalizedDescriptionKey: "not a wav file: " + path])
            }
            func u16(_ o: Int) -> Int { return Int(head[o]) | Int(head[o + 1]) << 8 }
            func u32(_ o: Int) -> Int64 { return Int64(u16(o)) | Int64(u16(o + 2)) << 16 }
            channels = max(1, u16(22))
            rate = Int(u32(24))
            let size = (try? h.seekToEnd()).map { Int64($0) } ?? 44
            frames = max(0, (size - 44) / Int64(2 * channels))
        }

        deinit { try? handle.close() }

        /// Frames [from, from+count) as interleaved floats; past the end (or before 0) is silence.
        public func read(from: Int64, count: Int) -> [Float] {
            var out = [Float](repeating: 0, count: count * channels)
            let lo = max(from, 0), hi = min(from + Int64(count), frames)
            if hi <= lo { return out }
            do {
                try handle.seek(toOffset: UInt64(44 + lo * Int64(2 * channels)))
                let data = try handle.read(upToCount: Int(hi - lo) * 2 * channels) ?? Data()
                let base = Int(lo - from) * channels
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let n = raw.count / 2
                    for i in 0..<n {
                        let v = Int16(bitPattern: UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8)
                        out[base + i] = Float(v) / 32768
                    }
                }
            } catch {
                Log.write("wav read: " + Config.message(error))
            }
            return out
        }
    }
}
