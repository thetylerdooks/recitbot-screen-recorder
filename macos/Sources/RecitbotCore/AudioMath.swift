import Foundation

/// A time span in seconds (end may be +infinity while it is still open). parity: AgentRecorder.cs Span
public struct Span: Equatable, Sendable, CustomStringConvertible {
    public var start: Double, end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var description: String { return NetFormat.fixed(start, 3) + "-" + NetFormat.fixed(end, 3) }
}

/// One recorded segment on the shared clock (Clock.now seconds): where its video starts and how long it is. Segments
/// are joined back to back, so segment i starts at the sum of the earlier durations in the uploaded video.
/// parity: AgentRecorder.cs Segment
public struct Segment: Equatable, Sendable {
    public var wallStart: Double, duration: Double
    public init(_ wallStart: Double, _ duration: Double) { self.wallStart = wallStart; self.duration = duration }
}

/// Mute on/off history of one source. Toggling only appends; spans are read at any time (thread-safe).
/// parity: AgentRecorder.cs MuteLog
public final class MuteLog: @unchecked Sendable {
    private let gate = NSLock()
    private var spans: [Span] = []
    private var openSince = Double.nan

    public init() {}

    public var muted: Bool { gate.lock(); defer { gate.unlock() }; return !openSince.isNaN }

    /// Returns false when nothing changed.
    @discardableResult
    public func set(_ muted: Bool, _ t: Double) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if muted == !openSince.isNaN { return false }
        if muted { openSince = t } else { spans.append(Span(openSince, max(openSince, t))); openSince = .nan }
        return true
    }

    /// Closed spans, plus the open one (to +infinity) while muted.
    public func allSpans() -> [Span] {
        gate.lock()
        defer { gate.unlock() }
        var l = spans
        if !openSince.isNaN { l.append(Span(openSince, .infinity)) }
        return l
    }
}

/// Pure audio timeline math (covered by the selftest): mute spans, frame ranges to zero, start trim, slices.
/// parity: AgentRecorder.cs AudioMath (wes-8b83b0f). MixFilter's ffmpeg filter string has no macOS counterpart: the same
/// plan (slices with their leading delay, the mic's muted spans, system gain, ducking, limiter, 16 kHz copy) is run
/// natively by AudioMixer. KeyframeTimes parses ffmpeg framecrc output; on macOS the encoder reports its keyframes.
/// The early keyframes: a forced keyframe on every max(1, round(fps/10))-th frame for the first 2 s, so the start trim
/// can cut close to the mic's first sample. parity: AgentRecorder.cs VideoChain.EarlyKeys
/// (-force_key_frames "expr:lt(t,2)*not(mod(n,every))"), applied per frame with kVTEncodeFrameOptionKey_ForceKeyFrame.
public enum EarlyKeys {
    public static func every(_ fps: Int) -> Int { return max(1, Int(NetFormat.round(Double(fps) / 10.0))) }
    /// Frame n at t seconds from the first frame.
    public static func forced(_ n: Int, _ t: Double, _ every: Int) -> Bool { return t < 2 && n % every == 0 }
}

public enum AudioMath {
    /// Sorted, overlaps and touching spans merged, empty spans dropped.
    public static func merge(_ spans: [Span]) -> [Span] {
        let l = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var o: [Span] = []
        for s in l {
            if let last = o.last, s.start <= last.end { o[o.count - 1] = Span(last.start, max(last.end, s.end)) } else { o.append(s) }
        }
        return o
    }

    /// Frames [from, from+count) at `rate` that fall in a span: (offset into the block, length) pairs. A frame is muted
    /// when its start time is inside [start, end).
    public static func mutedRanges(_ spans: [Span], _ from: Int64, _ count: Int, _ rate: Int) -> [(Int, Int)] {
        var r: [(Int, Int)] = []
        for s in merge(spans) {
            let a = Int64((s.start * Double(rate)).rounded(.up))
            let b = s.end.isInfinite && s.end > 0 ? Int64.max : Int64((s.end * Double(rate)).rounded(.up))
            let lo = max(a, from), hi = min(b, from + Int64(count))
            if hi > lo { r.append((Int(lo - from), Int(hi - lo))) }
        }
        return r
    }

    /// Wall-clock spans (Clock.now seconds) -> spans in the joined video, widened by padBefore/padAfter (clamped to
    /// each segment) and merged. Parts outside every segment (between segments, after the end) are dropped.
    public static func toTimeline(_ wall: [Span], _ segs: [Segment], _ padBefore: Double, _ padAfter: Double) -> [Span] {
        var o: [Span] = []
        var at = 0.0
        for g in segs {
            for w in wall {
                let a = max(w.start - padBefore, g.wallStart), b = min(w.end + padAfter, g.wallStart + g.duration)
                if b > a { o.append(Span(at + a - g.wallStart, at + b - g.wallStart)) }
            }
            at += g.duration
        }
        return merge(o)
    }

    /// Slices (seconds in a WAV whose sample 0 was at `wavStart` on the shared clock) for each segment: segment i plays
    /// the WAV from its video start. Mic and system audio are both continuous WAVs cut this way.
    public static func slices(_ segs: [Segment], _ wavStart: Double) -> [Span] {
        return segs.map { Span($0.wallStart - wavStart, $0.wallStart - wavStart + $0.duration) }
    }

    /// The most the video's head is ever cut off at the start (startTrim).
    public static let maxTrim = 0.5

    /// Where the uploaded video starts (seconds into the joined video) so that it does not open before the mic does: 0
    /// when the mic's first sample (`micStart`, shared clock) is at or before the video's (`videoStart`), else the first
    /// keyframe at or after the difference (the cut is a stream copy), at most maxTrim. A mic later than that is
    /// `capped`: the last keyframe at or below maxTrim (0 at worst), and the mix delays the mic for the rest. Only the
    /// mic decides (NaN = no mic: 0): system audio never trims, it is delayed.
    public static func startTrim(_ videoStart: Double, _ micStart: Double, _ keyframes: [Double]) -> (trim: Double, capped: Bool) {
        let late = micStart - videoStart
        if !(late > 0) { return (0, false) }
        var best = -1.0, floor = 0.0
        for k in keyframes {
            if k > maxTrim { continue }
            if k >= late && (best < 0 || k < best) { best = k }
            if k > floor { floor = k }
        }
        if best >= 0 { return (best, false) }
        return (floor, true)
    }

    /// The segments with the first `trim` seconds of the joined video cut off (segments wholly inside it dropped).
    public static func trimStart(_ segs: [Segment], _ trim: Double) -> [Segment] {
        var trim = trim
        var o: [Segment] = []
        for g in segs {
            let cut = min(max(trim, 0), g.duration)
            trim -= cut
            if g.duration - cut > 0 { o.append(Segment(g.wallStart + cut, g.duration - cut)) }
        }
        return o
    }

    /// The joined video's length: the stored duration_s, and the length of the mixed track and transcription WAV.
    public static func length(_ segs: [Segment]) -> Double {
        return segs.reduce(0) { $0 + $1.duration }
    }

    /// System audio under the mic (full gain when it is alone).
    public static let systemGain = 0.6

    /// One slice as the mix cuts it: leading silence for a slice that starts before the WAV does (system audio that
    /// started late, a mic later than maxTrim), then `duration` seconds of the WAV from `start`, so every slice is
    /// exactly its segment's length. parity: AudioMath.Sliced (adelay=delays=<ms>:all=1, atrim=start:duration).
    public struct SliceOp: Equatable {
        public var delayMs: Int64
        public var start: Double, duration: Double
        public init(delayMs: Int64, start: Double, duration: Double) { self.delayMs = delayMs; self.start = start; self.duration = duration }
    }

    public static func sliceOps(_ slices: [Span]) -> [SliceOp] {
        return slices.map { s in
            SliceOp(delayMs: s.start < 0 ? Int64(NetFormat.round(-s.start * 1000)) : 0, start: filterValue(max(0, s.start)),
                    duration: filterValue(s.end - s.start))
        }
    }

    /// A number as MixFilter writes it into the filter string (ToString("0.###"): at most 3 decimals, half away from
    /// zero), so the native mix cuts and mutes at the very times ffmpeg is given on Windows.
    public static func filterValue(_ v: Double) -> Double {
        guard v.isFinite else { return v }
        return Double(NetFormat.upTo(v, 3)) ?? v
    }
}

/// What the final audio is made of (MixFilter's inputs). parity: Recorder.MixAudio
public struct MixPlan {
    /// The mic's muted spans on the video timeline (already widened 100 ms early / 50 ms late), nil = no mic.
    public var micMuted: [Span]
    public var micSlices: [AudioMath.SliceOp]?
    public var sysSlices: [AudioMath.SliceOp]?
    public init(micMuted: [Span], micSlices: [AudioMath.SliceOp]?, sysSlices: [AudioMath.SliceOp]?) {
        self.micMuted = micMuted; self.micSlices = micSlices; self.sysSlices = sysSlices
    }
    /// SystemGain under the mic, 1 when system audio is alone.
    public var sysGain: Double { return micSlices != nil ? AudioMath.systemGain : 1.0 }
}

/// Start path of one recording, in ms after the start command. Logged once as one "start timing" line when the first
/// frame, the start and the bubble (if one was asked for) are all settled, or when the recording ends; a missing step
/// is "-". parity: AgentRecorder.cs StartTimes (wes-8b83b0f names: t_pill, t_ffmpeg_launch = capture launch)
public final class StartTimes: @unchecked Sendable {
    public static let names = ["t_cmd", "t_pill", "t_encoder", "t_ffmpeg_launch", "t_first_frame", "t_started", "t_bubble"]
    private let gate = NSLock()
    private var at: [Double]
    private var bubbleOpen = false, logged = false
    /// Fired once, right after the line is logged.
    public var onLogged: ((StartTimes) -> Void)?

    public init(_ cmd: Double) {
        at = Array(repeating: .nan, count: StartTimes.names.count)
        at[0] = cmd
    }

    /// A bubble was asked for: the line waits for it (mark("t_bubble") or bubbleSettled).
    public func expectBubble() { gate.lock(); bubbleOpen = true; gate.unlock() }

    /// First time only; later marks of the same step are ignored.
    public func mark(_ name: String, _ now: Double = Clock.now()) {
        gate.lock()
        if let i = StartTimes.names.firstIndex(of: name) {
            if at[i].isNaN { at[i] = now }
            if name == "t_bubble" { bubbleOpen = false }
        }
        gate.unlock()
        tryLog(false)
    }

    /// The bubble failed or was abandoned: t_bubble stays "-".
    public func bubbleSettled() { gate.lock(); bubbleOpen = false; gate.unlock(); tryLog(false) }

    /// ms after the command, NaN when the step was not reached.
    public func ms(_ name: String) -> Double {
        gate.lock()
        defer { gate.unlock() }
        guard let i = StartTimes.names.firstIndex(of: name) else { return .nan }
        return (at[i] - at[0]) * 1000
    }

    public func line() -> String {
        gate.lock()
        defer { gate.unlock() }
        var parts: [String] = []
        for (i, n) in StartTimes.names.enumerated() {
            parts.append(n + "=" + (at[i].isNaN ? "-" : String(Int64(NetFormat.round((at[i] - at[0]) * 1000)))))
        }
        return parts.joined(separator: " ")
    }

    /// Logs whatever was reached (the recording ended or failed first).
    public func flush() { tryLog(true) }

    private func tryLog(_ force: Bool) {
        gate.lock()
        if logged { gate.unlock(); return }
        let ff = StartTimes.names.firstIndex(of: "t_first_frame")!, st = StartTimes.names.firstIndex(of: "t_started")!
        if !force && (bubbleOpen || at[ff].isNaN || at[st].isNaN) { gate.unlock(); return }
        logged = true
        gate.unlock()
        Log.write("start timing (ms after the start command): " + line())
        onLogged?(self)
    }
}

/// "mic@5,sys@6.5" -> [(mic, 5), (sys, 6.5)] in time order; unknown entries are skipped. parity: Program.Toggles
public enum Toggles {
    public static let mic = "mic", sys = "sys", stop = "stop"

    public static func parse(_ spec: String?) -> [(String, Double)] {
        var l: [(String, Double)] = []
        for part in (spec ?? "").split(separator: ",", omittingEmptySubsequences: false) {
            let kv = NetParse.trim(String(part)).split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2, kv[0] == mic || kv[0] == sys, let t = parseDouble(kv[1]), t >= 0 else { continue }
            l.append((kv[0], t))
        }
        // List.Sort by time (stable here; equal times keep their order).
        return l.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset }.map { $0.element }
    }

    /// double.TryParse(NumberStyles.Float, invariant): optional white space, sign, digits, '.', exponent.
    static func parseDouble(_ s: String) -> Double? {
        let t = NetParse.trim(s)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ "0123456789+-.eE".unicodeScalars.contains($0) }) else { return nil }
        return Double(t)
    }
}
