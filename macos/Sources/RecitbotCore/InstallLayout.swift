import Foundation

/// What installer/install.template.sh, installer/uninstall.sh and the app agree on: where the app and the LaunchAgent
/// live, the zip the Worker serves, the self-update script name install.sh deletes, the result line and exit codes.
/// The scripts hard-code the same values; the selftest pins them here so a change on one side shows up.
/// parity: install.template.ps1 (result line, exit codes), SelfUpdater (script name, arguments)
public enum InstallLayout {
    /// LaunchAgent Label == CFBundleIdentifier (Info.plist).
    public static let label = "com.recitbot.agent"
    public static let executableName = "Recitbot"

    /// ~/Applications/Recitbot.app/Contents/MacOS/Recitbot: the LaunchAgent's ProgramArguments[0].
    public static func executable(home: String) -> String {
        return SelfUpdater.trimSlash(home) + "/Applications/" + SelfUpdater.appBundle + "/Contents/MacOS/" + executableName
    }

    /// ~/Library/LaunchAgents/com.recitbot.agent.plist
    public static func launchAgentPlist(home: String) -> String {
        return SelfUpdater.trimSlash(home) + "/Library/LaunchAgents/" + label + ".plist"
    }

    /// The app zip install.sh downloads from <server>/<zipName> (Windows: <server>/recorder.zip).
    public static func zipName(_ version: String) -> String {
        return "Recitbot-mac-" + version + ".zip"
    }

    /// install.sh deletes itself on exit when its file name has this shape and it runs with --update (install.ps1:
    /// `recitbot-update-*.ps1`). Must match every SelfUpdater.scriptName.
    public static func isUpdateScript(_ name: String) -> Bool {
        return name.hasPrefix("recitbot-update-") && name.hasSuffix(".sh") && !name.contains("/")
    }

    /// The flags install.sh accepts for each SelfUpdater.arguments entry (both spellings, like -Server / -Update).
    public static let serverFlags = ["--server", "-Server", "-server"]
    public static let updateFlags = ["--update", "-Update", "-update"]

    /// install.sh / install.ps1 exit codes.
    public static let exitArguments: Int32 = 2, exitDownload: Int32 = 3, exitPairing: Int32 = 4, exitNotStarted: Int32 = 5

    public static func okLine(device: String, version: String, autostart: String) -> String {
        return "RECITBOT_INSTALL_OK device=" + device + " version=" + version + " autostart=" + autostart
    }

    public static func failedLine(_ reason: String) -> String {
        return "RECITBOT_INSTALL_FAILED: " + reason
    }

    /// install.sh with a pairing code on a Mac that already has a working Recitbot.app of this version or newer: it only
    /// pairs the new account with that app (nothing stopped, swapped or wiped; the running agent picks the account up).
    /// installed nil = no app or no readable version: the full install. --update always reinstalls.
    public static func addAccountOnly(installed: String?, installer: String, update: Bool) -> Bool {
        guard !update, let v = installed, SelfUpdater.parse(v) != nil else { return false }
        return compareVersions(v, installer) >= 0
    }

    /// worker/src/installer.ts compareVersions (x.y.z, numeric per part). update_recorder sends an update only when
    /// this is < 0 for (current, latest); SelfUpdater.isNewer(latest, current) must agree on every valid x.y.z.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let pb = b.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        for i in 0..<3 {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
