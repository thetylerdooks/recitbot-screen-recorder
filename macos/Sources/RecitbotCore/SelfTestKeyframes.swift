import Foundation

/// End-of-recording keyframes (Stills, hello "keyframes"): frame times, the skips (short, audio only), the PUT policy
/// (404/501 = not supported, quietly; other failures logged; never throws), with fake probes, grabs and PUTs. Case names
/// and vectors are copied from AgentRecorder.cs StillsSelfTest. The C# probe-parsing cases ("probe reads ...") and the
/// real-ffmpeg cases have no counterpart: the Mac probe and grab are AVFoundation (MacStills, in the app target).
enum SelfTestKeyframes {
    static func keyframes(_ t: SelfTest) {
        func join(_ l: [Int64]) -> String { return l.map { String($0) }.joined(separator: ",") }
        t.equal("keyframes: times are the centres of 6 equal buckets (60 s -> 5, 15, 25, 35, 45, 55 s)", join(Stills.times(60)), "5000,15000,25000,35000,45000,55000")
        var spaced = true
        for d in [2.0, 2.5, 7.3, 61.25, 119.9, 1800] {
            let l = Stills.times(d)
            let ms = Int64((d * 1000).rounded(.down))
            spaced = spaced && l.count == 6 && l[0] > 0 && l[5] < ms
            for i in 1..<l.count { spaced = spaced && abs(Double(l[i] - l[i - 1]) - d * 1000 / 6) <= 1 }
            spaced = spaced && abs(Double(l[0]) - d * 1000 / 12) <= 1 && abs(Double(ms - l[5]) - d * 1000 / 12) <= 1
        }
        t.check("keyframes: 6 times, evenly spaced (duration / 6), in range, never 0 and never the exact end (half a bucket from each)", spaced)
        t.equal("keyframes: 2.0 s exactly -> 166, 500, 833, 1166, 1500, 1833 ms", join(Stills.times(2.0)), "166,500,833,1166,1500,1833")
        t.check("keyframes: shorter than 2 s (or unknown) -> no times, skipped",
                Stills.times(1.999).isEmpty && Stills.times(0).isEmpty && Stills.times(.nan).isEmpty
                && Stills.skip(1.999, true) == "shorter than 2 s" && Stills.skip(.nan, true) != nil && Stills.skip(2.0, true) == nil)
        t.check("keyframes: no video track -> audio only, skipped (mac)", Stills.skip(30, false) == "audio only")

        t.check("keyframes: 2xx stored, 404 and 501 not supported, the rest (no response, 401, 409, 413, 500, 503) failed",
                Stills.outcome(200) == .stored && Stills.outcome(201) == .stored && Stills.outcome(204) == .stored
                && Stills.outcome(404) == .unsupported && Stills.outcome(501) == .unsupported
                && [0, 401, 409, 413, 500, 503].allSatisfy { Stills.outcome($0) == .failed })
        let base = "https://x/upload/AAAAAAAAAAAAAAAAAAAAAA/"
        t.check("keyframes: content type image/jpeg; video, audio and JSON unchanged",
                Uploader.contentType(url: base + "keyframes/3?t=25000", hasFile: true) == "image/jpeg"
                && Uploader.contentType(url: base + "video/mp/2", hasFile: true) == "video/mp4"
                && Uploader.contentType(url: base + "audio", hasFile: true) == "audio/wav"
                && Uploader.contentType(url: base + "complete", hasFile: false) == "application/json")

        // The whole step on fakes: grabs write a tiny JPEG header, PUTs answer from a script. Sandbox folder only.
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-stills-" + UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func files() -> Int { return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).count }
        let id = "AAAAAAAAAAAAAAAAAAAAAA"
        let video62 = { (_: String) -> (seconds: Double, hasVideo: Bool) in (62.5, true) }
        final class Grabs { var ms: [Int64] = [] }
        let grabs = Grabs()
        let grab = { (_: String, ms: Int64, jpg: String) throws -> Void in
            grabs.ms.append(ms)
            FileManager.default.createFile(atPath: jpg, contents: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]))
        }
        func run(_ probe: (String) throws -> (seconds: Double, hasVideo: Bool), _ answer: @escaping (Int) -> Int) -> (line: String, puts: [String]) {
            var puts: [String] = []
            let line = Stills.run(probe: probe, grab: grab, put: { path, jpg in
                puts.append(path + (FileManager.default.fileExists(atPath: jpg) ? "" : " (no file)"))
                return answer(puts.count)
            }, video: "v.mp4", fallbackSeconds: 10, dir: dir, id: id)
            return (line, puts)
        }

        let ok = run(video62) { _ in 200 }
        t.check("keyframes: all stored -> 6 PUTs keyframes/1..6?t=<ms>, files gone after",
                ok.line == "keyframes: 6 of 6 sent" && ok.puts.joined(separator: "|") == "keyframes/1?t=5208|keyframes/2?t=15625|keyframes/3?t=26041|keyframes/4?t=36458|keyframes/5?t=46875|keyframes/6?t=57291"
                && files() == 0, ok.line + " " + ok.puts.joined(separator: "|"))
        for code in [404, 501] {
            let r = run(video62) { _ in code }
            t.check("keyframes: " + String(code) + " (no route on this server yet) -> one PUT, the rest skipped quietly, no throw, files gone",
                    r.line == "keyframes: not supported by this server (" + String(code) + "); skipped" && r.puts.count == 1 && files() == 0, r.line)
        }
        let mid = run(video62) { $0 == 3 ? 500 : 200 }
        t.check("keyframes: a 500 on the 3rd -> stops there, logged (2 of 6 sent)", mid.line == "keyframes: 2 of 6 sent; stopped at 3 (HTTP 500)" && mid.puts.count == 3, mid.line)
        let net = run(video62) { _ in 0 }
        t.check("keyframes: no response -> stops, logged, no throw", net.line == "keyframes: 0 of 6 sent; stopped at 1 (no response)" && net.puts.count == 1, net.line)
        let thrown = Stills.run(probe: video62, grab: grab, put: { _, _ in throw UploadError("boom") }, video: "v.mp4", fallbackSeconds: 10, dir: dir, id: id)
        t.equal("keyframes: a PUT that throws -> stops, no throw", thrown, "keyframes: 0 of 6 sent; stopped at 1 (no response)")

        grabs.ms = []
        let audioOnly = run({ _ in (30, false) }) { _ in 200 }
        t.check("keyframes: audio only -> skipped: no grab, no PUT", audioOnly.line == "keyframes: skipped (audio only)" && grabs.ms.isEmpty && audioOnly.puts.isEmpty, audioOnly.line)
        let shortOne = run({ _ in (1.9, true) }) { _ in 200 }
        t.check("keyframes: 1.9 s video -> skipped: no grab, no PUT", shortOne.line == "keyframes: skipped (shorter than 2 s)" && grabs.ms.isEmpty && shortOne.puts.isEmpty, shortOne.line)
        let fallback = run({ _ in (.nan, true) }) { _ in 200 }
        t.check("keyframes: no duration in the probe -> the recording's own length (10 s)", fallback.puts.count == 6 && fallback.puts.first == "keyframes/1?t=833", fallback.line)

        // A bad frame (grab throws, or writes something that is not a JPEG) is left out; the others keep their slot.
        var puts2: [String] = []
        let bad = Stills.run(probe: video62, grab: { _, ms, jpg in
            if ms == 15625 { throw UploadError("decode error") }
            let b: [UInt8] = ms == 36458 ? [1, 2, 3, 4] : [0xFF, 0xD8, 0xFF, 0xDB]
            FileManager.default.createFile(atPath: jpg, contents: Data(b))
        }, put: { path, _ in puts2.append(path); return 200 }, video: "v.mp4", fallbackSeconds: 10, dir: dir, id: id)
        t.check("keyframes: bad frames (grab error, not a JPEG) left out, the rest sent with their own slot and time",
                bad == "keyframes: 4 of 4 sent" && puts2.joined(separator: "|") == "keyframes/1?t=5208|keyframes/3?t=26041|keyframes/5?t=46875|keyframes/6?t=57291" && files() == 0,
                bad + " " + puts2.joined(separator: "|"))
        let probeFails = Stills.run(probe: { _ in throw UploadError("no such file") }, grab: grab, put: { _, _ in 200 }, video: "v.mp4", fallbackSeconds: 10, dir: dir, id: id)
        t.equal("keyframes: probe failure -> skipped, no throw", probeFails, "keyframes: skipped (no such file)")
        let big = (dir as NSString).appendingPathComponent("big.jpg")
        var bytes = Data(count: Int(Stills.maxBytes) + 1)
        bytes[0] = 0xFF; bytes[1] = 0xD8; bytes[2] = 0xFF
        FileManager.default.createFile(atPath: big, contents: bytes)
        t.check("keyframes: a JPEG over 1 MiB is not usable", !Stills.usable(big) && !Stills.usable((dir as NSString).appendingPathComponent("none.jpg")))
        try? FileManager.default.removeItem(atPath: big)
    }
}
