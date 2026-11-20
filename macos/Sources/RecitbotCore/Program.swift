import Foundation

/// parity: AgentRecorder.cs Program (Version, Features, HelloJson) and the frames Agent builds.
public enum Program {
    public static let version = "0.6.1"
    /// What this recorder understands beyond the v1 command (the Worker only sends what is listed here).
    public static let features = ["system_audio", "webcam_shape", "webcam_pct", "ready_push", "chunked_upload", "self_update", "self_uninstall", "multi_account", "update_defer_rollback", "keyframes"]

    public static func helloJson() -> String {
        return "{\"type\":\"hello\",\"version\":" + Json.esc(version) + ",\"features\":["
            + features.map { Json.esc($0) }.joined(separator: ",") + "]}"
    }

    /// Exit codes of Program.Main.
    public static let exitOk: Int32 = 0, exitFailed: Int32 = 1, exitAlreadyRunning: Int32 = 2, exitNotEnrolled: Int32 = 3,
        exitBadArgs: Int32 = 4, exitEnrollFailed: Int32 = 5, exitBadSetting: Int32 = 6

    /// Program.Arg: the value after the first `name` (nil when absent or last).
    public static func arg(_ args: [String], _ name: String) -> String? {
        var i = 0
        while i < args.count - 1 { if args[i] == name { return args[i + 1] }; i += 1 }
        return nil
    }
}

/// Frames and URLs of the device protocol (worker/src/device-hub.ts, index.ts).
public enum Frames {
    /// {"type":"status","recording_id":...,"status":...[,"error":...]}. parity: AgentRecorder.cs Agent.SendStatus
    public static func status(_ id: String?, _ status: String, _ error: String?) -> String {
        return "{\"type\":\"status\",\"recording_id\":" + Json.esc(id) + ",\"status\":" + Json.esc(status)
            + (error != nil ? ",\"error\":" + Json.esc(error) : "") + "}"
    }

    /// wss://host/device/ws from the configured server. parity: AgentRecorder.cs Agent.RunAsync (TrimEnd('/') + Replace)
    public static func socketUrl(_ server: String) -> String {
        return trimEndSlash(server).replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            + "/device/ws"
    }

    /// string.TrimEnd('/').
    public static func trimEndSlash(_ s: String) -> String {
        var t = Substring(s)
        while t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }

    /// The pairing code from stdin: alphanumerics only (a UTF-8 parent shell can prepend a BOM or junk).
    public static func sanitizeCode(_ line: String?) -> String {
        return String(String.UnicodeScalarView((line ?? "").unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }))
    }

    /// POST /device/enroll body; the name is cut to 64 UTF-16 code units like name.Substring(0, 64). Always carries
    /// platform "macos"; device_token only when one is already held (a re-pair), so the server matches by token.
    public static func enrollBody(code: String, name: String, deviceToken: String? = nil) -> String {
        let u = Array(name.utf16)
        let n = u.count > 64 ? String(decoding: u[0..<64], as: UTF16.self) : name
        var body = "{\"code\":" + Json.esc(code) + ",\"name\":" + Json.esc(n) + ",\"platform\":\"macos\""
        if let t = deviceToken, !t.isEmpty { body += ",\"device_token\":" + Json.esc(t) }
        return body + "}"
    }

    /// The text after "enroll failed: " for a non-2xx enroll answer: the body's JSON "error" string when there is a
    /// non-empty one (the Worker's `{ "error": "..." }`, e.g. a device-limit "remove one" message), else the status code.
    /// Never echoes the request, so the pairing code cannot reach the log. parity: AgentRecorder.cs Program.Enroll
    public static func enrollError(_ status: Int, _ body: String) -> String {
        if let f = try? Json.parseFlat(body), let e = f["error"] ?? nil, !e.isEmpty { return e }
        return String(status)
    }

    /// Uri.IsLoopback for a host: localhost, 127.0.0.0/8, ::1.
    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased() else { return false }
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        let p = h.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p[0] == "127" && p.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 } && Int(part)! <= 255
        }
    }
}

/// Per-recording webcam choice: nil camera / 0 px fall back to the device config. parity: AgentRecorder.cs Recorder.WebcamOpts
public struct WebcamOpts: Equatable, Sendable {
    public var on = false
    public var camera: String?
    public var px = 0
    /// Percent of the monitor's short side (start_recording webcam_size as a number); 0 = use px / the config.
    public var pct = 0
    /// "circle" / "rect"; nil = the shape last chosen on this Mac.
    public var shape: String?
    public init() {}
}

/// What to record. parity: AgentRecorder.cs Recorder.StartOpts
public struct StartOpts: Equatable, Sendable {
    public var mic = false
    public var systemAudio = false
    public var micDevice: String?, monitor: String?, window: String?
    public var cam = WebcamOpts()
    /// The start command's upload_part_bytes: files larger than this go up in parts; 0 = one PUT each.
    public var partBytes: Int64 = 0
    public init() {}

    /// The verified "start" frame's options. parity: AgentRecorder.cs Agent.Handle (type == "start")
    public static func from(_ f: JsonFields, configWebcam: Bool) -> StartOpts {
        let webcam = Fields.opt(f, "webcam"), size = Fields.opt(f, "webcam_size"), shape = Fields.opt(f, "webcam_shape")
        let px = WebcamSize.pxForName(size)
        var pct = NetParse.int32(size ?? "") ?? 0
        if px > 0 || NetParse.int32(size ?? "") == nil || pct < 1 || pct > 100 { pct = 0 }
        var partBytes = NetParse.int64(Fields.opt(f, "upload_part_bytes") ?? "") ?? 0
        if partBytes < 0 { partBytes = 0 }
        var o = StartOpts()
        o.mic = Fields.get(f, "mic") == "true"
        o.systemAudio = Fields.opt(f, "system_audio") == "true"
        o.micDevice = Fields.opt(f, "mic_device")
        o.monitor = Fields.opt(f, "monitor")
        o.window = Fields.opt(f, "window")
        o.partBytes = partBytes
        o.cam.on = webcam == nil ? configWebcam : webcam == "true"
        o.cam.camera = Fields.opt(f, "camera")
        o.cam.px = px > 0 ? px : 0
        o.cam.pct = pct
        o.cam.shape = shape == "rect" || shape == "circle" ? shape : nil
        return o
    }
}
