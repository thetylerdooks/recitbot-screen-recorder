import Foundation

/// Phase (e) selftests. Self-update: the signed update block (shared vector with worker/test/installer.test.ts), version
/// order, link policy, hash check, the installer argv and the report frame, with the names and vectors of
/// AgentRecorder.cs SelfUpdateSelfTest; "(mac)" cases are additions: the whole Install order (busy, installed check,
/// link, cooldown, download, hash, start) against a scripted platform, no network, no process started. deferRollback:
/// the 0.6.1 cases of AgentRecorder.cs UpdateDeferRollbackSelfTest (same names).
enum SelfTestUpdate {
    static func update(_ t: SelfTest) {
        let acct = SelfTestCases.acct, dev = SelfTestCases.dev
        let sha = "6685944C4FFFC4F5B140100CEEB4BD6BC9663578062018C2E8B0756C7ECE7D9D"
        let link = "https://recitbot.com/i/v1.update.BBBBBBBBBBBBBBBBBBBBBB.1731650600.NNNNNNNNNNNN.." + String(repeating: "M", count: 43)
        var upd: JsonFields = [
            "type": "update", "recording_id": "AAAAAAAAAAAAAAAAAAAAAA", "max_seconds": "0", "mic": "false",
            "nonce": "1731650000000", "exp": "1731650060", "account_id": acct,
            "device_id": dev, "upload_token": "", "url": link, "version": "0.5.0", "sha256": sha,
        ]
        t.check("update canonical form", CommandVerifier.canonical(upd).hasSuffix("|CCCCCCCCCCCCCCCCCCCCCC||url|" + link + "|upd|0.5.0|" + sha))
        t.equal("update canonical hmac matches worker vector", SelfTestCases.mac(upd), "4ac3acc3df0b6942ada285bcfa62250587b5ac25235ce107902e07c422ceb5fb")
        upd["mac"] = SelfTestCases.mac(upd)
        for field in ["version", "sha256", "url"] {
            var x = upd
            x[field] = field == "url" ? "https://evil.example/i/x" : field == "version" ? "9.9.9" : String(repeating: "0", count: 64)
            t.equal("update: tampered " + field + " rejected", SelfTestCases.verifier().verify(x, 1731650000), "bad mac")
        }
        t.check("signed update accepted", SelfTestCases.verifier().verify(upd, 1731650000) == nil)

        t.check("update: newer versions only", SelfUpdater.isNewer("0.5.0", "0.4.0") && SelfUpdater.isNewer("0.10.0", "0.9.9")
                && SelfUpdater.isNewer("1.0.0", "0.99.99") && !SelfUpdater.isNewer("0.4.0", "0.4.0") && !SelfUpdater.isNewer("0.3.9", "0.4.0")
                && !SelfUpdater.isNewer("1.0", "0.4.0") && !SelfUpdater.isNewer(nil, "0.4.0") && !SelfUpdater.isNewer("0.5.0-beta", "0.4.0"))
        t.check("update (mac): x.y.z strictly (no 4-digit parts, signs, spaces, empty parts; .NET's final \\n kept)",
                !SelfUpdater.isNewer("0.5.1000", "0.5.0") && !SelfUpdater.isNewer("+1.0.0", "0.5.0") && !SelfUpdater.isNewer(" 1.0.0", "0.5.0")
                && !SelfUpdater.isNewer("1..0", "0.5.0") && !SelfUpdater.isNewer("1.0.0.0", "0.5.0") && !SelfUpdater.isNewer("１.0.0", "0.5.0")
                && SelfUpdater.isNewer("1.0.0\n", "0.5.0") && !SelfUpdater.isNewer("1.0.0\r\n", "0.5.0") && SelfUpdater.isNewer("001.0.0", "0.5.0"))

        let server = "https://agent-recorder-demo.example.workers.dev"
        let tok = String(repeating: "t", count: 40)
        t.check("update link: recitbot.com or the server, https, /i/<token>", SelfUpdater.urlAllowed(link, server)
                && SelfUpdater.urlAllowed("https://agent-recorder-demo.example.workers.dev/i/" + tok, server))
        t.check("update link: other hosts, http, ports, queries, other paths rejected",
                !SelfUpdater.urlAllowed("https://evil.example/i/" + tok, server)
                && !SelfUpdater.urlAllowed("http://recitbot.com/i/" + tok, server)
                && !SelfUpdater.urlAllowed("https://recitbot.com:8443/i/" + tok, server)
                && !SelfUpdater.urlAllowed(link + "?x=1", server)
                && !SelfUpdater.urlAllowed("https://recitbot.com/install.ps1", server)
                && !SelfUpdater.urlAllowed("https://user@recitbot.com/i/" + tok, server)
                && !SelfUpdater.urlAllowed(nil, server))
        t.check("update link: http only against a loopback dev server",
                SelfUpdater.urlAllowed("http://127.0.0.1:8787/i/" + tok, "http://127.0.0.1:8787")
                && !SelfUpdater.urlAllowed("http://127.0.0.1:8787/i/" + tok, server))
        var through = [String]()
        for u in [
            "https://recitbot.com/i/" + String(repeating: "t", count: 19), "https://recitbot.com/i/" + String(repeating: "t", count: 401),
            "https://recitbot.com/i/" + tok + "#f", "https://recitbot.com/i/" + tok + "?", "https://RECITBOT.com/i/" + tok,
            "HTTPS://recitbot.com/i/" + tok, "https://recitbot.com:443/i/" + tok, "https://recitbot.com/i/" + tok + "/x",
            "https://recitbot.com/I/" + tok, "https://recitbot.com/x/../i/" + tok, "https://recitbot.com/i/" + tok + "%41",
            "https://recitbot.com/i/" + tok + " ", "https://recitbot.com.evil.example/i/" + tok, "ftp://recitbot.com/i/" + tok,
            "https://recitbot.com\\i\\" + tok, "//recitbot.com/i/" + tok, "",
        ] where SelfUpdater.urlAllowed(u, server) { through.append(u) }
        t.check("update link (mac): lengths, fragments, empty query, case, default port, extra segments, escapes rejected (\(through.count) let through)",
                through.isEmpty, through.joined(separator: " "))
        t.check("update link (mac): 20 and 400 token chars, . _ - allowed, server host any case, no server = rejected",
                SelfUpdater.urlAllowed("https://recitbot.com/i/" + String(repeating: "a", count: 20), server)
                && SelfUpdater.urlAllowed("https://recitbot.com/i/" + String(repeating: "a", count: 400), server)
                && SelfUpdater.urlAllowed("https://recitbot.com/i/a._-" + String(repeating: "Z9", count: 8), server)
                && SelfUpdater.urlAllowed("https://agent-recorder-demo.example.workers.dev/i/" + tok, "HTTPS://Agent-Recorder-Demo.example.workers.dev/")
                && !SelfUpdater.urlAllowed(link, nil) && !SelfUpdater.urlAllowed(link, ""))
        t.check("update link (mac): loopback dev any port incl. localhost, never https elsewhere on a dev port",
                SelfUpdater.urlAllowed("http://localhost:8787/i/" + tok, "http://localhost:8787")
                && SelfUpdater.urlAllowed("http://127.0.0.1/i/" + tok, "http://127.0.0.1:8787")
                && !SelfUpdater.urlAllowed("https://recitbot.com:8787/i/" + tok, "http://127.0.0.1:8787")
                && SelfUpdater.urlAllowed("https://recitbot.com/i/" + tok, "http://127.0.0.1:8787"))

        let abc = Data("abc".utf8)
        t.check("update: sha256 checked (any case), malformed refused",
                SelfUpdater.hashMatches(abc, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
                && SelfUpdater.hashMatches(abc, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                && !SelfUpdater.hashMatches(abc, sha) && !SelfUpdater.hashMatches(abc, "BA78") && !SelfUpdater.hashMatches(abc, nil))
        t.check("update (mac): sha256 with spaces, a final newline or non-hex refused",
                !SelfUpdater.hashMatches(abc, " ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                && !SelfUpdater.hashMatches(abc, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n")
                && !SelfUpdater.hashMatches(abc, "ga7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))

        // The C# vector is the powershell.exe command line; macOS starts /bin/bash with an argv array (nothing to quote).
        t.check("update: hidden, no-prompt installer command line that keeps the pairing",
                SelfUpdater.shell == "/bin/bash"
                && SelfUpdater.arguments("/var/folders/xy/abc/T/recitbot-update-1.sh", "https://recitbot.com")
                == ["/var/folders/xy/abc/T/recitbot-update-1.sh", "--server", "https://recitbot.com", "--update"])
        t.check("update (mac): argv keeps spaces and quotes as one argument each",
                SelfUpdater.arguments("/tmp/a b/\"x\".sh", "http://127.0.0.1:8787") == ["/tmp/a b/\"x\".sh", "--server", "http://127.0.0.1:8787", "--update"])
        t.equal("update (mac): script name recitbot-update-<Guid N>.sh",
                SelfUpdater.scriptName(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!), "recitbot-update-0f1e2d3c4b5a69788796a5b4c3d2e1f0.sh")
        t.check("update report frames", SelfUpdater.reportJson("0.5.0", nil) == "{\"type\":\"update\",\"status\":\"installing\",\"version\":\"0.5.0\"}"
                && SelfUpdater.reportJson("0.5.0", "bad \"x\" <y>") == "{\"type\":\"update\",\"status\":\"failed\",\"version\":\"0.5.0\",\"error\":\"bad x y\"}")
        t.check("update (mac): report error cut to 200 after sanitizing; all-stripped error dropped",
                SelfUpdater.reportJson("0.5.0", String(repeating: "é", count: 10) + String(repeating: "a", count: 250))
                == "{\"type\":\"update\",\"status\":\"failed\",\"version\":\"0.5.0\",\"error\":\"" + String(repeating: "a", count: 200) + "\"}"
                && SelfUpdater.reportJson("0.5.0", "<>") == "{\"type\":\"update\",\"status\":\"failed\",\"version\":\"0.5.0\"}")
        t.equal("update (mac): limits", "\(SelfUpdater.maxScriptBytes) \(SelfUpdater.timeoutSeconds) \(SelfUpdater.cooldown)", "1048576 30.0 600.0")

        installed(t)
        install(t, link: link)
        deferRollback(t)
    }

    static func installed(_ t: SelfTest) {
        let home = "/Users/u", data = "/Users/u/Library/Application Support/Recitbot"
        let exe = "/Users/u/Applications/Recitbot.app/Contents/MacOS/Recitbot"
        t.check("update (mac): installed = binary inside ~/Applications/Recitbot.app and the default data folder",
                SelfUpdater.installedCheck(executable: exe, home: home, dataDir: data, defaultDataDir: data) == nil
                && SelfUpdater.installedCheck(executable: exe, home: home + "/", dataDir: data + "/", defaultDataDir: data) == nil
                && SelfUpdater.installedCheck(executable: "/users/U/applications/recitbot.app/Contents/MacOS/Recitbot", home: home, dataDir: data.uppercased(), defaultDataDir: data) == nil)
        let notApp = "not an installed recorder (app is not in Applications/Recitbot.app)"
        t.check("update (mac): a dev build, /Applications or a look-alike bundle is not an installed recorder",
                SelfUpdater.installedCheck(executable: "/Users/u/src/mac-recorder/.build/release/Recitbot", home: home, dataDir: data, defaultDataDir: data) == notApp
                && SelfUpdater.installedCheck(executable: "/Applications/Recitbot.app/Contents/MacOS/Recitbot", home: home, dataDir: data, defaultDataDir: data) == notApp
                && SelfUpdater.installedCheck(executable: "/Users/u/Applications/Recitbot.app2/Contents/MacOS/Recitbot", home: home, dataDir: data, defaultDataDir: data) == notApp
                && SelfUpdater.installedCheck(executable: "/Users/u/Applications/Recitbot.app", home: home, dataDir: data, defaultDataDir: data) == notApp)
        t.equal("update (mac): a --data run is not an installed recorder",
                SelfUpdater.installedCheck(executable: exe, home: home, dataDir: "/tmp/rb", defaultDataDir: data) ?? "",
                "not an installed recorder (data folder is not the install folder)")
    }

    /// SelfUpdater.Run/Install against a scripted platform: every step's error, its report frame and log line.
    static func install(_ t: SelfTest, link: String) {
        let home = "/Users/u", data = "/Users/u/Library/Application Support/Recitbot"
        let script = Data("#!/bin/bash\necho ok\n".utf8)
        let hash = SelfUpdater.hashHex(script).lowercased()
        let cfg = Config(dir: data)
        var clock = Date(timeIntervalSince1970: 1_731_650_000)

        final class Platform {
            var downloads = [String](), starts = [(Data, String)]()
            var body = Data()
            var downloadError: Error?, startError: Error?
        }
        let p = Platform()
        let gate = UpdateGate(now: { clock })
        func env(exe: String? = nil) -> UpdateEnvironment {
            return UpdateEnvironment(executable: exe ?? home + "/Applications/Recitbot.app/Contents/MacOS/Recitbot", home: home, defaultDataDir: data, download: { u in
                p.downloads.append(u)
                if let e = p.downloadError { throw e }
                return p.body
            }, start: { d, s in
                if let e = p.startError { throw e }
                p.starts.append((d, s))
            }, gate: gate)
        }

        // Log lines go to a scratch agent.log for the duration.
        let logDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-update-" + UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: logDir) }
        let logPath = (logDir as NSString).appendingPathComponent("agent.log")
        let savedLog = Log.pathName
        Log.pathName = logPath
        defer { Log.pathName = savedLog }
        func lastLog() -> String {
            let l = (try? SecureFile.readLines(logPath))?.last ?? ""
            guard let sp = l.firstIndex(of: " ") else { return l }
            return String(l[l.index(after: sp)...])
        }
        var frames = [String]()
        let queue = DeferredUpdates()
        func run(_ version: String?, busy: Bool = false, otherUrl: String? = nil, noUrl: Bool = false, e: UpdateEnvironment? = nil) -> String? {
            frames.removeAll()
            let url = noUrl ? nil : otherUrl ?? link
            SelfUpdater.run(cfg: cfg, server: "https://recitbot.com", busy: busy, version: version, sha256: hash, url: url, env: e ?? env(),
                            held: queue) { frames.append($0) }
            return frames.count == 1 ? frames[0] : frames.isEmpty ? nil : "\(frames.count) frames"
        }
        func failed(_ err: String) -> String { return SelfUpdater.reportJson("9.0.0", err) }
        p.body = script

        t.check("update (mac): not newer = ignored, logged, no frame, nothing fetched",
                run(Program.version) == nil && lastLog() == "update to \(Program.version) ignored: not newer than \(Program.version)" && run(nil) == nil
                && lastLog() == "update to ? ignored: not newer than \(Program.version)" && p.downloads.isEmpty)
        t.check("update (mac): while recording = deferred (held), nothing fetched or started",
                run("9.0.0", busy: true) == SelfUpdater.statusJson("deferred", "9.0.0", nil)
                && lastLog() == "update to 9.0.0: recording in progress; deferred until it is uploaded"
                && p.downloads.isEmpty && p.starts.isEmpty && queue.held?.version == "9.0.0")
        _ = queue.take()
        t.check("update (mac): refused outside ~/Applications/Recitbot.app",
                run("9.0.0", e: env(exe: "/tmp/Recitbot")) == failed("not an installed recorder (app is not in Applications/Recitbot.app)") && p.downloads.isEmpty)
        t.check("update (mac): rejected link never fetched",
                run("9.0.0", otherUrl: "https://evil.example/i/" + String(repeating: "t", count: 40)) == failed("update link rejected")
                && run("9.0.0", noUrl: true) == failed("update link rejected") && p.downloads.isEmpty)

        p.downloadError = UpdateFailure("WebException")
        let d1 = run("9.0.0")
        p.downloadError = nil
        p.body = Data("tampered".utf8)
        let d2 = run("9.0.0")
        t.check("update (mac): download failure / sha256 mismatch reported, nothing started, cooldown freed",
                d1 == failed("download failed: WebException") && d2 == failed("sha256 mismatch") && lastLog() == "update to 9.0.0 failed: sha256 mismatch"
                && p.downloads == [link, link] && p.starts.isEmpty)
        p.body = script
        let ok = run("9.0.0")
        t.check("update (mac): verified script started with the server, reported installing",
                ok == "{\"type\":\"update\",\"status\":\"installing\",\"version\":\"9.0.0\"}" && lastLog() == "update to 9.0.0: installer started"
                && p.starts.count == 1 && p.starts[0].0 == script && p.starts[0].1 == "https://recitbot.com")
        clock = clock.addingTimeInterval(9 * 60 + 59)
        let busyGate = run("9.0.0")
        clock = clock.addingTimeInterval(1)
        let again = run("9.0.0")
        t.check("update (mac): one at a time for 10 minutes",
                busyGate == failed("an update is already in progress") && again == "{\"type\":\"update\",\"status\":\"installing\",\"version\":\"9.0.0\"}"
                && p.starts.count == 2 && p.downloads.count == 4)
        clock = clock.addingTimeInterval(600)
        p.startError = UpdateFailure("IOException")
        let s1 = run("9.0.0")
        p.startError = nil
        let s2 = run("9.0.0")
        t.check("update (mac): script not written = installer not started; the cooldown stays armed (as in C#)",
                s1 == failed("installer not started: IOException") && lastLog() == "update to 9.0.0 failed: an update is already in progress"
                && s2 == failed("an update is already in progress"))
        t.check("update (mac): no secret or link in any update log line",
                !((try? SecureFile.readText(logPath)) ?? "").contains("/i/"))
    }

    /// 0.6.1 (hello "update_defer_rollback"): an update during a recording is held and reported "deferred" (newest
    /// version wins, no installer), and runs once the recording is uploaded; one whose link expired by then fails
    /// without an installer; the installer's health decision and the restored recorder's "rolled_back". The template
    /// half (update_health, the swap and rollback) is mac/installer/check.sh and flow-test.sh.
    /// parity: AgentRecorder.cs UpdateDeferRollbackSelfTest (same case names)
    static func deferRollback(_ t: SelfTest) {
        let server = "https://recitbot.com", sha = "6685944C4FFFC4F5B140100CEEB4BD6BC9663578062018C2E8B0756C7ECE7D9D"
        let now: Int64 = 1_731_650_000
        func link(_ exp: Int64) -> String {
            return "https://recitbot.com/i/v1.update.BBBBBBBBBBBBBBBBBBBBBB.\(exp).NNNNNNNNNNNN.." + String(repeating: "M", count: 43)
        }
        final class Box { var sent = [String](), installs = [String]() }
        let b = Box()
        let install: (PendingUpdate) throws -> String? = { p in b.installs.append(p.version ?? ""); return nil }
        func upd(_ v: String, _ url: String, _ cmdExp: Int64) -> PendingUpdate {
            return PendingUpdate(version: v, sha256: sha, url: url, server: server, expires: SelfUpdater.expiry(url, cmdExp), send: { b.sent.append($0) })
        }
        func last() -> String? { return b.sent.last }
        func deferred(_ v: String) -> String { return "{\"type\":\"update\",\"status\":\"deferred\",\"version\":\"" + v + "\"}" }

        let q = DeferredUpdates()
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: true, held: q, install: install)
        t.check("update defer: while recording the update is held, reported deferred, no installer started",
                b.sent.count == 1 && last() == deferred("0.7.0") && SelfUpdater.statusJson("deferred", "0.7.0", nil) == deferred("0.7.0")
                && b.installs.isEmpty && q.held?.version == "0.7.0")
        SelfUpdater.handle(upd("0.7.2", link(now + 600), now + 60), busy: true, held: q, install: install)
        SelfUpdater.handle(upd("0.7.1", link(now + 600), now + 60), busy: true, held: q, install: install)
        t.check("update defer: the newest pending version is kept (an older one reports the held version)",
                q.held?.version == "0.7.2" && b.sent.count == 3 && b.sent[1] == deferred("0.7.2") && b.sent[2] == deferred("0.7.2") && b.installs.isEmpty)
        SelfUpdater.handle(upd("0.7.2", link(now + 900), now + 60), busy: true, held: q, install: install)
        t.check("update defer: the same version again replaces the held one (fresher link)", q.held?.version == "0.7.2" && q.held?.expires == now + 900)
        var before = b.sent.count
        SelfUpdater.handle(upd(Program.version, link(now + 600), now + 60), busy: true, held: q, install: install)
        SelfUpdater.handle(upd("0.7.3", "https://evil.example/i/" + String(repeating: "t", count: 40), now + 60), busy: true, held: q, install: install)
        t.check("update defer: not newer is ignored, a rejected link fails at once; neither is held",
                b.sent.count == before + 1 && last() == SelfUpdater.reportJson("0.7.3", "update link rejected") && q.held?.version == "0.7.2" && b.installs.isEmpty)
        SelfUpdater.runDeferred(busy: { true }, held: q, now: now + 100, install: install)
        t.check("update defer: a recording running again at upload time keeps it held", b.installs.isEmpty && q.held != nil)
        before = b.sent.count
        SelfUpdater.runDeferred(busy: { false }, held: q, now: now + 100, install: install)
        t.check("update defer: after the recording is uploaded the held update runs (installing)",
                b.installs == ["0.7.2"] && b.sent.count == before + 1 && last() == SelfUpdater.reportJson("0.7.2", nil) && q.held == nil)
        SelfUpdater.runDeferred(busy: { false }, held: q, now: now + 100, install: install)
        t.check("update defer: nothing held, nothing runs", b.installs.count == 1 && b.sent.count == before + 1)
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: false, held: q, install: install)
        t.check("update defer: not recording installs at once (nothing held)", b.installs.count == 2 && last() == SelfUpdater.reportJson("0.7.0", nil) && q.held == nil)
        let thrown = b.sent.count
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: false, held: q, install: { _ in throw UpdateFailure("IOException") })
        t.check("update defer: an installer that cannot start reports failed",
                b.sent.count == thrown + 1 && last() == SelfUpdater.reportJson("0.7.0", "installer not started: IOException"))

        let tok = "https://recitbot.com/i/" + String(repeating: "t", count: 40)
        t.check("update expiry: read from the Worker link, the command exp when the link has none",
                SelfUpdater.linkExpiry(link(1_731_650_600)) == 1_731_650_600 && SelfUpdater.linkExpiry(tok) == 0 && SelfUpdater.linkExpiry(nil) == 0
                && SelfUpdater.linkExpiry("https://recitbot.com/i/v1.update.B.12x4.N.." + String(repeating: "M", count: 43)) == 0
                && SelfUpdater.expiry(link(1_731_650_600), 1_731_650_060) == 1_731_650_600 && SelfUpdater.expiry(tok, 1_731_650_060) == 1_731_650_060)
        let expiredError = "update link expired while deferred (send the update again)"
        let qe = DeferredUpdates()
        let n = b.installs.count
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: true, held: qe, install: install)
        SelfUpdater.runDeferred(busy: { false }, held: qe, now: now + 600, install: install)
        t.check("update expiry: a deferred update whose link expired by the upload reports failed and starts no installer",
                b.installs.count == n && last() == SelfUpdater.reportJson("0.7.0", expiredError) && (last() ?? "").contains("\"status\":\"failed\"") && qe.held == nil)
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: true, held: qe, install: install)
        SelfUpdater.runDeferred(busy: { false }, held: qe, now: now + 600 - SelfUpdater.expiryMarginSeconds, install: install)
        let margin = b.installs.count == n && last() == SelfUpdater.reportJson("0.7.0", expiredError)
        SelfUpdater.handle(upd("0.7.0", link(now + 600), now + 60), busy: true, held: qe, install: install)
        SelfUpdater.runDeferred(busy: { false }, held: qe, now: now + 600 - SelfUpdater.expiryMarginSeconds - 1, install: install)
        t.check("update expiry: 15 s of margin for the download; before that it runs", margin && b.installs.count == n + 1)
        SelfUpdater.handle(upd("0.7.0", tok, now + 60), busy: true, held: qe, install: install)
        SelfUpdater.runDeferred(busy: { false }, held: qe, now: now + 60, install: install)
        t.check("update expiry: an expired command exp (no expiry in the link) fails too",
                b.installs.count == n + 1 && last() == SelfUpdater.reportJson("0.7.0", expiredError))

        func decide(_ m: String?, _ running: Bool, _ elapsed: Double) -> UpdateHealth.Verdict {
            return UpdateHealth.decide(marker: m, version: "0.7.0", running: running, elapsed: elapsed, window: 90)
        }
        t.check("update rollback: health marker naming the new version within the window = success (no rollback)",
                decide(UpdateHealth.markerText("0.7.0"), true, 10) == .healthy && decide("\u{FEFF}version=0.7.0\r\n", true, 89.9) == .healthy
                && decide(UpdateHealth.markerText("0.7.0"), false, 95) == .healthy)
        t.check("update rollback: no marker yet within the window = keep waiting", decide(nil, true, 0) == .wait && decide("", true, 89.9) == .wait)
        t.check("update rollback: marker missing after the window, the old version's marker, or the recorder gone = rollback",
                decide(nil, true, 90) == .rollBack && decide(UpdateHealth.markerText("0.6.1"), true, 95) == .rollBack
                && decide("version=0.7.0x", true, 95) == .rollBack && decide(nil, false, 3) == .rollBack)
        t.equal("update rollback: rolled_back report frame", UpdateHealth.rolledBackJson("0.7.0"), "{\"type\":\"update\",\"status\":\"rolled_back\",\"version\":\"0.7.0\"}")

        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-update-rollback-" + UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        UpdateHealth.writeMarker(dir: dir, version: Program.version)
        let marker = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(UpdateHealth.markerFile), encoding: .utf8)
        t.check("update rollback (mac): the marker install.sh reads (version=<this version>)", marker == "version=" + Program.version + "\n")
        let record = (dir as NSString).appendingPathComponent(UpdateHealth.rollbackFile)
        try? "version=0.7.0\n".write(toFile: record, atomically: true, encoding: .utf8)
        let rolled = UpdateHealth.rolledBack(dir: dir, current: Program.version)
        let still = FileManager.default.fileExists(atPath: record) ? UpdateHealth.rolledBack(dir: dir, current: "0.7.0") : "missing"
        t.check("update rollback: the restored recorder reads the attempted version; a record for its own (or an older) version is stale and goes",
                rolled == "0.7.0" && still == nil && !FileManager.default.fileExists(atPath: record))
        t.equal("update rollback (mac): file names and window shared with install.sh",
                "\(UpdateHealth.markerFile) \(UpdateHealth.rollbackFile) \(UpdateHealth.backupApp) \(UpdateHealth.windowSeconds)",
                "update-health.txt update-rollback.txt .Recitbot.app.rollback 90")
    }
}
