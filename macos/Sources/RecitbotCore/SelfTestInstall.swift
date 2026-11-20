import Foundation

/// Phase (f) selftests, all "(mac)" additions: what install.sh relies on in the app (installer/check.sh and
/// installer/flow-test.sh cover the scripts themselves). Pure strings, no file system, no process.
enum SelfTestInstall {
    static func install(_ t: SelfTest) {
        let home = "/Users/u"
        let exe = InstallLayout.executable(home: home)
        t.equal("install: app path (mac)", exe, "/Users/u/Applications/Recitbot.app/Contents/MacOS/Recitbot")
        t.equal("install: app path, home with trailing slash (mac)", InstallLayout.executable(home: home + "/"), exe)
        t.equal("install: launch agent plist (mac)", InstallLayout.launchAgentPlist(home: home),
                "/Users/u/Library/LaunchAgents/com.recitbot.agent.plist")
        t.equal("install: zip name (mac)", InstallLayout.zipName(Program.version), "Recitbot-mac-" + Program.version + ".zip")

        // The app install.sh installs, run with install.sh's default data folder, is one SelfUpdater updates.
        let data = home + "/Library/Application Support/Recitbot"
        t.check("install: installed app passes the self-update check (mac)",
                SelfUpdater.installedCheck(executable: exe, home: home, dataDir: data, defaultDataDir: data) == nil)
        t.check("install: default data folder is the one install.sh pairs into (mac)",
                DataDir.defaultPath.hasSuffix("/Library/Application Support/Recitbot"))

        // The updater's script is the file install.sh deletes, and its argv is what install.sh parses.
        let ids = ["0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "00000000-0000-0000-0000-000000000000", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"]
        t.check("install: every update script name is one install.sh deletes (mac)",
                ids.allSatisfy { InstallLayout.isUpdateScript(SelfUpdater.scriptName(UUID(uuidString: $0)!)) }
                && InstallLayout.isUpdateScript(SelfUpdater.scriptName(UUID())))
        t.check("install: other scripts are never deleted (mac)",
                !InstallLayout.isUpdateScript("install.sh") && !InstallLayout.isUpdateScript("recitbot-install-1.sh")
                && !InstallLayout.isUpdateScript("recitbot-update-1.ps1") && !InstallLayout.isUpdateScript("x/recitbot-update-1.sh"))
        let argv = SelfUpdater.arguments("/tmp/recitbot-update-1.sh", "https://recitbot.com")
        t.check("install: updater argv is what install.sh parses (mac)",
                argv.count == 4 && InstallLayout.serverFlags.contains(argv[1]) && argv[2] == "https://recitbot.com"
                && InstallLayout.updateFlags.contains(argv[3]) && SelfUpdater.shell == "/bin/bash")

        // Result line and exit codes: the same as install.ps1 (bots parse them on both platforms).
        t.equal("install: ok line (mac)", InstallLayout.okLine(device: "dev_1", version: "0.5.0", autostart: "logon"),
                "RECITBOT_INSTALL_OK device=dev_1 version=0.5.0 autostart=logon")
        t.equal("install: failed line (mac)", InstallLayout.failedLine("Invalid pairing code."), "RECITBOT_INSTALL_FAILED: Invalid pairing code.")
        t.check("install: exit codes as install.ps1 (mac)",
                [InstallLayout.exitArguments, InstallLayout.exitDownload, InstallLayout.exitPairing, InstallLayout.exitNotStarted] == [2, 3, 4, 5])
        t.check("install: launch agent label is the bundle id (mac)", InstallLayout.label == "com.recitbot.agent")

        // Worker update_recorder (compareVersions(current, latest) >= 0 = up_to_date) and SelfUpdater.isNewer agree.
        let pairs: [(String, String, Int)] = [
            ("0.5.0", "0.5.0", 0), ("0.4.0", "0.5.0", -1), ("0.5.1", "0.5.0", 1), ("0.9.9", "0.10.0", -1),
            ("0.99.99", "1.0.0", -1), ("1.0.0", "0.99.99", 1), ("10.0.0", "9.0.0", 1), ("0.5.10", "0.5.9", 1),
        ]
        t.check("install: worker compareVersions vectors (mac)", pairs.allSatisfy { InstallLayout.compareVersions($0.0, $0.1) == $0.2 })
        t.check("install: isNewer agrees with the worker's version order (mac)",
                pairs.allSatisfy { SelfUpdater.isNewer($0.0, $0.1) == ($0.2 > 0) && SelfUpdater.isNewer($0.1, $0.0) == ($0.2 < 0) })
    }
}
