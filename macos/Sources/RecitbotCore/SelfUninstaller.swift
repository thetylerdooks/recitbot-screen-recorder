import Foundation

/// When the server has revoked this device ("uninstall Recitbot"): the device WebSocket upgrade answers 410
/// {"error":"device_revoked","scope":...}. Only that exact answer counts; 401/403/404/409/426/5xx, a 410 with any other body,
/// timeouts, offline, DNS and TLS errors keep the agent reconnecting as before. Pure (the probe itself is the app's,
/// App/SelfUninstall.swift RevocationProbe).
/// parity: AgentRecorder.cs Revocation
public enum Revocation {
    /// The confirming probe's timeout (HttpWebRequest Timeout 15000 ms).
    public static let probeTimeoutSeconds: TimeInterval = 15

    /// The confirming probe's code: never a real pairing code (the server checks the token before the code anyway).
    public static let probeCode = "0000000000"

    /// The probe's POST /device/enroll body: {"code":"0000000000","name":"revocation-check","platform":<platform>,
    /// "device_token":<token>}. parity: AgentRecorder.cs Revocation.ProbeBody
    public static func probeBody(token: String?, platform: String) -> String {
        return "{\"code\":" + Json.esc(probeCode) + ",\"name\":\"revocation-check\",\"platform\":" + Json.esc(platform)
            + ",\"device_token\":" + Json.esc(token) + "}"
    }

    /// status 410 and a JSON body whose "error" is exactly "device_revoked".
    public static func isRevoked(_ status: Int, _ body: String?) -> Bool { return revokedScope(status, body) != nil }

    /// What a revocation removes (nil = not revoked): the body's "scope" (2026.11, {"error":"device_revoked",
    /// "scope":"account"|"all"}). "account" drops only that account's pairing; "all", or no scope at all (a server from
    /// before scopes, whose uninstall always removed everything), removes the install. Any other value counts as
    /// "account": the token is dead either way, and a 410 for one account says nothing about the others.
    /// parity: AgentRecorder.cs Revocation.RevokedScope
    public static func revokedScope(_ status: Int, _ body: String?) -> SelfUninstaller.Scope? {
        guard status == 410, let b = body, !b.isEmpty, let f = try? Json.parseFlat(b), let e = f["error"] ?? nil, e == "device_revoked" else { return nil }
        guard let v = f["scope"] ?? nil else { return .all }
        return v == "all" ? .all : .account
    }

    /// The status in "The server returned status code '410' when status code '101' was expected." (the text
    /// SocketDelegate builds, like the C# WebSocketException); 0 = none (network, DNS, TLS, timeout).
    public static func handshakeStatus(_ message: String?) -> Int {
        guard let m = message, let r = m.range(of: "status code '") else { return 0 }
        let rest = m[r.upperBound...]
        let digits = rest.prefix(3)
        guard digits.count == 3, digits.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              rest.dropFirst(3).hasPrefix("' when status code '101' was expected") else { return 0 }
        return Int(digits)!
    }
}

/// Removes this install when the server says so (hello "self_uninstall"): a verified "uninstall" command (answered first
/// with uninstall_ack) or a revoked device token (Revocation). A /bin/sh helper in its own process group boots the
/// LaunchAgent out (which ends this agent) and removes the plist, both only when the plist's ProgramArguments[0] is inside
/// this app bundle (only entries that point at this exe, 0.5.3), ends the agent pid if it still runs, removes the
/// bundle of the running executable and this install's own data folder (only while it holds config.dat), resets
/// Recitbot's privacy rows (like installer/uninstall.sh) and deletes itself. Only an installed recorder (installedCheck)
/// deletes anything; a dev run just stops connecting. The decisions and the script text live here; writing and starting
/// it is App/SelfUninstall.swift MacUninstall.
/// parity: AgentRecorder.cs SelfUninstaller
public enum SelfUninstaller {
    public static let shell = "/bin/sh"

    /// A verified (rejection == nil) command of type "uninstall". A rejected one never uninstalls.
    public static func commanded(_ rejection: String?, _ f: JsonFields?) -> Bool {
        guard rejection == nil, let f = f else { return false }
        return Fields.opt(f, "type") == "uninstall"
    }

    /// {"type":"uninstall_ack","request_id":"<recording_id>","accounts_remaining":<n>} (0 when the whole install goes).
    /// requestId nil: {"type":"uninstall_ack","accounts_remaining":0} with no request_id at all, the full-removal notice
    /// on the other accounts' sockets (the server revokes that connection's device and closes it).
    public static func ackJson(_ requestId: String?, accountsRemaining: Int) -> String {
        let rid = requestId.map { ",\"request_id\":" + Json.esc($0) } ?? ""
        return "{\"type\":\"uninstall_ack\"" + rid + ",\"accounts_remaining\":" + String(max(0, accountsRemaining)) + "}"
    }

    /// The signed command's `scope`: "account" removes only the account whose connection sent it; "all" removes the
    /// whole install. nil = an unknown value (or null): the command is rejected (scopeRejection).
    public enum Scope: Equatable { case account, all }

    /// No scope at all (a server from before scopes, whose uninstall always removed everything) = "all".
    public static func scope(_ f: JsonFields) -> Scope? {
        if !Fields.has(f, "scope") { return .all }
        let v = f["scope"] ?? nil
        if v == "account" { return .account }
        if v == "all" { return .all }
        return nil
    }

    /// The rejection of a verified "uninstall" command with an unknown scope (handled like any rejected command: logged,
    /// nothing removed); nil for every other frame.
    public static func scopeRejection(_ f: JsonFields) -> String? {
        return Fields.opt(f, "type") == "uninstall" && scope(f) == nil ? "unknown uninstall scope" : nil
    }

    /// How long the commanding connection's ack is waited for, and the other accounts' acks (sent at the same time).
    public static let ackWaitSeconds = 5.0, otherAcksWaitSeconds = 2.0

    /// One uninstall_ack frame and the account whose socket it goes on.
    public struct Ack: Equatable, Sendable {
        public let account: String
        public let frame: String
        public init(account: String, frame: String) { self.account = account; self.frame = frame }
    }

    /// The acks a removal sends, the commanding connection's first. requestId (the command's recording_id; nil for a
    /// revocation, which has no socket to answer on): ackJson(requestId, all ? 0 : accountsRemaining) on account's
    /// socket. all: ackJson(nil, 0) on every other account in connected (accounts whose sockets are not connected get
    /// nothing). Scope "account" with accounts left: nothing to the others.
    public static func acks(account: String, requestId: String?, all: Bool, accountsRemaining: Int, connected: [String]) -> [Ack] {
        var out = [Ack]()
        if let r = requestId { out.append(Ack(account: account, frame: ackJson(r, accountsRemaining: all ? 0 : accountsRemaining))) }
        if all {
            for c in connected where c != account && !out.contains(where: { $0.account == c }) {
                out.append(Ack(account: c, frame: ackJson(nil, accountsRemaining: 0)))
            }
        }
        return out
    }

    /// Whether the whole install goes: scope "all", or no account would be left (the last one is today's full removal).
    public static func removesAll(_ scope: Scope, accountsRemaining: Int) -> Bool { return scope == .all || accountsRemaining <= 0 }

    /// A /bin/sh single-quoted word: ' becomes '\''. (C#: PsQuote.)
    public static func shQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// recitbot-uninstall-<uuid hex>.sh in the temp folder (C#: .ps1).
    public static func scriptName(_ id: UUID) -> String {
        return "recitbot-uninstall-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".sh"
    }

    /// nil when this process may delete its install, else why not: the running binary is
    /// <home>/Applications/Recitbot.app/Contents/MacOS/Recitbot (InstallLayout.executable), and the data folder holds
    /// config.dat, is absolute, and is neither "/", home, nor a folder above home. (C#: InstalledCheck.)
    public static func installedCheck(executable: String, home: String, dataDir: String?, configExists: Bool) -> String? {
        let h = SelfUpdater.trimSlash(home)
        if h.isEmpty || !h.hasPrefix("/") { return "home folder unknown" }
        if NetParse.lowerInvariant(executable) != NetParse.lowerInvariant(InstallLayout.executable(home: h)) {
            return "not an installed recorder (app is not in Applications/Recitbot.app)"
        }
        let d = SelfUpdater.trimSlash(dataDir ?? "")
        if d.isEmpty || !d.hasPrefix("/") { return "data folder unknown" }
        let dl = NetParse.lowerInvariant(d), hl = NetParse.lowerInvariant(h)
        if dl == hl || hl.hasPrefix(dl + "/") || d.contains("/../") || d.hasSuffix("/..") { return "refusing to delete " + d }
        if !configExists { return "not an installed recorder (no config.dat)" }
        return nil
    }

    /// The .app bundle that holds the running executable: exe is <bundle>.app/Contents/MacOS/<name>, absolute, with no
    /// empty, "." or ".." components. nil when the path has any other shape (a dev build, a bare binary). (0.5.3)
    public static func bundle(ofExecutable exe: String) -> String? {
        let parts = exe.split(separator: "/", omittingEmptySubsequences: false)
        let n = parts.count
        guard exe.hasPrefix("/"), n >= 5, !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let b = parts[n - 4]
        guard parts[n - 3] == "Contents", parts[n - 2] == "MacOS", b.hasSuffix(".app"), b.count > 4 else { return nil }
        return parts[0..<(n - 3)].joined(separator: "/")
    }

    /// The helper script (pure). Every path is single-quoted (shQuote); every step ignores errors. app is the bundle of
    /// the running executable (bundle(ofExecutable:)), dataDir this install's own data folder (the one installedCheck
    /// validated). The LaunchAgent is booted out and its plist removed only when its ProgramArguments[0] is inside app:
    /// a plist under the same label that starts another app is kept. The data folder is removed only while it still
    /// holds config.dat. Other bundles and data folders are never touched (0.5.3). The agent pid wait + kill still ends
    /// this process when the plist is kept.
    /// parity: AgentRecorder.cs SelfUninstaller (only entries that point at this exe, only its own folder)
    public static func script(app bundle: String, home: String, dataDir: String, label: String, agentPid: Int32, resetPrivacy: Bool) -> String {
        let h = SelfUpdater.trimSlash(home)
        let app = SelfUpdater.trimSlash(bundle)
        var s = [
            "#!/bin/sh",
            "# Recitbot self-uninstall, written by the recorder; deletes itself when done.",
            "sleep 1",
            "# Unloads the LaunchAgent (ends the agent if it is still running) and removes its plist, only when the agent it",
            "# starts is inside this app bundle; this script has its own process group.",
            "plist=" + shQuote(h + "/Library/LaunchAgents/" + label + ".plist"),
            "app=" + shQuote(app),
            "a=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \"$plist\" 2>/dev/null || true)",
            "case \"$a\" in \"$app\"/*) launchctl bootout \"gui/$(id -u)/\"" + shQuote(label) + " >/dev/null 2>&1 || true; rm -f \"$plist\" ;; esac",
            "p=" + String(agentPid),
            "i=0",
            "while [ $i -lt 20 ] && kill -0 \"$p\" 2>/dev/null; do sleep 0.25; i=$((i + 1)); done",
            "case \"$(ps -p \"$p\" -o comm= 2>/dev/null || true)\" in",
            "  */Recitbot|Recitbot) kill -KILL \"$p\" 2>/dev/null || true ;;",
            "esac",
            "rm -rf " + shQuote(app),
            "data=" + shQuote(SelfUpdater.trimSlash(dataDir)),
            "[ -f \"$data/config.dat\" ] && rm -rf \"$data\"",
        ]
        if resetPrivacy { s.append("tccutil reset All " + shQuote(label) + " >/dev/null 2>&1 || true") }
        s.append("rm -f \"$0\"")
        return s.joined(separator: "\n") + "\n"
    }
}

extension Frames {
    /// The body of the one retry after enrolling with a held token got 410 {"error":"device_revoked"}: the same pairing
    /// without device_token (a fresh pairing). nil = no retry. parity: AgentRecorder.cs Program.EnrollRetryBody
    public static func enrollRetryBody(status: Int, body: String?, code: String, name: String, held: String?) -> String? {
        guard let h = held, !h.isEmpty, Revocation.isRevoked(status, body) else { return nil }
        return enrollBody(code: code, name: name, deviceToken: nil)
    }
}
