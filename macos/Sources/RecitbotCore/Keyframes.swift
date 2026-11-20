import Foundation

/// End-of-recording keyframes (hello "keyframes", docs/keyframes.md): once the MP4 upload has succeeded, up to `count`
/// evenly spaced JPEG stills of the final MP4 go up one PUT each, /upload/<id>/keyframes/<n>?t=<ms>. Best effort: a
/// skipped, bad or refused still is logged and never fails the recording (`run` never throws). The policy is pure; the
/// probe, the frame grab and the PUT come in as closures. parity: AgentRecorder.cs Stills
/// (the C# probe parses ffmpeg -i's listing; here the probe is AVAsset's duration and video tracks: MacStills.probe)
public enum Stills {
    public static let count = 6, maxWidth = 1280, quality = 75
    public static let maxBytes: Int64 = 1024 * 1024
    public static let minSeconds = 2.0

    /// Frame times in ms from the start of the video: the centres of `count` equal buckets, duration * (2i - 1) / (2 * count)
    /// for i = 1..count, floored to the ms. Never 0 and never the exact end. None under minSeconds (or of unknown length).
    public static func times(_ seconds: Double) -> [Int64] {
        if !seconds.isFinite || seconds < minSeconds { return [] }
        return (1...count).map { i in Int64((seconds * 1000 * Double(2 * i - 1) / Double(2 * count)).rounded(.down)) }
    }

    /// Why no stills are taken, or nil to take them: no video track (audio only) or shorter than minSeconds.
    public static func skip(_ seconds: Double, _ hasVideo: Bool) -> String? {
        if !hasVideo { return "audio only" }
        if !seconds.isFinite || seconds < minSeconds { return "shorter than 2 s" }
        return nil
    }

    public enum Result { case stored, unsupported, failed }

    /// 2xx stored; 404 / 501 = this server has no keyframes route (yet): the rest are skipped without an error;
    /// anything else (no response = 0, other 4xx, 5xx) is a failure: logged, the rest skipped.
    public static func outcome(_ status: Int) -> Result {
        if status >= 200 && status < 300 { return .stored }
        if status == 404 || status == 501 { return .unsupported }
        return .failed
    }

    /// One still: its slot n (1..count, kept when another slot's frame was bad), time and JPEG file.
    public struct Frame {
        public var n: Int
        public var ms: Int64
        public var file: String
    }

    /// The PUT's path under /upload/<id>/.
    public static func route(_ f: Frame) -> String { return "keyframes/" + String(f.n) + "?t=" + String(f.ms) }

    /// The PUTs (path, jpg) -> HTTP status (0 = no response), in order, once each (no retries). Stops at the first one
    /// that is not stored. Returns the log line.
    public static func send(_ put: (String, String) throws -> Int, _ frames: [Frame]) -> String {
        var sent = 0
        for f in frames {
            var st = 0
            do { st = try put(route(f), f.file) } catch { Log.write("keyframes: " + message(error)); st = 0 }
            switch outcome(st) {
            case .stored: sent += 1
            case .unsupported: return "keyframes: not supported by this server (" + String(st) + "); skipped"
            case .failed:
                return "keyframes: " + String(sent) + " of " + String(frames.count) + " sent; stopped at " + String(f.n)
                    + " (" + (st == 0 ? "no response" : "HTTP " + String(st)) + ")"
            }
        }
        return "keyframes: " + String(sent) + " of " + String(frames.count) + " sent"
    }

    /// A file the PUT may carry: a JPEG (FF D8 FF) of 3 bytes .. maxBytes.
    public static func usable(_ file: String) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file), let n = (a[.size] as? NSNumber)?.int64Value,
              n >= 3, n <= maxBytes, let h = FileHandle(forReadingAtPath: file) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 3), head.count == 3 else { return false }
        return head[head.startIndex] == 0xFF && head[head.startIndex + 1] == 0xD8 && head[head.startIndex + 2] == 0xFF
    }

    /// The whole step for one uploaded recording: probe (video -> length in seconds, NaN when unknown, and whether it has
    /// a video track), skip or grab the stills (video, ms, jpg; a frame that throws or is not usable is logged and left
    /// out), PUT them, delete them. fallbackSeconds: the recording's own length when the probe has none. Never throws;
    /// returns the log line.
    public static func run(probe: (String) throws -> (seconds: Double, hasVideo: Bool), grab: (String, Int64, String) throws -> Void,
                           put: (String, String) throws -> Int, video: String, fallbackSeconds: Double, dir: String, id: String) -> String {
        var frames: [Frame] = []
        defer { for f in frames { try? FileManager.default.removeItem(atPath: f.file) } }
        let p: (seconds: Double, hasVideo: Bool)
        do { p = try probe(video) } catch { return "keyframes: skipped (" + message(error) + ")" }
        let seconds = p.seconds.isNaN ? fallbackSeconds : p.seconds
        if let why = skip(seconds, p.hasVideo) { return "keyframes: skipped (" + why + ")" }
        for (i, ms) in times(seconds).enumerated() {
            let f = Frame(n: i + 1, ms: ms, file: (dir as NSString).appendingPathComponent(id + ".k" + String(i + 1) + ".jpg"))
            do {
                try grab(video, f.ms, f.file)
                if usable(f.file) { frames.append(f); continue }
                Log.write("keyframes: frame " + String(f.n) + " at " + String(f.ms) + " ms is not a usable JPEG; left out")
            } catch {
                Log.write("keyframes: frame " + String(f.n) + " at " + String(f.ms) + " ms: " + message(error) + "; left out")
            }
            try? FileManager.default.removeItem(atPath: f.file)
        }
        if frames.isEmpty { return "keyframes: no usable frame; nothing sent" }
        return send(put, frames)
    }

    /// An error's text for the log: a Swift error's own description (UploadError, the app's CaptureError), else
    /// Config.message (NSError's localized description).
    static func message(_ e: Error) -> String {
        if !(type(of: e) is NSError.Type), let c = e as? CustomStringConvertible { return c.description }
        return Config.message(e)
    }
}
