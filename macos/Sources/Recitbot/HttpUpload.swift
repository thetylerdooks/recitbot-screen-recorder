import AppKit
import Foundation
import RecitbotCore

/// Uploads one finished recording: video (one PUT, or the chunked upload over upload_part_bytes), the transcription WAV
/// when there is one (a mic was recorded: transcripts are mic-only), then POST complete {duration_s, has_system_audio}.
/// Without a mic no audio request is made at all and complete is the same; the Worker stores the recording without a
/// transcript, else it transcribes and pushes the signed "ready" frame (Agent.onReady).
/// parity: AgentRecorder.cs Recorder.Upload + Recorder.Send + Recorder.Http
///
/// Endpoints (relative to server + "/upload/" + id + "/"), all with "Authorization: Bearer <upload_token>":
///   PUT  video | audio                      Content-Type video/mp4 | audio/wav, body = the whole file
///   POST video/mp | audio/mp                application/json {"total_bytes":N}        (create)
///   PUT  video/mp/<n> | audio/mp/<n>        video/mp4 | audio/wav, body = part n's bytes
///   POST video/mp/complete | audio/mp/complete   application/json {"parts":N}
///   POST complete                           application/json {"duration_s":D.D,"has_system_audio":bool}
final class HttpUploader: RecordingUploader {
    func upload(server: String?, id: String, video: String, audio: String, hasTranscript: Bool, hasSystemAudio: Bool, token: String?,
                duration: Double, partBytes: Int64) throws {
        let baseUrl = Uploader.baseUrl(server ?? "", id)
        let session = HttpUploader.makeSession()
        defer { session.invalidateAndCancel() }
        let up = Uploader({ method, path, file, offset, count, json in
            try HttpUploader.http(session, baseUrl + path, method, token, file, offset, count, json)
        }, partBytes)
        try up.recording(video: video, videoBytes: try HttpUploader.length(video), audio: audio,
                         audioBytes: FileManager.default.fileExists(atPath: audio) ? Recorder.fileSize(audio) : 0,
                         hasTranscript: hasTranscript, hasSystemAudio: hasSystemAudio, duration: duration)
        Log.write(UploadLog.uploaded(id))
    }

    /// One keyframe JPEG, PUT keyframes/<n>?t=<ms> (image/jpeg, the whole file), with the recording's upload token.
    /// 30 s at most, no retries. parity: Recorder.PutStill
    func putStill(server: String?, id: String, token: String?, path: String, jpg: String) throws -> Int {
        let session = HttpUploader.makeSession(timeout: 30)
        defer { session.invalidateAndCancel() }
        return try HttpUploader.http(session, Uploader.baseUrl(server ?? "", id) + path, "PUT", token, jpg, 0, Recorder.fileSize(jpg), nil)
    }

    /// new FileInfo(video).Length: a missing file fails the recording with FileNotFoundException's message.
    static func length(_ path: String) throws -> Int64 {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), let n = a[.size] as? NSNumber else {
            throw UploadError("Could not find file '" + path + "'.")
        }
        return n.int64Value
    }

    /// HttpWebRequest Timeout / ReadWriteTimeout are 600 s per operation; a whole 80 MB PUT may take longer than that
    /// on a slow line, so only the idle timeout is 600 s. No cookies, no cache, no redirects (see RedirectBlocker).
    /// A keyframe (putStill) gets 30 s for the whole request.
    static func makeSession(timeout: TimeInterval = 600) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout < 600 ? timeout : 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    /// One request: bytes [offset, offset + count) of file streamed from disk (never held in memory), else the json
    /// body. Returns the HTTP status, 0 when there was no response (logged with the /upload/... path only).
    /// parity: Recorder.Http. A part of a file is first copied to a 0600 slice file beside it (URLSession streams a body
    /// only from a whole file), deleted right after the request.
    static func http(_ session: URLSession, _ url: String, _ method: String, _ token: String?, _ file: String?, _ offset: Int64,
                     _ count: Int64, _ json: String?) throws -> Int {
        guard let u = URL(string: url) else {
            Log.write(UploadLog.noResponse(method, url, "Invalid URI: The format of the URI could not be determined."))
            return 0
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue(Uploader.contentType(url: url, hasFile: file != nil), forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + (token ?? ""), forHTTPHeaderField: "Authorization")
        var slice: String?
        defer { if let s = slice { try? FileManager.default.removeItem(atPath: s) } }
        let task: URLSessionTask
        let box = ResultBox()
        let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { _, res, err in box.finish(res, err) }
        if let f = file {
            var body = f
            if offset != 0 || count != Recorder.fileSize(f) {
                let s = f + ".part"
                try copyRange(f, s, offset, count)
                slice = s
                body = s
            }
            req.setValue(String(count), forHTTPHeaderField: "Content-Length")
            task = session.uploadTask(with: req, fromFile: URL(fileURLWithPath: body), completionHandler: handler)
        } else {
            let data = Data((json ?? "").utf8)
            req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            task = session.uploadTask(with: req, from: data, completionHandler: handler)
        }
        task.resume()
        box.done.wait()
        if let res = box.response as? HTTPURLResponse { return res.statusCode }
        Log.write(UploadLog.noResponse(method, url, box.error.map { ($0 as NSError).localizedDescription } ?? "no response"))
        return 0
    }

    /// Copies bytes [offset, offset + count) of src to dst (created 0600) in 64 KiB blocks.
    static func copyRange(_ src: String, _ dst: String, _ offset: Int64, _ count: Int64) throws {
        guard let input = FileHandle(forReadingAtPath: src) else { throw UploadError("Could not find file '" + src + "'.") }
        defer { try? input.close() }
        try? FileManager.default.removeItem(atPath: dst)
        guard FileManager.default.createFile(atPath: dst, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = FileHandle(forWritingAtPath: dst) else { throw UploadError("could not write " + (dst as NSString).lastPathComponent) }
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        var left = count
        while left > 0 {
            let chunk = try input.read(upToCount: Int(min(65536, left))) ?? Data()
            if chunk.isEmpty { throw UploadError("file shorter than expected") }
            try output.write(contentsOf: chunk)
            left -= Int64(chunk.count)
        }
    }

    final class ResultBox: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var response: URLResponse?
        var error: Error?
        func finish(_ r: URLResponse?, _ e: Error?) { response = r; error = e; done.signal() }
    }

    /// A redirect is never followed: the 3xx comes back as the status (retried, then UPLOAD_FAILED), and the bearer
    /// token is never sent to another URL. (HttpWebRequest cannot replay an unbuffered body on a redirect either.)
    final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Opens a link in the user's default browser through Launch Services (NSWorkspace.open of the https URL: a new tab in
/// the browser that is already open; no browser is ever started by name or path). With AGENT_RECORDER_OPEN_LOG set
/// (tests) the URL is appended to that file instead, so no tab pops up. parity: AgentRecorder.cs LinkPolicy + LinkOpener
///
/// Nothing of this app stands in the way: the app registers no URL schemes (Info.plist has no CFBundleURLTypes), so the
/// https link always goes to the default browser, and the browser is asked to come forward (activates = true) while
/// this accessory app yields activation to it; this app never activates itself.
final class MacLinkOpener: ShareLinkOpener {
    func allowed(url: String?, server: String?, recordingId: String?) -> Bool {
        return LinkPolicy.allowed(url, server, recordingId)
    }

    func open(_ url: String) {
        let stub = ProcessInfo.processInfo.environment["AGENT_RECORDER_OPEN_LOG"] ?? ""
        if !stub.isEmpty {
            do { try SecureFile.append(stub, url + "\n") } catch { Log.write("open link stub: " + Config.message(error)) }
            Log.write("share link: opener stubbed (AGENT_RECORDER_OPEN_LOG)")
            return
        }
        guard let u = URL(string: url) else { Log.write("share link not opened: not a URL"); return }
        DispatchQueue.main.async { MainActor.assumeIsolated {
            let ws = NSWorkspace.shared
            if let app = ws.urlForApplication(toOpen: u), let bid = Bundle(url: app)?.bundleIdentifier {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: bid)
            }
            let c = NSWorkspace.OpenConfiguration()
            c.activates = true
            ws.open(u, configuration: c) { _, error in
                // Domain and code only: a Launch Services message can quote the URL, which is a bearer link.
                if let e = error as NSError? { Log.write("share link not opened: " + e.domain + " " + String(e.code)) }
                else { Log.write("share link opened in the default browser") }
            }
        } }
    }
}
