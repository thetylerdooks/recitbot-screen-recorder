import Foundation

/// Phase (d) selftests: video cap, upload part planning, the upload policy against a scripted server (retries, backoff,
/// restarts, 4xx/502 handling), the complete body, link policy and the ready frame. Case names and vectors are copied
/// from AgentRecorder.cs (kit-install 0.5.0 = cb8c7c7) Program.SelfTest / AudioSelfTest; "(mac)" cases are additions.
enum SelfTestUpload {
    static func upload(_ t: SelfTest) {
        t.check("video cap: no part size (one PUT) stays at Free's 250 MiB, even at 1800 s", VideoCap.bytes(0, 1800, false) == 250 * 1024 * 1024)
        t.check("video cap: Free 120 s with audio = 250 MiB less audio", VideoCap.bytes(33554432, 120, true) == 250 * 1024 * 1024 - 17500 * 120)
        t.check("video cap: Free 300 s boundary with audio = 250 MiB less audio", VideoCap.bytes(33554432, 300, true) == 250 * 1024 * 1024 - 17500 * 300)
        let gib8: Int64 = Int64(8) * 1024 * 1024 * 1024
        t.check("video cap: one PUT stays at Free's 250 MiB even at 4 h", VideoCap.bytes(0, 14400, true) == Int64(250 * 1024 * 1024) - Int64(17500) * 14400)
        t.check("video cap: chunked long recording (1800 s with audio) under 8 GiB", VideoCap.bytes(33554432, 1800, true) == gib8 - Int64(17500) * 1800)
        t.check("video cap: chunked 4 h with audio = 8 GiB less audio", VideoCap.bytes(33554432, 14400, true) == gib8 - Int64(17500) * 14400)
        t.check("length cap: MaxSeconds is 4 h (14400)", RecordingLength.maxSeconds == 14400)
        t.check("length cap: clamp 1..14400", RecordingLength.clamp(99999) == 14400 && RecordingLength.clamp(14400) == 14400 && RecordingLength.clamp(0) == 1 && RecordingLength.clamp(-5) == 1)
        t.check("length cap: the server's max_seconds still governs (300 runs 300, 1800 runs 1800)", RecordingLength.clamp(300) == 300 && RecordingLength.clamp(1800) == 1800)

        let P: Int64 = 32 * 1024 * 1024
        func show(_ ps: [(offset: Int64, count: Int64)]) -> String { return ps.map { String($0.offset) + "+" + String($0.count) }.joined(separator: ",") }
        t.check("parts: exact multiple", show(Uploader.parts(2 * P, P)) == "0+\(P),\(P)+\(P)")
        t.check("parts: remainder in a short last part", show(Uploader.parts(2 * P + 5, P)) == "0+\(P),\(P)+\(P),\(2 * P)+5")
        t.check("parts: one byte over", Uploader.parts(P + 1, P).count == 2 && Uploader.parts(P + 1, P)[1].count == 1)
        let big = Uploader.parts(1536 * 1024 * 1024 - 1, P)
        var sum: Int64 = 0
        var even = true
        for (i, p) in big.enumerated() { sum += p.count; even = even && p.offset == Int64(i) * P && (i == big.count - 1 || p.count == P) }
        t.check("parts: 1.5 GiB in 48 parts, contiguous, all full but the last", big.count == 48 && sum == 1536 * 1024 * 1024 - 1 && even)
        let huge = Uploader.parts(gib8, P)
        t.check("parts: 8 GiB in 256 full parts, the last ending at 8 GiB", huge.count == 256 && huge[255].offset == 255 * P && huge[255].count == P && huge[255].offset + huge[255].count == gib8)

        // Scripted server: answers each request from a queue of statuses per path (default 200), logs the requests.
        final class Scripted {
            var script: [String: [Int]]
            var log: [String] = []
            var sleeps: [Int] = []
            var up: Uploader!
            init(_ script: [String: [Int]], _ part: Int64) {
                self.script = script
                up = Uploader({ [unowned self] method, path, file, offset, count, json in
                    self.log.append(method + " " + path + (file != nil ? " " + file! + " " + String(offset) + "+" + String(count) : "") + (json != nil ? " " + json! : ""))
                    if var q = self.script[path], !q.isEmpty { let st = q.removeFirst(); self.script[path] = q; return st }
                    return 200
                }, part)
                up.sleep = { [unowned self] in self.sleeps.append($0) }
            }
            var joined: String { return log.joined(separator: "|") }
        }
        func error(_ a: () throws -> Void) -> String? {
            do { try a(); return nil } catch let e as UploadError { return e.description } catch { return "\(error)" }
        }

        var s = Scripted([:], 0)
        try? s.up.file("video", "v.mp4", 3 * P)
        t.check("upload: no part size -> one PUT of the whole file", s.joined == "PUT video v.mp4 0+\(3 * P)")
        s = Scripted([:], P)
        try? s.up.file("audio", "a.wav", P)
        t.check("upload: file of exactly the part size -> one PUT", s.joined == "PUT audio a.wav 0+\(P)")

        let tb = "{\"total_bytes\":\(2 * P + 7)}"
        s = Scripted([:], P)
        try? s.up.file("video", "v.mp4", 2 * P + 7)
        t.check("upload: chunked happy path (create with total, parts in order, complete with N)", s.joined ==
            "POST video/mp " + tb + "|PUT video/mp/1 v.mp4 0+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)|PUT video/mp/3 v.mp4 \(2 * P)+7|POST video/mp/complete {\"parts\":3}")

        s = Scripted(["video/mp/2": [0, 503]], P)
        try? s.up.file("video", "v.mp4", 2 * P + 7)
        t.check("upload: a failed part is sent again with the same number and range", s.joined ==
            "POST video/mp " + tb + "|PUT video/mp/1 v.mp4 0+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)"
            + "|PUT video/mp/3 v.mp4 \(2 * P)+7|POST video/mp/complete {\"parts\":3}" && s.sleeps == [2000, 4000])

        s = Scripted(["video/mp/2": [502]], P)
        try? s.up.file("video", "v.mp4", 2 * P + 7)
        t.check("upload: 502 on a part -> start over from create, all parts again", s.joined ==
            "POST video/mp " + tb + "|PUT video/mp/1 v.mp4 0+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)"
            + "|POST video/mp " + tb + "|PUT video/mp/1 v.mp4 0+\(P)|PUT video/mp/2 v.mp4 \(P)+\(P)"
            + "|PUT video/mp/3 v.mp4 \(2 * P)+7|POST video/mp/complete {\"parts\":3}" && s.sleeps.isEmpty)

        s = Scripted(["video/mp/complete": [502]], P)
        try? s.up.file("video", "v.mp4", P + 1)
        t.check("upload: 502 on complete -> start over", s.log.count == 8 && s.log[4] == "POST video/mp {\"total_bytes\":\(P + 1)}"
                && s.log[7] == "POST video/mp/complete {\"parts\":2}")

        s = Scripted(["video/mp/1": [502, 502, 502]], P)
        let e1 = error { try s.up.file("video", "v.mp4", P + 1) }
        t.check("upload: aborted on every restart -> UPLOAD_FAILED after \(Uploader.restarts) creates",
                (e1 ?? "").hasPrefix("UPLOAD_FAILED") && s.log.filter { $0 == "POST video/mp {\"total_bytes\":\(P + 1)}" }.count == Uploader.restarts)

        s = Scripted(["video/mp/2": [0, 0, 0]], P)
        let e2 = error { try s.up.file("video", "v.mp4", P + 1) }
        t.check("upload: a part with no response \(Uploader.attempts) times -> UPLOAD_FAILED, no complete",
                e2 == "UPLOAD_FAILED: PUT video/mp/2 (no response)" && !s.log.contains { $0.contains("complete") })

        s = Scripted(["video/mp/2": [409]], P)
        let e3 = error { try s.up.file("video", "v.mp4", P + 1) }
        t.check("upload: 4xx on a part is final (no retry)", e3 == "UPLOAD_REJECTED_409" && s.log.count == 3)

        s = Scripted(["video": [502, 200]], P)
        try? s.up.file("video", "v.mp4", 100)
        t.check("upload: single PUT retries a 502 (no multipart to restart)", s.log.count == 2 && s.log[1] == "PUT video v.mp4 0+100")

        s = Scripted(["video/mp": [413]], P)
        let e4 = error { try s.up.file("video", "v.mp4", P + 1) }
        t.check("upload: create refused (over the account's size) -> UPLOAD_REJECTED_413, no parts", e4 == "UPLOAD_REJECTED_413" && s.log.count == 1)

        // macOS additions: the parts of Recorder.Upload / Recorder.Http that are pure here.
        s = Scripted(["complete": [500, 500, 500]], 0)
        let e5 = error { try s.up.complete(Uploader.completeJson(duration: 12.25, hasSystemAudio: true)) }
        t.check("upload (mac): complete body and its error string", s.log.first == "POST complete {\"duration_s\":12.3,\"has_system_audio\":true}"
                && e5 == "UPLOAD_FAILED: POST complete (500)" && Uploader.completeJson(duration: 7, hasSystemAudio: false) == "{\"duration_s\":7.0,\"has_system_audio\":false}")
        let base = Uploader.baseUrl("https://recitbot.com//", "AAAAAAAAAAAAAAAAAAAAAA")
        t.check("upload (mac): endpoints and content types as Recorder.Http", base == "https://recitbot.com/upload/AAAAAAAAAAAAAAAAAAAAAA/"
                && Uploader.contentType(url: base + "video", hasFile: true) == "video/mp4" && Uploader.contentType(url: base + "video/mp/3", hasFile: true) == "video/mp4"
                && Uploader.contentType(url: base + "audio/mp/1", hasFile: true) == "audio/wav" && Uploader.contentType(url: base + "video/mp", hasFile: false) == "application/json"
                && Uploader.contentType(url: base + "complete", hasFile: false) == "application/json")
        // The upload_token only ever goes into the Authorization header (HttpUploader): the request paths, errors and
        // log lines are built without it.
        let secret = "tok_SECRET_upload_token_value"
        s = Scripted(["video/mp/1": [0, 0, 0]], P)
        let e6 = error { try s.up.file("video", "v.mp4", P + 1) }
        let lines = [UploadLog.noResponse("PUT", base + "video/mp/1", "The request timed out."), UploadLog.uploaded("AAAAAAAAAAAAAAAAAAAAAA"), e6 ?? ""] + s.log
        t.check("upload (mac): no token in any request path, error or log line", !lines.contains { $0.contains(secret) || $0.contains("Bearer") }
                && UploadLog.noResponse("PUT", base + "video/mp/1", "x") == "upload PUT /upload/AAAAAAAAAAAAAAAAAAAAAA/video/mp/1: x")

        // Transcripts are mic-only: the whole upload plan (Uploader.recording) with and without the mic's WAV.
        // parity: AgentRecorder.cs ChunkedSelfTest "upload plan: ..." (the C# reads the sizes from sandbox files).
        let Q: Int64 = 1000 // the 2007-byte video goes up in 3 parts, the WAV in one PUT
        let done = "POST complete {\"duration_s\":12.5,\"has_system_audio\":true}"
        s = Scripted([:], Q)
        try? s.up.recording(video: "v.mp4", videoBytes: 2 * Q + 7, audio: "v.wav", audioBytes: 844, hasTranscript: true, hasSystemAudio: true, duration: 12.5)
        t.check("upload plan: mic + system -> video (3 parts), the mic's WAV, complete", s.log.count == 7 && s.log[4] == "POST video/mp/complete {\"parts\":3}"
                && s.log[5] == "PUT audio v.wav 0+844" && s.log[6] == done)
        // System audio only: the recorder passes hasTranscript false (no WAV file at all).
        s = Scripted([:], Q)
        try? s.up.recording(video: "v.mp4", videoBytes: 2 * Q + 7, audio: "absent.wav", audioBytes: 0, hasTranscript: false, hasSystemAudio: true, duration: 12.5)
        t.check("upload plan: system audio only (no mic) -> no audio request at all, the same complete", s.log.count == 6
                && !s.log.contains { $0.hasPrefix("POST audio") || $0.hasPrefix("PUT audio") } && s.log[4] == "POST video/mp/complete {\"parts\":3}" && s.log[5] == done)
        s = Scripted(["video/mp/2": [0, 503]], Q)
        try? s.up.recording(video: "v.mp4", videoBytes: 2 * Q + 7, audio: "absent.wav", audioBytes: 0, hasTranscript: false, hasSystemAudio: false, duration: 3)
        t.check("upload plan: no mic, video part retried -> still no audio, complete has_system_audio false", s.log.count == 8
                && !s.log.contains { $0.hasPrefix("POST audio") || $0.hasPrefix("PUT audio") } && s.log[7] == "POST complete {\"duration_s\":3.0,\"has_system_audio\":false}")
        s = Scripted([:], Q)
        try? s.up.recording(video: "v.mp4", videoBytes: 2 * Q + 7, audio: "v.wav", audioBytes: 44, hasTranscript: true, hasSystemAudio: false, duration: 3)
        t.check("upload plan: header-only WAV is not sent", !s.log.contains { $0.hasPrefix("PUT audio") } && (s.log.last ?? "").hasPrefix("POST complete"))

        // Auto-open: link policy (same rules as worker/src/ready.ts) and once-per-recording.
        let id = "AAAAAAAAAAAAAAAAAAAAAA"
        let ok1 = "https://recitbot.com/v/" + id + "?e=1731736400&s=ab-c_d&o=e_f"
        t.check("link: recitbot.com viewer link opens (any server)", LinkPolicy.allowed(ok1, "https://agent-recorder-demo.x.workers.dev", id) && LinkPolicy.allowed(ok1, "https://recitbot.com", id))
        t.check("link: the server's own host opens", LinkPolicy.allowed("https://agent-recorder-demo.x.workers.dev/v/" + id + "?e=1", "https://agent-recorder-demo.x.workers.dev", id))
        let rejected: [String?] = [
            "http://recitbot.com/v/" + id + "?e=1", "https://evil.example/v/" + id, "https://recitbot.com.evil.example/v/" + id,
            "https://user@recitbot.com/v/" + id, "https://recitbot.com:8443/v/" + id, "https://recitbot.com/v/BBBBBBBBBBBBBBBBBBBBBB",
            "https://recitbot.com/m/" + id, "https://recitbot.com/v/" + id + "#x", "https://recitbot.com/v/" + id + "?e=1&x=<script>",
            "https://recitbot.com/v/" + id + "/../../x", "file:///C:/Windows/notepad.exe", "javascript:alert(1)", "notepad.exe", "", nil,
            "https://RECITBOT.com/v/" + id,
        ]
        let allowed = rejected.filter { LinkPolicy.allowed($0, "https://recitbot.com", id) }.count
        t.check("link: other hosts, schemes, paths, ports, userinfo, fragments, odd queries rejected (\(allowed) let through)", allowed == 0)
        t.check("link: http only for a loopback dev server", LinkPolicy.allowed("http://127.0.0.1:8787/v/" + id + "?e=1", "http://127.0.0.1:8787", id)
                && !LinkPolicy.allowed("http://127.0.0.1:8787/v/" + id, "https://recitbot.com", id) && !LinkPolicy.allowed(ok1, "https://recitbot.com", "bad id!"))
        // What System.Uri would have normalized (so AbsoluteUri != url in the C#), and macOS-only openers.
        let normalized = [
            "HTTPS://recitbot.com/v/" + id, "https://recitbot.com:443/v/" + id, " https://recitbot.com/v/" + id, "https://recitbot.com/v/" + id + " ",
            "https://recitbot.com/v/%41" + String(id.dropFirst()), "https://recitbot.com\\v\\" + id, "https://recitbot.com/./v/" + id, "https://recitbot.com/v/" + id + "?e=%31",
            "file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.preference.security", "https://recitbot.com./v/" + id,
            "https://recitbot.com/v/" + id + "?e=\u{e9}", "http://localhost:8787/v/" + id,
        ]
        let let2 = normalized.filter { LinkPolicy.allowed($0, "https://recitbot.com", id) }.count
        t.check("link (mac): forms System.Uri would normalize, non-web schemes rejected (\(let2) let through)", let2 == 0
                && LinkPolicy.allowed("http://localhost:8787/v/" + id, "http://localhost:8787/", id)
                && !LinkPolicy.allowed("http://127.0.0.1:80/v/" + id, "http://127.0.0.1", id)
                && LinkPolicy.allowed("https://agent.example.dev/v/" + id, "https://Agent.Example.dev/", id)
                && !LinkPolicy.allowed(ok1, nil, id) && !LinkPolicy.allowed(ok1, "", id))

        // The ready frame as it comes off the socket: the fields Agent.onReady reads, then policy + once-only.
        let frame = "{\"type\":\"ready\",\"recording_id\":\"" + id + "\",\"url\":\"https:\\/\\/recitbot.com\\/v\\/" + id + "?e=1731736400&s=ab-c_d&o=e_f\","
            + "\"nonce\":\"1731650000000\",\"exp\":1731650060,\"mac\":\"00\"}"
        var parsedOk = false
        if let f = try? Json.parseFlat(frame) {
            let rl = ReadyLinks()
            let now = Date(timeIntervalSince1970: 1731650000)
            let rid = Fields.opt(f, "recording_id"), url = Fields.opt(f, "url")
            rl.expect(id, now)
            parsedOk = Fields.opt(f, "type") == "ready" && rid == id && url == ok1 && LinkPolicy.allowed(url, "https://recitbot.com", rid)
                && rl.claim(rid, now + 3) && !rl.claim(rid, now + 4)
        }
        t.check("ready (mac): frame fields parsed, link allowed, claimed once", parsedOk)
        let noUrl = try? Json.parseFlat("{\"type\":\"ready\",\"recording_id\":\"" + id + "\",\"url\":null}")
        t.check("ready (mac): a missing or null url never opens", noUrl != nil && !LinkPolicy.allowed(Fields.opt(noUrl!, "url"), "https://recitbot.com", id))
    }
}
