import Foundation

/// An upload error. The text is the C# exception message, so the "failed" status frame carries the same error string
/// (UPLOAD_FAILED: ..., UPLOAD_REJECTED_<status>). parity: AgentRecorder.cs Uploader (throw new Exception(...))
public struct UploadError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ s: String) { description = s }
}

/// The upload policy of one recording's files (pure: HTTP goes through `send`, waits through `sleep`; the selftest drives
/// it with failures). A file up to the part size (or any file when the server sent none) is one PUT. A larger one goes
/// up in parts through the Worker's R2 multipart upload: create, PUT parts 1..N in order (a failed part is sent again
/// with the same number), complete {parts: N}. A 502 means the Worker aborted the multipart upload: start over from
/// create. parity: AgentRecorder.cs Uploader (and worker/src/upload.ts)
public final class Uploader {
    /// One request to /upload/:id/{path}. Body: bytes [offset, offset + count) of file, else json. Returns the HTTP
    /// status, 0 when there was no response; throws only for a local failure (the file shorter than expected), which
    /// fails the recording as the C#'s IOException does. parity: Uploader.SendFn
    public typealias SendFn = (_ method: String, _ path: String, _ file: String?, _ offset: Int64, _ count: Int64, _ json: String?) throws -> Int

    /// Tries of one request (after no response or a 5xx), and multipart uploads started per file.
    public static let attempts = 3, restarts = 3
    let send: SendFn
    let partBytes: Int64
    /// Milliseconds; Thread.Sleep in the C#. Backoff before try a (a > 0) is 2000 * a ms: 2 s, then 4 s.
    public var sleep: (Int) -> Void = { usleep(useconds_t($0) * 1000) }

    public init(_ send: @escaping SendFn, _ partBytes: Int64) { self.send = send; self.partBytes = partBytes }

    /// [offset, count] of each part: every part but the last is partBytes, the last holds the rest (1..partBytes).
    public static func parts(_ length: Int64, _ partBytes: Int64) -> [(offset: Int64, count: Int64)] {
        var l: [(offset: Int64, count: Int64)] = []
        var o: Int64 = 0
        while o < length { l.append((o, min(partBytes, length - o))); o += partBytes }
        return l
    }

    /// kind = "video" | "audio".
    public func file(_ kind: String, _ file: String, _ length: Int64) throws {
        if partBytes <= 0 || length <= partBytes { _ = try call("PUT", kind, file, 0, length, nil, false); return }
        let ps = Uploader.parts(length, partBytes)
        for r in 0..<Uploader.restarts {
            if r > 0 { Log.write(kind + ": the server aborted the multipart upload; starting it again") }
            if try call("POST", kind + "/mp", nil, 0, 0, "{\"total_bytes\":" + String(length) + "}", true) == 502 { continue }
            var aborted = false
            var i = 0
            while i < ps.count && !aborted {
                aborted = try call("PUT", kind + "/mp/" + String(i + 1), file, ps[i].offset, ps[i].count, nil, true) == 502
                i += 1
            }
            if aborted { continue }
            if try call("POST", kind + "/mp/complete", nil, 0, 0, "{\"parts\":" + String(ps.count) + "}", true) == 502 { continue }
            Log.write(kind + ": " + String(length) + " bytes in " + String(ps.count) + " parts of up to " + String(partBytes))
            return
        }
        throw UploadError("UPLOAD_FAILED: " + kind + " multipart upload aborted " + String(Uploader.restarts) + " times")
    }

    public func complete(_ json: String) throws { _ = try call("POST", "complete", nil, 0, 0, json, false) }

    /// The requests of one recording: the video, the transcription WAV (the mic only) when there is one, then complete.
    /// No mic (hasTranscript false), or a WAV that is missing (audioBytes 0) or header-only: no audio request at all, and
    /// complete as always (the Worker stores it without a transcript). parity: AgentRecorder.cs Recorder.Send
    public func recording(video: String, videoBytes: Int64, audio: String, audioBytes: Int64, hasTranscript: Bool, hasSystemAudio: Bool,
                          duration: Double) throws {
        try file("video", video, videoBytes)
        if hasTranscript && audioBytes > 44 { try file("audio", audio, audioBytes) }
        else { Log.write("upload: no transcription audio (" + (hasTranscript ? "the WAV is empty or missing" : "no mic") + "); video only") }
        try complete(Uploader.completeJson(duration: duration, hasSystemAudio: hasSystemAudio))
    }

    /// The /complete body: duration_s with one decimal (ToString("0.0")) and has_system_audio.
    public static func completeJson(duration: Double, hasSystemAudio: Bool) -> String {
        return "{\"duration_s\":" + NetFormat.fixed(duration, 1) + ",\"has_system_audio\":" + (hasSystemAudio ? "true" : "false") + "}"
    }

    /// Sends one request, again (the same request) after no response or a 5xx. A 4xx is final (thrown); a 502 is
    /// returned when abortable (the multipart upload is gone).
    func call(_ method: String, _ path: String, _ file: String?, _ offset: Int64, _ count: Int64, _ json: String?, _ abortable: Bool) throws -> Int {
        var st = 0
        for a in 0..<Uploader.attempts {
            if a > 0 { sleep(2000 * a) }
            st = try send(method, path, file, offset, count, json)
            if st >= 200 && st < 300 { return st }
            if abortable && st == 502 { return st }
            if st >= 400 && st < 500 { throw UploadError("UPLOAD_REJECTED_" + String(st)) }
        }
        throw UploadError("UPLOAD_FAILED: " + method + " " + path + " (" + (st == 0 ? "no response" : String(st)) + ")")
    }

    /// The request's Content-Type: JSON bodies are application/json; file bodies image/jpeg under "/keyframes/" (Stills),
    /// video/mp4 when the URL has "/video", else audio/wav (the Worker answers 415 BAD_CONTENT_TYPE otherwise).
    /// parity: Recorder.ContentType
    public static func contentType(url: String, hasFile: Bool) -> String {
        if !hasFile { return "application/json" }
        if url.contains("/keyframes/") { return "image/jpeg" }
        return url.contains("/video") ? "video/mp4" : "audio/wav"
    }

    /// server + "/upload/" + id + "/" (server.TrimEnd('/')). parity: Recorder.Upload
    public static func baseUrl(_ server: String, _ id: String) -> String {
        var s = server
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/upload/" + id + "/"
    }

    /// What the log may show of a request URL: from "/upload/" on (never the host's query or anything secret; the
    /// upload_token only ever travels in the Authorization header). parity: url.Substring(url.IndexOf("/upload/"))
    public static func logPath(_ url: String) -> String {
        guard let r = url.range(of: "/upload/") else { return url }
        return String(url[r.lowerBound...])
    }
}

/// The video's size cap, less room for the AAC track when there is audio. Free recordings (up to 300 s, the boundary
/// included) get 250 MiB; with the chunked upload, anything longer may be a long one, up to 8 GiB (4 h at
/// RecordingLength.maxSeconds). Without a part size (one PUT) the cap stays at Free's 250 MiB at any length. Not a plan
/// limit: the length always comes from the start command's max_seconds; this only sizes the encoder's byte cap.
/// parity: AgentRecorder.cs Recorder.VideoCap
public enum VideoCap {
    public static let chunked: Int64 = Int64(8) * 1024 * 1024 * 1024
    public static func bytes(_ partBytes: Int64, _ maxSeconds: Int, _ hasAudio: Bool) -> Int64 {
        let audio: Int64 = hasAudio ? 17500 * Int64(maxSeconds) : 0 // AAC 128 kb/s (16 KB/s) plus container overhead
        return (partBytes > 0 && maxSeconds > 300 ? chunked : Int64(250 * 1024 * 1024)) - audio
    }
}

/// Longest recording any account may ask for: 4 h, the recorder's own ceiling. The start command's max_seconds still
/// governs (a shorter server limit always wins). parity: AgentRecorder.cs Recorder.MaxSeconds / Recorder.ClampSeconds
public enum RecordingLength {
    public static let maxSeconds = 14400
    public static func clamp(_ maxSeconds: Int) -> Int { return max(1, min(RecordingLength.maxSeconds, maxSeconds)) }
}

/// Which ready links may be opened: https, our own viewer page for that very recording, on the server this Mac talks
/// to or recitbot.com (the Worker's PUBLIC_BASE_URL; older installs talk to the workers.dev host). http only when the
/// server itself is a loopback dev server. Pure, covered by the selftest; the Worker applies the same rule.
/// parity: AgentRecorder.cs LinkPolicy.Allowed. The C# parses with System.Uri and then requires u.AbsoluteUri == url
/// ("nothing the parser had to normalize"), so only canonical URLs ever pass; this port accepts exactly that canonical
/// form (lowercase scheme and host, no userinfo, no fragment, no default or zero-padded port, literal path) and applies
/// the same host/port/path/query rules to it.
public enum LinkPolicy {
    public static let publicHost = "recitbot.com"

    public static func allowed(_ url: String?, _ server: String?, _ recordingId: String?) -> Bool {
        guard let url = url, !url.isEmpty, let id = recordingId, isId(id) else { return false }
        guard let u = CanonicalUrl(url), let s = ServerUrl(server ?? "") else { return false }
        let dev = s.isLoopback && u.isLoopback && u.scheme == "http"
        if u.scheme != "https" && !dev { return false }
        if u.host != s.host && u.host != publicHost { return false }
        if u.port != nil && !dev { return false }
        if u.path != "/v/" + id { return false }
        if let q = u.query, !q.unicodeScalars.allSatisfy({ queryChar($0) }) { return false }
        return true
    }

    /// ^[A-Za-z0-9]{20,30}$
    static func isId(_ s: String) -> Bool {
        let u = s.unicodeScalars
        return u.count >= 20 && u.count <= 30 && u.allSatisfy { alnum($0) }
    }

    static func alnum(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }

    /// [A-Za-z0-9_=&.-]
    static func queryChar(_ c: Unicode.Scalar) -> Bool { return alnum(c) || "_=&.-".unicodeScalars.contains(c) }

    /// Uri.IsLoopback: localhost, 127.0.0.0/8, [::1].
    static func loopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" { return true }
        let p = host.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4, p.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        return p[0] == "127" && p.allSatisfy { Int($0)! <= 255 }
    }

    /// A URL in the form Uri.AbsoluteUri would give back unchanged, for http(s) only: scheme://host[:port]/path[?query].
    /// Anything else (other schemes, upper case, userinfo, a fragment, white space, backslashes, dot segments, escapes,
    /// non-ASCII, a default or zero-padded port, an empty path) is nil: the C# rejects all of it at u.AbsoluteUri == url
    /// or earlier.
    struct CanonicalUrl {
        var scheme = "", host = "", path = ""
        var port: Int?
        var query: String?
        var isLoopback: Bool { return LinkPolicy.loopback(host) }

        init?(_ url: String) {
            guard url.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "\\" && $0 != "#" && $0 != "%" }) else { return nil }
            let s = url
            if s.hasPrefix("https://") { scheme = "https" } else if s.hasPrefix("http://") { scheme = "http" } else { return nil }
            var rest = Substring(s.dropFirst(scheme.count + 3))
            guard let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" }), rest[slash] == "/" else { return nil }
            var authority = String(rest[..<slash])
            rest = rest[slash...]
            if authority.contains("@") { return nil }
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return nil }
                host = String(authority[...close])
                authority = String(authority[authority.index(after: close)...])
                guard host.dropFirst().dropLast().unicodeScalars.allSatisfy({ "0123456789abcdef:.".unicodeScalars.contains($0) }) else { return nil }
            } else {
                let colon = authority.firstIndex(of: ":") ?? authority.endIndex
                host = String(authority[..<colon])
                authority = String(authority[colon...])
                guard !host.isEmpty, host.unicodeScalars.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.-".unicodeScalars.contains($0) }) else { return nil }
            }
            if !authority.isEmpty {
                // ":<port>": digits, no leading zero, not the scheme's default (AbsoluteUri would drop or rewrite it).
                let digits = authority.dropFirst()
                guard authority.first == ":", !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      digits.first != "0", let p = Int(digits), p <= 65535, p != (scheme == "https" ? 443 : 80) else { return nil }
                port = p
            }
            if let q = rest.firstIndex(of: "?") {
                query = String(rest[rest.index(after: q)...])
                rest = rest[..<q]
            }
            path = String(rest)
            // Dot segments are normalized by Uri (and would change AbsoluteUri).
            for seg in path.split(separator: "/", omittingEmptySubsequences: false) where seg == "." || seg == ".." { return nil }
        }
    }

    /// The server URL as Uri would read it: host lowercased (without port or userinfo), and whether it is loopback.
    struct ServerUrl {
        var host = ""
        var isLoopback: Bool { return LinkPolicy.loopback(host) }

        init?(_ server: String) {
            let t = NetParse.trim(server)
            guard let c = t.range(of: "://"), !t[..<c.lowerBound].isEmpty,
                  t[..<c.lowerBound].unicodeScalars.allSatisfy({ LinkPolicy.alnum($0) || "+-.".unicodeScalars.contains($0) }) else { return nil }
            var a = t[c.upperBound...]
            if let end = a.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { a = a[..<end] }
            if let at = a.lastIndex(of: "@") { a = a[a.index(after: at)...] }
            var h = String(a)
            if h.hasPrefix("[") { if let close = h.firstIndex(of: "]") { h = String(h[...close]) } }
            else if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
            if h.isEmpty { return nil }
            host = NetParse.lowerInvariant(h)
        }
    }
}

/// Upload and link log lines must never carry a secret: these are the only formats used (id, kind, sizes, statuses,
/// the /upload/... path). The selftest checks the formats against a token. parity: C# log lines of Recorder.Upload,
/// Recorder.Http, Uploader, Agent.OnReady and LinkOpener.
public enum UploadLog {
    public static func uploaded(_ id: String) -> String { return "uploaded " + id }
    public static func noResponse(_ method: String, _ url: String, _ message: String) -> String {
        return "upload " + method + " " + Uploader.logPath(url) + ": " + message
    }
}
