import Foundation

/// The final audio, made natively from the same plan ffmpeg's MixFilter runs on Windows (streamed in blocks: a 30-minute
/// recording never sits in memory). parity: AgentRecorder.cs AudioMath.MixFilter + WindowsFfmpegBackend.MixAudio:
///   mic:    its slices joined (atrim/adelay), mono -> stereo (pan c0=c0|c1=c0), 10 ms blocks inside a muted span
///           silenced (asetnsamples=n=480, volume=0:enable='between(t,a,b)');
///   system: its slices joined, stereo, x SystemGain (0.6) under the mic, else 1;
///   both:   system ducked by the mic (sidechaincompress threshold 0.05, ratio 3, attack 10 ms, release 300 ms, rms,
///           knee 2.82843), summed (amix normalize=0), limited (alimiter limit 0.97, level 0, latency compensated);
///   output: 48 kHz stereo float for the AAC track (padded/cut to the video by the caller: apad + -shortest);
///   [t]:    with a mic only, the mic alone after its muted blocks are silenced, before the system mix, ducking and
///           limiter (takeTranscription; the caller makes it 16 kHz mono PCM16 with Downsampler16k: aresample=16000,
///           -ac 1). Transcripts are mic-only: no mic = no transcription copy at all.
public final class AudioMixer {
    public static let rate = 48000
    let mic: SlicedSource?, sys: SlicedSource?
    let micMuted: [Span]
    let gain: Float
    var comp = SidechainCompressor(rate: AudioMixer.rate)
    var lim = Limiter()
    /// Frames of the mix: the sources are as long as the trimmed timeline (every slice is its segment's length).
    public let totalFrames: Int64
    var produced: Int64 = 0
    /// Pre-limiter frames waiting for the limiter's lookahead (stereo, interleaved).
    var pending: [Float] = []
    var pendingStart: Int64 = 0
    /// The muted mic (stereo, interleaved) read since the last takeTranscription: [m] split off before any mixing.
    var micTap: [Float] = []
    /// Whether there is a transcription copy (a mic): MixFilter's [t] exists only with one.
    public var transcribes: Bool { return mic != nil }

    public init(plan: MixPlan, micWav: String?, sysWav: String?) throws {
        mic = try plan.micSlices.flatMap { ops in try micWav.map { try SlicedSource(path: $0, ops: ops, rate: AudioMixer.rate) } }
        sys = try plan.sysSlices.flatMap { ops in try sysWav.map { try SlicedSource(path: $0, ops: ops, rate: AudioMixer.rate) } }
        // Enable(): merged, then each end written as "0.###" into between(t,a,b).
        micMuted = AudioMath.merge(plan.micMuted).map { Span(AudioMath.filterValue($0.start), AudioMath.filterValue($0.end)) }
        gain = Float(mic != nil ? AudioMath.systemGain : 1.0)
        totalFrames = max(mic?.total ?? 0, sys?.total ?? 0)
    }

    /// Next block of at most maxFrames mixed stereo frames (interleaved), nil at the end.
    public func next(_ maxFrames: Int) -> [Float]? {
        if produced >= totalFrames { return nil }
        let k = Int(min(Int64(maxFrames), totalFrames - produced))
        if mic == nil || sys == nil {
            let out = raw(k)
            produced += Int64(k)
            return out
        }
        // Both sources: the limiter looks Limiter.lookahead frames ahead.
        let need = k + Limiter.lookahead
        let have = pending.count / 2
        if have < need {
            let more = need - have
            let avail = Int(max(0, totalFrames - (pendingStart + Int64(have))))
            var add = raw(min(more, avail))
            if add.count / 2 < more { add += [Float](repeating: 0, count: (more - add.count / 2) * 2) }
            pending += add
        }
        let out = lim.process(pending, k)
        pending.removeFirst(k * 2)
        pendingStart += Int64(k)
        produced += Int64(k)
        return out
    }

    /// The mic-only transcription copy produced since the last call (48 kHz stereo, interleaved; muted blocks silent),
    /// in order. Taken after each next(), it covers the same frames as the mix (the limiter's lookahead reads ahead,
    /// so a block may run up to Limiter.lookahead frames ahead of the mix; the total is the same). Empty without a mic.
    public func takeTranscription() -> [Float] {
        let t = micTap
        micTap.removeAll(keepingCapacity: true)
        return t
    }

    /// The next n frames before the limiter (mic, system, or ducked sum).
    func raw(_ n: Int) -> [Float] {
        var m: [Float]? = nil, s: [Float]? = nil
        if let mic = mic {
            let start = mic.position
            let mono = mic.read(n)
            var st = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { st[2 * i] = mono[i]; st[2 * i + 1] = mono[i] }
            muteBlocks(&st, start, n)
            m = st
            micTap += st
        }
        if let sys = sys {
            var st = sys.read(n)
            for i in 0..<st.count { st[i] *= gain }
            s = st
        }
        guard let mm = m else { return s ?? [Float](repeating: 0, count: n * 2) }
        guard var ss = s else { return mm }
        comp.process(&ss, key: mm)
        for i in 0..<ss.count { ss[i] += mm[i] }
        return ss
    }

    /// Zeroes each 480-frame block (10 ms) whose start time is inside a muted span (between(t, a, b): both ends
    /// included). Blocks are counted from the start of the joined mic track.
    func muteBlocks(_ st: inout [Float], _ from: Int64, _ n: Int) {
        if micMuted.isEmpty { return }
        var i = 0
        while i < n {
            let pos = from + Int64(i)
            let block = pos / 480
            let blockEnd = (block + 1) * 480
            let len = Int(min(Int64(n - i), blockEnd - pos))
            let t = Double(block * 480) / Double(AudioMixer.rate)
            if micMuted.contains(where: { $0.start <= t && t <= $0.end }) {
                for k in (2 * i)..<(2 * (i + len)) { st[k] = 0 }
            }
            i += len
        }
    }
}

/// One source's slices joined: each slice is `duration` long, its first `delayMs` silent, the rest read from the WAV
/// from `start` (silence past the WAV's end). Output: interleaved frames with the WAV's channel count, except a stereo
/// WAV read as mono averages (not used) and a mono WAV is returned mono.
final class SlicedSource {
    let reader: WavFile.Reader
    struct Op { var delay: Int64; var start: Int64; var frames: Int64 }
    let ops: [Op]
    let total: Int64
    var opIndex = 0, inOp: Int64 = 0
    private(set) var position: Int64 = 0
    var channels: Int { return reader.channels }

    init(path: String, ops: [AudioMath.SliceOp], rate: Int) throws {
        reader = try WavFile.Reader(path: path)
        let r = Double(rate)
        self.ops = ops.map { Op(delay: $0.delayMs * Int64(rate) / 1000, start: Int64(NetFormat.round($0.start * r)), frames: max(0, Int64(NetFormat.round($0.duration * r)))) }
        total = self.ops.reduce(0) { $0 + $1.frames }
    }

    /// The next n frames (silence after the last slice).
    func read(_ n: Int) -> [Float] {
        let ch = channels
        var out = [Float](repeating: 0, count: n * ch)
        var filled = 0
        while filled < n && opIndex < ops.count {
            let op = ops[opIndex]
            let left = op.frames - inOp
            if left <= 0 { opIndex += 1; inOp = 0; continue }
            let take = Int(min(Int64(n - filled), left))
            // [inOp, inOp+take) of this slice: silence while inside the delay, then the WAV from op.start.
            let silent = Int(max(0, min(Int64(take), op.delay - inOp)))
            if take > silent {
                let wavFrom = op.start + (inOp + Int64(silent) - op.delay)
                let data = reader.read(from: wavFrom, count: take - silent)
                for k in 0..<data.count { out[(filled + silent) * ch + k] = data[k] }
            }
            filled += take
            inOp += Int64(take)
        }
        position += Int64(n)
        return out
    }
}

/// ffmpeg's sidechaincompress (af_sidechaincompress.c) with the filter's parameters: rms detection, average link,
/// threshold 0.05, ratio 3, attack 10 ms, release 300 ms, knee 2.82843, makeup 1, mix 1.
struct SidechainCompressor {
    let attackCoeff: Double, releaseCoeff: Double
    let thres: Double, ratio = 3.0, knee = 2.82843
    let adjKneeStart: Double, kneeStart: Double, kneeStop: Double, compressedKneeStop: Double
    var linSlope = 0.0

    init(rate: Int, threshold: Double = 0.05, attackMs: Double = 10, releaseMs: Double = 300) {
        attackCoeff = min(1, 1 / (attackMs * Double(rate) / 4000))
        releaseCoeff = min(1, 1 / (releaseMs * Double(rate) / 4000))
        thres = log(threshold)
        let linKneeStart = threshold / knee.squareRoot(), linKneeStop = threshold * knee.squareRoot()
        adjKneeStart = linKneeStart * linKneeStart
        kneeStart = log(linKneeStart)
        kneeStop = log(linKneeStop)
        compressedKneeStop = (kneeStop - thres) / ratio + thres
    }

    func outputGain(_ lin: Double) -> Double {
        let slope = log(lin) * 0.5
        var gain = (slope - thres) / ratio + thres
        let delta = 1 / ratio
        if knee > 1 && slope < kneeStop {
            gain = SidechainCompressor.hermite(slope, kneeStart, kneeStop, kneeStart, compressedKneeStop, 1.0, delta)
        }
        return exp(gain - slope)
    }

    static func hermite(_ x: Double, _ x0: Double, _ x1: Double, _ p0: Double, _ p1: Double, _ m0: Double, _ m1: Double) -> Double {
        let width = x1 - x0, t = (x - x0) / width
        let mm0 = m0 * width, mm1 = m1 * width
        let t2 = t * t, t3 = t2 * t
        let ct0 = p0, ct1 = mm0
        let ct2 = -3 * p0 - 2 * mm0 + 3 * p1 - mm1
        let ct3 = 2 * p0 + mm0 - 2 * p1 + mm1
        return ct3 * t3 + ct2 * t2 + ct1 * t + ct0
    }

    /// Ducks `src` (stereo, interleaved) by the level of `key` (stereo, same length).
    mutating func process(_ src: inout [Float], key: [Float]) {
        let n = src.count / 2
        for i in 0..<n {
            var a = (Double(abs(key[2 * i])) + Double(abs(key[2 * i + 1]))) / 2
            a *= a
            linSlope += (a - linSlope) * (a > linSlope ? attackCoeff : releaseCoeff)
            var g = 1.0
            if linSlope > 0 && linSlope > adjKneeStart { g = outputGain(linSlope) }
            src[2 * i] = Float(Double(src[2 * i]) * g)
            src[2 * i + 1] = Float(Double(src[2 * i + 1]) * g)
        }
    }
}

/// A lookahead peak limiter in the spirit of ffmpeg's alimiter (limit 0.97, attack 5 ms, release 50 ms, level 0 = no
/// auto gain, latency compensated): the gain reaches what the loudest frame of the next 5 ms needs before that frame
/// plays, then recovers over 50 ms; a final clamp keeps every sample within the limit.
struct Limiter {
    static let lookahead = 240
    static let chunk = 48
    let limit: Float = 0.97
    let attack: Float = 1 / 60
    let release: Float = 1 - Float(exp(-1.0 / (0.05 * 48000)))
    var env: Float = 1

    /// The first k frames of buf (stereo; buf holds at least k + lookahead frames).
    mutating func process(_ buf: [Float], _ k: Int) -> [Float] {
        let frames = buf.count / 2
        let chunks = (frames + Limiter.chunk - 1) / Limiter.chunk
        var need = [Float](repeating: 1, count: chunks)
        for i in 0..<frames {
            let p = max(abs(buf[2 * i]), abs(buf[2 * i + 1]))
            if p > limit { let c = i / Limiter.chunk; need[c] = min(need[c], limit / p) }
        }
        var out = [Float](repeating: 0, count: k * 2)
        let span = Limiter.lookahead / Limiter.chunk + 1
        for i in 0..<k {
            let c = i / Limiter.chunk
            var target: Float = 1
            for j in c..<min(chunks, c + span) { target = min(target, need[j]) }
            if target < env { env += (target - env) * attack; env = min(env, max(target, env)) } else { env += (target - env) * release }
            for ch in 0..<2 {
                let v = buf[2 * i + ch] * env
                out[2 * i + ch] = max(-limit, min(limit, v))
            }
        }
        return out
    }
}

/// 48 kHz stereo -> 16 kHz mono PCM16 (aresample=16000, -ac 1): channel average, windowed-sinc low-pass, every 3rd
/// sample. Streamed: the filter history carries across blocks.
public final class Downsampler16k {
    static let taps: [Float] = {
        let n = 63, fc = 7200.0 / 48000.0
        var t = [Float](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let m = Double(i - n / 2)
            let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            t[i] = Float(sinc * w)
            sum += sinc * w
        }
        return t.map { $0 / Float(sum) }
    }()
    var hist = [Float](repeating: 0, count: 62)
    var phase = 0

    public init() {}

    /// One block of stereo frames -> its 16 kHz mono PCM16 samples.
    public func process(_ stereo: [Float]) -> [Int16] {
        let n = stereo.count / 2
        var x = hist
        x.reserveCapacity(hist.count + n)
        for i in 0..<n { x.append((stereo[2 * i] + stereo[2 * i + 1]) / 2) }
        var out: [Int16] = []
        out.reserveCapacity(n / 3 + 1)
        let taps = Downsampler16k.taps, h = hist.count
        for i in 0..<n {
            if (phase + i) % 3 != 0 { continue }
            var acc: Float = 0
            let base = i + h - (taps.count - 1)
            for k in 0..<taps.count { acc += taps[k] * x[base + k] }
            let v = (acc * 32768).rounded(.toNearestOrEven)
            out.append(Int16(max(-32768, min(32767, v))))
        }
        phase = (phase + n) % 3
        hist = Array(x.suffix(h))
        return out
    }
}

/// A PCM16 WAV written in pieces; the header is completed by finish().
public final class WavWriter {
    let handle: FileHandle
    let rate: Int, channels: Int
    public private(set) var frames: Int64 = 0

    public init(path: String, rate: Int, channels: Int) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "Recitbot", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot create " + path])
        }
        handle = h
        self.rate = rate
        self.channels = channels
        try h.write(contentsOf: Data(count: 44))
    }

    public func write(_ samples: [Int16]) throws {
        if samples.isEmpty { return }
        var d = Data(count: samples.count * 2)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for (i, s) in samples.enumerated() {
                let u = UInt16(bitPattern: s)
                raw[2 * i] = UInt8(u & 0xFF)
                raw[2 * i + 1] = UInt8(u >> 8)
            }
        }
        try handle.write(contentsOf: d)
        frames += Int64(samples.count / channels)
    }

    public func finish() throws {
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavFile.header(rate: rate, channels: channels, dataBytes: frames * Int64(2 * channels)))
    }
}
