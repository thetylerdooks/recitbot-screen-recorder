import Foundation

/// One-click Screen Recording onboarding, all "(mac)": the pending start file, the one-shot flags, the bare-launch
/// handoff and the relaunch decisions. No TCC, no launchctl, no process: the real prompt and relaunch need a real run.
enum SelfTestOnboarding {
    static func onboarding(_ t: SelfTest) {
        flags(t)
        pending(t)
        launch(t)
        relaunch(t)
    }

    static func flags(_ t: SelfTest) {
        t.equal("onboarding: --check-screen (mac)", ScreenOnboarding.mode(["--check-screen"]), .checkScreen)
        t.equal("onboarding: --request-screen with --data (mac)", ScreenOnboarding.mode(["--request-screen", "--data", "/d"]), .requestScreen)
        t.equal("onboarding: no flag (mac)", ScreenOnboarding.mode(["--data", "/d"]), .none)
        t.equal("onboarding: flag values are not flags (mac)", ScreenOnboarding.mode(["--data", "--check-screenx"]), .none)
        t.check("onboarding: check line round trip (mac)",
                ScreenOnboarding.parseCheck(ScreenOnboarding.checkLine(true) + "\n")
                && !ScreenOnboarding.parseCheck(ScreenOnboarding.checkLine(false) + "\n"))
        t.check("onboarding: only an exact granted line counts (mac)",
                !ScreenOnboarding.parseCheck("") && !ScreenOnboarding.parseCheck("screen=granted?")
                && !ScreenOnboarding.parseCheck("xscreen=granted") && ScreenOnboarding.parseCheck("noise\r\nscreen=granted\r\n"))
        t.check("onboarding: pane deep link (mac)",
                ScreenOnboarding.paneUrl == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                && URL(string: ScreenOnboarding.paneUrl) != nil)
        t.equal("onboarding: pill hint (mac)", ScreenOnboarding.hint, "Flip Recitbot on, then come back")
        t.equal("onboarding: timeout error is the one the Worker already knows (mac)", ScreenOnboarding.deniedError,
                "CAPTURE_FAILED: Screen Recording permission is off for Recitbot")
        t.check("onboarding: errors fit the status frame (<=100 UTF-16) (mac)",
                [ScreenOnboarding.deniedError, ScreenOnboarding.stoppedError, ScreenOnboarding.replacedError].allSatisfy { $0.utf16.count <= 100 })
    }

    static func pending(_ t: SelfTest) {
        let frame = "{\"type\":\"start\",\"recording_id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"max_seconds\":120,\"mic\":true,\"monitor\":\"a\\\"b\"}"
        let p = PendingStart(recordingId: "AAAAAAAAAAAAAAAAAAAAAA", frame: frame, savedAt: 1_800_000_000, relaunches: 1)
        t.equal("onboarding: pending json round trip (mac)", PendingStart.parse(p.json), p)
        t.check("onboarding: saved frame parses back to the same command (mac)",
                (try? Json.parseFlat(PendingStart.parse(p.json)?.frame ?? "")).map { Fields.opt($0, "monitor") == "a\"b" && Fields.opt($0, "max_seconds") == "120" } ?? false)
        t.check("onboarding: malformed pending is ignored (mac)",
                PendingStart.parse("") == nil && PendingStart.parse("{}") == nil
                && PendingStart.parse(p.json.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")) == nil
                && PendingStart.parse(p.json.replacingOccurrences(of: "\"recording_id\":\"AAAAAAAAAAAAAAAAAAAAAA\"", with: "\"recording_id\":\"\"")) == nil)
        let at = p.savedAt
        t.check("onboarding: pending fresh within the wait (mac)", p.fresh(at) && p.fresh(at + ScreenOnboarding.waitSeconds - 1))
        t.check("onboarding: pending expires after the wait (mac)", !p.fresh(at + ScreenOnboarding.waitSeconds) && !p.fresh(at + 86400))
        t.check("onboarding: pending from the future is void (mac)", !p.fresh(at - 60) && p.fresh(at - 2))
        t.check("onboarding: expiresIn counts down to 0 (mac)", p.expiresIn(at) == ScreenOnboarding.waitSeconds && p.expiresIn(at + 9999) == 0)

        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try DataDir.create(dir)
            try PendingStore.save(dir, p)
            let mode = (try? FileManager.default.attributesOfItem(atPath: PendingStore.path(dir))[.posixPermissions] as? NSNumber)?.intValue
            t.check("onboarding: pending file is 0600 (it holds the upload token) (mac)", mode == 0o600, "mode \(String(describing: mode))")
            t.equal("onboarding: pending load (mac)", PendingStore.load(dir), p)
            t.equal("onboarding: pending claim takes it (mac)", PendingStore.claim(dir, now: at + 10), p)
            t.check("onboarding: pending claim is once only (mac)",
                    PendingStore.claim(dir, now: at + 10) == nil && !SecureFile.exists(PendingStore.path(dir)))
            try PendingStore.save(dir, p)
            t.check("onboarding: expired pending is removed, not started (mac)",
                    PendingStore.claim(dir, now: at + ScreenOnboarding.waitSeconds) == nil && !SecureFile.exists(PendingStore.path(dir)))
            try PendingStore.save(dir, p)
            PendingStore.clear(dir)
            t.check("onboarding: pending clear (mac)", PendingStore.load(dir) == nil)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? ["?"]
            t.check("onboarding: no claim or tmp files left (mac)", left.isEmpty, left.joined(separator: ","))
        } catch {
            t.check("onboarding: pending store (mac)", false, Config.message(error))
        }
    }

    static func launch(_ t: SelfTest) {
        let label = InstallLayout.label
        t.check("onboarding: bare launches (mac)",
                ScreenOnboarding.isBare([]) && ScreenOnboarding.isBare(["-psn_0_12345"])
                && ScreenOnboarding.isBare(["-NSDocumentRevisionsDebugMode", "YES"]))
        t.check("onboarding: flagged launches are not bare (mac)",
                !ScreenOnboarding.isBare(["--data", "/d"]) && !ScreenOnboarding.isBare(["--enroll"]) && !ScreenOnboarding.isBare(["-psn_0_1", "--set"]))
        t.equal("onboarding: LaunchServices launch hands off to launchd (mac)",
                ScreenOnboarding.launchDecision(args: [], xpcServiceName: nil, label: label), .handOff)
        t.equal("onboarding: Quit & Reopen launch hands off (mac)",
                ScreenOnboarding.launchDecision(args: ["-psn_0_1"], xpcServiceName: "application.com.recitbot.agent.1.2", label: label), .handOff)
        t.equal("onboarding: launchd's own job runs (mac)",
                ScreenOnboarding.launchDecision(args: [], xpcServiceName: label, label: label), .run)
        t.equal("onboarding: the LaunchAgent's --data launch runs (mac)",
                ScreenOnboarding.launchDecision(args: ["--data", "/d"], xpcServiceName: label, label: label), .run)
        t.equal("onboarding: a direct --data start runs (mac)",
                ScreenOnboarding.launchDecision(args: ["--data", "/d"], xpcServiceName: nil, label: label), .run)
        t.equal("onboarding: kickstart argv never kills (no -k) (mac)", ScreenOnboarding.kickstartArgv(uid: 501, label: label),
                ["/bin/launchctl", "kickstart", "gui/501/com.recitbot.agent"])
    }

    static func relaunch(_ t: SelfTest) {
        t.equal("onboarding: still off = wait (mac)", ScreenOnboarding.onPoll(childGranted: false, inProcess: false, relaunches: 0), .wait)
        t.equal("onboarding: granted = relaunch (mac)", ScreenOnboarding.onPoll(childGranted: true, inProcess: false, relaunches: 0), .relaunch)
        t.equal("onboarding: granted after one relaunch = relaunch again (mac)",
                ScreenOnboarding.onPoll(childGranted: true, inProcess: false, relaunches: 1), .relaunch)
        t.equal("onboarding: relaunches capped (mac)",
                ScreenOnboarding.onPoll(childGranted: true, inProcess: false, relaunches: ScreenOnboarding.maxRelaunches), .giveUp)
        t.equal("onboarding: this process sees it = start here (mac)", ScreenOnboarding.onPoll(childGranted: false, inProcess: true, relaunches: 9), .startHere)
        t.equal("onboarding: launchd job relaunches via launchd (mac)",
                ScreenOnboarding.relaunchTarget(xpcServiceName: InstallLayout.label, uid: 501, label: InstallLayout.label), "gui/501/com.recitbot.agent")
        t.check("onboarding: direct start respawns itself (mac)",
                ScreenOnboarding.relaunchTarget(xpcServiceName: nil, uid: 501, label: InstallLayout.label) == nil
                && ScreenOnboarding.relaunchTarget(xpcServiceName: "application.com.apple.Terminal.1", uid: 501, label: InstallLayout.label) == nil)
        let respawn = ["/Apps/My App.app/Contents/MacOS/Recitbot", "--data", "/a b"]
        let argv = ScreenOnboarding.helperArgv(waitFor: 4242, kickstart: "gui/501/com.recitbot.agent", respawn: respawn)
        t.check("onboarding: helper waits for the pid, kickstarts, else execs the argv unparsed (mac)",
                argv.count == 8 && argv[0] == "/bin/sh" && argv[1] == "-c" && argv[2].contains("kill -0 \"$0\"")
                && argv[2].contains("launchctl kickstart \"$1\"") && !argv[2].contains("-k") && argv[2].hasSuffix("shift; exec \"$@\"")
                && argv[3] == "4242" && argv[4] == "gui/501/com.recitbot.agent" && Array(argv[5...]) == respawn)
        t.check("onboarding: helper without a job respawns (mac)",
                ScreenOnboarding.helperArgv(waitFor: 1, kickstart: nil, respawn: respawn)[4] == "")
        t.check("onboarding: Quit & Reopen never stops a recording (mac)", ScreenOnboarding.refuseQuit(busy: true, sessionEnding: false))
        t.check("onboarding: logout always quits (mac)",
                !ScreenOnboarding.refuseQuit(busy: true, sessionEnding: true) && !ScreenOnboarding.refuseQuit(busy: false, sessionEnding: true))
        t.check("onboarding: idle agent quits (mac)", !ScreenOnboarding.refuseQuit(busy: false, sessionEnding: false))
    }
}
