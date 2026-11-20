import Foundation

/// Self-uninstall (0.5.2; scoped to the running bundle, its LaunchAgent and its own data folder 0.5.3): the signed uninstall command and its ack, the
/// revocation decision (410 + device_revoked only), the revocation probe body, the handshake status parser, the enroll
/// retry, the install guard and the helper script, with the case names of AgentRecorder.cs SelfUninstallSelfTest; "(mac)"
/// cases are additions. The script also runs against a fake home in the temp folder (fake label, no tccutil, a pid above
/// macOS's pid range), once with a LaunchAgent plist pointing at the fake app and once with one pointing at another app,
/// and must remove only that fake install (and only the plist that points at it).
enum SelfTestUninstall {
    static func uninstall(_ t: SelfTest) {
        let acct = SelfTestCases.acct, dev = SelfTestCases.dev, rid = "Unin5tall01"
        var un: JsonFields = [
            "type": "uninstall", "recording_id": rid, "nonce": "1731650000000", "exp": "1731650060",
            "account_id": acct, "device_id": dev,
        ]
        t.equal("uninstall canonical form", CommandVerifier.canonical(un), "v1|uninstall|" + rid + "||0|1731650000000|1731650060|" + acct + "|" + dev + "|")
        un["mac"] = SelfTestCases.mac(un)
        let uv = SelfTestCases.verifier()
        let ur = uv.verify(un, 1731650000)
        t.check("uninstall command verifies and uninstalls", ur == nil && SelfUninstaller.commanded(ur, un), ur ?? "")
        t.equal("uninstall ack frame", SelfUninstaller.ackJson(rid, accountsRemaining: 0),
                "{\"type\":\"uninstall_ack\",\"request_id\":\"" + rid + "\",\"accounts_remaining\":0}")
        let replay = uv.verify(un, 1731650000)
        t.check("uninstall: replayed command rejected, no uninstall", replay == "replayed nonce" && !SelfUninstaller.commanded(replay, un), replay ?? "nil")
        var tampered = un
        tampered["recording_id"] = "Unin5tall02"
        let tr = SelfTestCases.verifier().verify(tampered, 1731650000)
        t.check("uninstall: tampered command rejected, no uninstall", tr == "bad mac" && !SelfUninstaller.commanded(tr, tampered), tr ?? "nil")
        var asStart = un
        asStart["type"] = "start"
        t.equal("uninstall: type swapped to start rejected", SelfTestCases.verifier().verify(asStart, 1731650000), "bad mac")
        let ex = SelfTestCases.verifier().verify(un, 1731650061)
        let wd = CommandVerifier(accountId: acct, deviceId: "DDDDDDDDDDDDDDDDDDDDDD", secret: SelfTestCases.key, noncePath: nil).verify(un, 1731650000)
        let wk = SelfTestCases.verifier(secret: "wrong-secret").verify(un, 1731650000)
        t.check("uninstall: expired / wrong device / wrong key rejected, no uninstall", ex == "expired" && wd == "wrong device" && wk == "bad mac"
                && !SelfUninstaller.commanded(ex, un) && !SelfUninstaller.commanded(wd, un) && !SelfUninstaller.commanded(wk, un))
        t.check("uninstall: other verified commands never uninstall", !SelfUninstaller.commanded(nil, asStart)
                && !SelfUninstaller.commanded(nil, JsonFields()) && !SelfUninstaller.commanded(nil, nil))

        let revoked = "{\"error\":\"device_revoked\"}"
        t.check("revoked: 410 + device_revoked", Revocation.isRevoked(410, revoked) && Revocation.isRevoked(410, " { \"error\" : \"device_revoked\", \"x\": 1 } "))
        let other = [0, 200, 401, 403, 404, 409, 426, 500, 502, 503].filter { Revocation.isRevoked($0, revoked) }
        t.check("revoked: 0, 200, 401, 403, 404, 409, 426, 500, 502, 503 with the same body are not", other.isEmpty, "\(other)")
        t.check("revoked: 410 with another, empty, null, non-JSON or nested body is not", !Revocation.isRevoked(410, "{\"error\":\"gone\"}")
                && !Revocation.isRevoked(410, "") && !Revocation.isRevoked(410, nil) && !Revocation.isRevoked(410, "device_revoked")
                && !Revocation.isRevoked(410, "<html>410 Gone</html>") && !Revocation.isRevoked(410, "{\"error\":{\"code\":\"device_revoked\"}}")
                && !Revocation.isRevoked(410, "{\"error\":\"DEVICE_REVOKED\"}") && !Revocation.isRevoked(410, "{\"err\":\"device_revoked\"}")
                && !Revocation.isRevoked(410, "{\"error\":null}"))
        t.check("revoked: 410 + device_revoked with a scope (account, all) is revoked", Revocation.isRevoked(410, "{\"error\":\"device_revoked\",\"scope\":\"account\"}")
                && Revocation.isRevoked(410, "{\"error\":\"device_revoked\",\"scope\":\"all\"}"))

        let pb = Revocation.probeBody(token: "fake-token-placeholder", platform: "macos")
        let pf = try? Json.parseFlat(pb)
        t.check("revocation probe body: JSON with exactly the dummy code, name, platform macos and the device_token", pf != nil && pf?.count == 4
                && Fields.opt(pf ?? JsonFields(), "code") == "0000000000" && Fields.opt(pf ?? JsonFields(), "name") == "revocation-check"
                && Fields.opt(pf ?? JsonFields(), "platform") == "macos" && Fields.opt(pf ?? JsonFields(), "device_token") == "fake-token-placeholder", pb)
        let pw = (try? Json.parseFlat(Revocation.probeBody(token: "a\"b\\c", platform: "windows"))) ?? JsonFields()
        t.check("revocation probe body: platform windows, token escaped", Fields.opt(pw, "platform") == "windows"
                && Fields.opt(pw, "device_token") == "a\"b\\c" && Fields.opt(pw, "code") == "0000000000")

        let m410 = "The server returned status code '410' when status code '101' was expected."
        t.check("handshake status: 410 and 401 from the WebSocketException text, also when wrapped",
                Revocation.handshakeStatus(m410) == 410 && Revocation.handshakeStatus(m410.replacingOccurrences(of: "410", with: "401")) == 401
                && Revocation.handshakeStatus("WebSocketException " + m410) == 410)
        t.check("handshake status: network errors are 0", Revocation.handshakeStatus("The Internet connection appears to be offline.") == 0
                && Revocation.handshakeStatus("The request timed out.") == 0 && Revocation.handshakeStatus("The connection was closed before the WebSocket opened.") == 0
                && Revocation.handshakeStatus("status code '41' when status code '101' was expected") == 0 && Revocation.handshakeStatus(nil) == 0)

        let retry = Frames.enrollRetryBody(status: 410, body: revoked, code: "ABCD1234", name: "Office Mac", held: "fake-token-placeholder")
        let rf = (try? Json.parseFlat(retry ?? "")) ?? JsonFields()
        t.check("enroll 410 retry body has no device_token key", retry != nil && !(retry ?? "").contains("device_token")
                && Fields.opt(rf, "code") == "ABCD1234" && Fields.opt(rf, "platform") == "macos", retry ?? "nil")
        t.check("enroll: no retry for other answers or without a held token",
                Frames.enrollRetryBody(status: 401, body: revoked, code: "ABCD1234", name: "Office Mac", held: "t") == nil
                && Frames.enrollRetryBody(status: 410, body: "{\"error\":\"gone\"}", code: "ABCD1234", name: "Office Mac", held: "t") == nil
                && Frames.enrollRetryBody(status: 410, body: revoked, code: "ABCD1234", name: "Office Mac", held: nil) == nil)

        t.check("sh quote: quotes escaped (mac)", SelfUninstaller.shQuote("/Users/o'brien/x") == "'/Users/o'\\''brien/x'"
                && SelfUninstaller.shQuote("$HOME `x` \"y\"") == "'$HOME `x` \"y\"'" && SelfUninstaller.shQuote("") == "''")
        t.check("app bundle of the running executable (mac)",
                SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/Contents/MacOS/Recitbot") == "/Users/u/Applications/Recitbot.app"
                && SelfUninstaller.bundle(ofExecutable: "/Volumes/X/Other Copy.app/Contents/MacOS/Recitbot") == "/Volumes/X/Other Copy.app"
                && SelfUninstaller.bundle(ofExecutable: "/R.app/Contents/MacOS/R") == "/R.app")
        t.check("app bundle: wrong trailing components are nil (mac)",
                SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/Contents/Resources/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/Contents/MacOS/") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/Contents/MacOS") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.app/Contents/MacOS/x/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/../Recitbot.app/Contents/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u//Recitbot.app/Contents/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "Recitbot.app/Contents/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "") == nil)
        t.check("app bundle: not a .app is nil (mac)",
                SelfUninstaller.bundle(ofExecutable: "/Users/u/src/recitbot/mac/.build/debug/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot/Contents/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/.app/Contents/MacOS/Recitbot") == nil
                && SelfUninstaller.bundle(ofExecutable: "/Users/u/Applications/Recitbot.apps/Contents/MacOS/Recitbot") == nil)

        let home = "/Users/o'brien"
        let planApp = SelfUninstaller.bundle(ofExecutable: InstallLayout.executable(home: home)) ?? ""
        let plan = SelfUninstaller.script(app: planApp + "/", home: home + "/", dataDir: home + "/Library/Application Support/Recitbot/",
                                          label: InstallLayout.label, agentPid: 4242, resetPrivacy: true)
        t.check("uninstall plan: silent, waits for the agent pid, stops only Recitbot",
                plan.hasPrefix("#!/bin/sh\n") && plan.contains("\nsleep 1\n") && plan.contains("\np=4242\n")
                && plan.contains("kill -0 \"$p\"") && plan.contains("*/Recitbot|Recitbot) kill -KILL \"$p\""), plan)
        t.check("uninstall plan: LaunchAgent bootout and plist removal",
                plan.contains("\nplist='/Users/o'\\''brien/Library/LaunchAgents/com.recitbot.agent.plist'\n")
                && plan.contains("\napp='/Users/o'\\''brien/Applications/Recitbot.app'\n")
                && plan.contains("\na=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \"$plist\" 2>/dev/null || true)\n")
                && plan.contains("\ncase \"$a\" in \"$app\"/*) launchctl bootout \"gui/$(id -u)/\"'com.recitbot.agent' >/dev/null 2>&1 || true; rm -f \"$plist\" ;; esac\n")
                && !plan.contains("\nlaunchctl bootout") && !plan.contains("\nrm -f '")
                && plan.range(of: "launchctl bootout")!.lowerBound < plan.range(of: "\np=4242\n")!.lowerBound
                && plan.range(of: "launchctl bootout")!.lowerBound < plan.range(of: "rm -rf")!.lowerBound, plan)
        t.check("uninstall plan: folder removed with retries, then the script itself, quotes escaped",
                plan.contains("\nrm -rf '/Users/o'\\''brien/Applications/Recitbot.app'\n")
                && plan.contains("\ntccutil reset All 'com.recitbot.agent' >/dev/null 2>&1 || true\n") && plan.hasSuffix("\nrm -f \"$0\"\n"), plan)
        let copy = SelfUninstaller.script(app: "/Volumes/X/Copy 'b'.app", home: home, dataDir: "/tmp/d", label: "x", agentPid: 1, resetPrivacy: false)
        t.check("uninstall plan: app is the quoted running bundle, data folder removed only while it holds config.dat (mac)",
                copy.contains("\napp='/Volumes/X/Copy '\\''b'\\''.app'\n") && copy.contains("\nrm -rf '/Volumes/X/Copy '\\''b'\\''.app'\n")
                && !copy.contains("Applications/Recitbot.app") && copy.contains("\ndata='/tmp/d'\n")
                && plan.contains("\ndata='/Users/o'\\''brien/Library/Application Support/Recitbot'\n[ -f \"$data/config.dat\" ] && rm -rf \"$data\"\n")
                && !plan.contains("rm -rf '/Users/o'\\''brien/Library") && plan.components(separatedBy: "rm -rf").count == 3, plan)
        t.check("uninstall plan: no tccutil when resetPrivacy is off (mac)",
                !SelfUninstaller.script(app: "/tmp/a.app", home: home, dataDir: "/tmp/d", label: "x", agentPid: 1, resetPrivacy: false).contains("tccutil"))
        let ids = ["0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"]
        t.check("uninstall script name, never one install.sh deletes as an update script (mac)",
                SelfUninstaller.scriptName(UUID(uuidString: ids[0])!) == "recitbot-uninstall-0f1e2d3c4b5a69788796a5b4c3d2e1f0.sh"
                && !InstallLayout.isUpdateScript(SelfUninstaller.scriptName(UUID())))

        let h = "/Users/u", exe = InstallLayout.executable(home: h), data = h + "/Library/Application Support/Recitbot"
        t.check("install guard: accepts the installed folder", SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: data, configExists: true) == nil
                && SelfUninstaller.installedCheck(executable: exe, home: h + "/", dataDir: data + "/", configExists: true) == nil)
        t.check("install guard: refuses drive roots", SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: "/", configExists: true) != nil)
        t.check("install guard: refuses LOCALAPPDATA / USERPROFILE / TEMP and folders above them",
                SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: h, configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: "/Users", configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: "/Users/U/", configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: h + "/x/..", configExists: true) != nil)
        t.check("install guard: refuses a data folder that is not the exe folder, relative or empty paths",
                SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: "Recitbot", configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: nil, configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: exe, home: "", dataDir: data, configExists: true) != nil)
        t.check("install guard: refuses a dev build outside Applications/Recitbot.app (mac)",
                SelfUninstaller.installedCheck(executable: "/Users/u/src/recitbot/mac/.build/debug/Recitbot", home: h, dataDir: data, configExists: true) != nil
                && SelfUninstaller.installedCheck(executable: "/Applications/Recitbot.app/Contents/MacOS/Recitbot", home: h, dataDir: data, configExists: true) != nil)
        t.check("install guard: refuses a folder without AgentRecorder.exe or config.dat",
                SelfUninstaller.installedCheck(executable: exe, home: h, dataDir: data, configExists: false) != nil)

        sandbox(t)
    }

    /// Runs the real script against <tmp>/recitbot-uninst-selftest-<uuid>/home: fake label (launchctl bootout of a label
    /// that is not loaded does nothing), resetPrivacy off, pid Int32.max (above macOS's pid range: waits for nothing,
    /// kills nothing). Every path it deletes is inside that fake home; the app is bundle(ofExecutable:) of the fake binary.
    /// Runs with the same fake label: the LaunchAgent plist's ProgramArguments[0] is first the fake app's binary (plist
    /// removed), then a second fake bundle's (plist kept); that second bundle and a second data folder are always kept.
    /// A last run without config.dat in the data folder keeps that folder.
    static func sandbox(_ t: SelfTest) {
        let fm = FileManager.default
        let g = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/recitbot-uninst-selftest-" + g
        let home = root + "/home o'brien"
        let label = "com.recitbot.selftest." + g
        let app = home + "/Applications/Recitbot.app", plist = home + "/Library/LaunchAgents/" + label + ".plist"
        let data = home + "/Library/Application Support/Recitbot", keep = home + "/Documents/keep.txt"
        let ours = app + "/Contents/MacOS/Recitbot", otherApp = home + "/Applications/Other.app"
        let other = otherApp + "/Contents/MacOS/Other", otherData = home + "/Library/Application Support/Recitbot Other"
        defer { try? fm.removeItem(atPath: root) }
        // The fake install, with a LaunchAgent plist (XML) whose ProgramArguments[0] is program, next to a second bundle
        // and a second data folder (with its own config.dat) that the script must keep.
        func install(_ program: String) throws {
            for d in [app + "/Contents/MacOS", otherApp + "/Contents/MacOS", home + "/Library/LaunchAgents", data, otherData, home + "/Documents"] {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            }
            for f in [ours, other, data + "/config.dat", otherData + "/config.dat", keep] { try Data("x".utf8).write(to: URL(fileURLWithPath: f)) }
            let agent: [String: Any] = ["Label": label, "ProgramArguments": [program, "--data", data]]
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: URL(fileURLWithPath: plist))
        }
        // Writes text to a fresh script in root, runs it with /bin/sh (stdio /dev/null) and returns its path.
        func run(_ text: String) throws -> String {
            let script = root + "/" + SelfUninstaller.scriptName(UUID())
            try Data(text.utf8).write(to: URL(fileURLWithPath: script))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SelfUninstaller.shell)
            p.arguments = [script]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return script
        }
        do {
            guard let bundle = SelfUninstaller.bundle(ofExecutable: ours), bundle == app else {
                t.check("uninstall sandbox (mac): app bundle of the fake executable", false, ours)
                return
            }
            let text = SelfUninstaller.script(app: bundle, home: home, dataDir: data, label: label, agentPid: Int32.max, resetPrivacy: false)
            guard text.components(separatedBy: "\n")
                    .filter({ ($0.hasPrefix("rm ") && !$0.hasPrefix("rm -f \"$0\"")) || $0.hasPrefix("plist=") || $0.hasPrefix("app=") || $0.hasPrefix("data=") })
                    .allSatisfy({ $0.contains("'" + home.replacingOccurrences(of: "'", with: "'\\''") + "/") }) else {
                t.check("uninstall sandbox (mac): every removed path is in the fake home", false, text)
                return
            }
            try install(ours)
            let script = try run(text)
            t.check("uninstall sandbox: helper removed the folder", !fm.fileExists(atPath: app) && !fm.fileExists(atPath: plist) && !fm.fileExists(atPath: data))
            t.check("uninstall sandbox: helper deleted its own script", !fm.fileExists(atPath: script))
            t.check("uninstall sandbox (mac): nothing else in the home removed", fm.fileExists(atPath: keep))
            t.check("uninstall sandbox (mac): LaunchAgent pointing at this app removed", !fm.fileExists(atPath: plist))
            let otherKept = fm.fileExists(atPath: other) && fm.fileExists(atPath: otherData + "/config.dat")

            try install(other)
            let script2 = try run(text)
            let kept = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plist)), options: [], format: nil)) as? [String: Any]
            let keptArgs = kept?["ProgramArguments"] as? [String]
            t.check("uninstall sandbox (mac): LaunchAgent pointing elsewhere kept", keptArgs?.first == other
                    && !fm.fileExists(atPath: app) && !fm.fileExists(atPath: data) && !fm.fileExists(atPath: script2) && fm.fileExists(atPath: keep))
            t.check("uninstall sandbox (mac): other app bundle and data kept", otherKept
                    && fm.fileExists(atPath: other) && fm.fileExists(atPath: otherData + "/config.dat"))

            // The data folder lost its config.dat before the helper ran: it is kept (the app is still removed).
            try install(ours)
            try fm.removeItem(atPath: data + "/config.dat")
            try Data("x".utf8).write(to: URL(fileURLWithPath: data + "/other.txt"))
            let script3 = try run(text)
            t.check("uninstall sandbox (mac): data folder without config.dat kept", fm.fileExists(atPath: data + "/other.txt")
                    && !fm.fileExists(atPath: app) && !fm.fileExists(atPath: script3))
        } catch {
            t.check("uninstall sandbox (mac): " + String(describing: error), false)
        }
    }
}
