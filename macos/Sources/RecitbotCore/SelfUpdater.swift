import CryptoKit
import Foundation

/// The Worker's signed "update" command (hello "self_update"): downloads install.sh (the twin of install.ps1) from the
/// signed link, checks its SHA-256 and runs it detached with --update, which keeps this Mac's pairing, stops this
/// process (launchctl bootout) once the new app is verified, swaps ~/Applications/Recitbot.app and bootstraps the
/// LaunchAgent again (whose hello then reports the new version). Only for a newer version, only from the server this Mac
/// talks to (or recitbot.com), never while recording, one at a time. The result goes back as
/// {"type":"update","status":"installing"|"failed","version":...,"error"?}.
/// 0.6.1 (hello "update_defer_rollback"): an update that arrives while recording is held (newest version wins) and
/// reported "deferred"; it runs once that recording is uploaded (runDeferred), or fails when its link has expired by
/// then. install.sh --update keeps the previous app and rolls back when the new recorder never reports healthy
/// (UpdateHealth); the restored recorder then reports "rolled_back".
/// parity: AgentRecorder.cs SelfUpdater (kit-install == cb8c7c7). The decisions live here; the download and the process
/// start are the app's (UpdateEnvironment), so the whole Install order is covered by the selftest.
public enum SelfUpdater {
    public static let maxScriptBytes = 1024 * 1024
    /// The update held while a recording runs (at most one: the newest).
    public static let deferred = DeferredUpdates()
    static let cooldown: TimeInterval = 10 * 60
    /// HttpWebRequest Timeout and ReadWriteTimeout (ms 30000).
    public static let timeoutSeconds: TimeInterval = 30
    /// The installer's interpreter (powershell.exe on Windows).
    public static let shell = "/bin/bash"
    /// The app bundle install.sh installs, under ~/Applications.
    public static let appBundle = "Recitbot.app"
    /// One gate per process, like the C# static Gate/startedAt.
    public static let gate = UpdateGate()

    /// Strictly greater x.y.z. Anything that is not x.y.z is never newer.
    public static func isNewer(_ version: String?, _ current: String?) -> Bool {
        guard let a = parse(version), let b = parse(current) else { return false }
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    /// ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ then int.Parse. .NET's `$` also matches before one final "\n" and int.Parse
    /// skips trailing white space, so "1.2.3\n" parses there; mirrored.
    static func parse(_ v: String?) -> [Int]? {
        guard var v = v else { return nil }
        if v.hasSuffix("\n") && !v.hasSuffix("\r\n") { v.removeLast() }
        let p = v.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 3, p.allSatisfy({ (1...3).contains($0.unicodeScalars.count) && $0.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 } })
        else { return nil }
        return p.map { Int($0)! }
    }

    /// The signed download link: https (http only against a loopback dev server), the server's host or recitbot.com,
    /// path /i/<token>, no query, nothing the parser had to normalize (LinkPolicy.CanonicalUrl only takes URLs that
    /// Uri.AbsoluteUri gives back unchanged, and refuses userinfo and fragments).
    public static func urlAllowed(_ url: String?, _ server: String?) -> Bool {
        guard let url = url, !url.isEmpty, let u = LinkPolicy.CanonicalUrl(url), let s = LinkPolicy.ServerUrl(server ?? "") else { return false }
        let dev = s.isLoopback && u.isLoopback && u.scheme == "http"
        if u.scheme != "https" && !dev { return false }
        if u.query != nil { return false }
        if u.host != s.host && u.host != LinkPolicy.publicHost { return false }
        if u.port != nil && !dev { return false }
        return pathAllowed(u.path)
    }

    /// ^/i/[A-Za-z0-9._-]{20,400}$
    static func pathAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/i/") else { return false }
        let token = path.unicodeScalars.dropFirst(3)
        return token.count >= 20 && token.count <= 400 && token.allSatisfy { LinkPolicy.alnum($0) || "._-".unicodeScalars.contains($0) }
    }

    /// SHA-256 of the data against 64 hex digits, any case. Anything else never matches.
    public static func hashMatches(_ data: Data, _ sha256: String?) -> Bool {
        guard let want = sha256, want.unicodeScalars.count == 64, want.unicodeScalars.allSatisfy({ isHex($0) }) else { return false }
        return hashHex(data) == want.uppercased()
    }

    /// SHA-256 as upper-case hex (C#: x.ToString("X2")).
    static func hashHex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func isHex(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
    }

    /// The installer's argv after /bin/bash: the script, the server, --update (keeps the pairing). install.sh has one
    /// fixed install location, so there is no -InstallDir. An argv array, never a command line: nothing to quote.
    /// parity: AgentRecorder.cs SelfUpdater.Arguments
    public static func arguments(_ script: String, _ server: String) -> [String] {
        return [script, "--server", server, "--update"]
    }

    /// recitbot-update-<Guid "N">.sh in the temp folder (C#: .ps1).
    public static func scriptName(_ id: UUID) -> String {
        return "recitbot-update-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".sh"
    }

    /// The update report frame; error text is cut to what the Worker accepts.
    public static func reportJson(_ version: String?, _ error: String?) -> String {
        return statusJson(error == nil ? "installing" : "failed", version, error)
    }

    /// {"type":"update","status":...,"version":...,"error"?}: "installing" / "failed" (reportJson), "deferred" (held
    /// until the recording is uploaded) or "rolled_back" (UpdateHealth: the installer put the previous version back).
    public static func statusJson(_ status: String, _ version: String?, _ error: String?) -> String {
        var e: String?
        if let error = error {
            var s = String(String.UnicodeScalarView(error.unicodeScalars.filter { c in
                let v = c.value
                return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || "_ .:,()'/-".unicodeScalars.contains(c)
            }))
            if s.count > 200 { s = String(s.prefix(200)) }
            e = s
        }
        return "{\"type\":\"update\",\"status\":" + Json.esc(status) + ",\"version\":" + Json.esc(version)
            + ((e ?? "").isEmpty ? "" : ",\"error\":" + Json.esc(e)) + "}"
    }

    /// Seconds before its expiry a held link counts as expired (the download still has to happen).
    public static let expiryMarginSeconds: Int64 = 15

    /// The expiry (unix s) inside a Worker update link /i/v1.<purpose>.<account>.<expires>.<random>.<code>.<sig>
    /// (worker/src/installer.ts installerUrl); 0 when the link has no readable one.
    public static func linkExpiry(_ url: String?) -> Int64 {
        guard let url = url, !url.isEmpty, let u = URL(string: url), u.scheme != nil, u.path.hasPrefix("/i/") else { return 0 }
        let p = u.path.dropFirst(3).split(separator: ".", omittingEmptySubsequences: false)
        guard p.count >= 4, p[0] == "v1", (1...12).contains(p[3].unicodeScalars.count),
              p[3].unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }), let e = Int64(p[3]) else { return 0 }
        return e
    }

    /// When a held update can no longer run: the link's own expiry, else the command's signed exp.
    public static func expiry(_ url: String?, _ commandExp: Int64) -> Int64 {
        let l = linkExpiry(url)
        return l > 0 ? l : commandExp
    }

    /// nil while p can still run at now, else the error its "failed" report carries (the server sends it again).
    public static func expired(_ p: PendingUpdate, _ now: Int64) -> String? {
        return p.expires > 0 && now >= p.expires - expiryMarginSeconds ? "update link expired while deferred (send the update again)" : nil
    }

    /// C#: the running AgentRecorder.exe must sit in the data folder (the install folder). macOS keeps the app and the
    /// data apart, so: the running binary is inside ~/Applications/Recitbot.app and the data folder is the default one
    /// (the one install.sh pairs into). A dev build or a --data run is never replaced.
    public static func installedCheck(executable: String, home: String, dataDir: String?, defaultDataDir: String) -> String? {
        let app = NetParse.lowerInvariant(trimSlash(home) + "/Applications/" + appBundle + "/")
        if !NetParse.lowerInvariant(executable).hasPrefix(app) { return "not an installed recorder (app is not in Applications/Recitbot.app)" }
        if NetParse.lowerInvariant(trimSlash(dataDir ?? "")) != NetParse.lowerInvariant(trimSlash(defaultDataDir)) {
            return "not an installed recorder (data folder is not the install folder)"
        }
        return nil
    }

    static func trimSlash(_ s: String) -> String {
        var t = Substring(s)
        while t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }

    /// parity: AgentRecorder.cs SelfUpdater.Run (same log lines, same report frame).
    /// server: the server of the account whose connection sent the command; exp: the command's signed exp.
    public static func run(cfg: Config, server: String?, busy: Bool, version: String?, sha256: String?, url: String?, exp: Int64 = 0,
                           env: UpdateEnvironment, held: DeferredUpdates = SelfUpdater.deferred, send: @escaping (String) -> Void) {
        let p = PendingUpdate(version: version, sha256: sha256, url: url, server: server, expires: expiry(url, exp), send: send)
        handle(p, busy: busy, held: held) { p in try install(cfg: cfg, server: p.server, sha256: p.sha256, url: p.url, env: env) }
    }

    /// A verified update command: ignored unless newer than this recorder; while recording, held (the newest one) and
    /// reported "deferred" with nothing downloaded or started; else installed now. install: nil once the installer
    /// started, else the error. parity: AgentRecorder.cs SelfUpdater.Handle
    public static func handle(_ p: PendingUpdate, busy: Bool, held: DeferredUpdates, install: (PendingUpdate) throws -> String?) {
        if !isNewer(p.version, Program.version) {
            Log.write("update to " + (p.version ?? "?") + " ignored: not newer than " + Program.version)
            return
        }
        if !busy { apply(p, install); return }
        if !urlAllowed(p.url, p.server) {
            Log.write("update to " + (p.version ?? "") + " failed: update link rejected")
            p.send(reportJson(p.version, "update link rejected"))
            return
        }
        let kept = held.offer(p)
        Log.write("update to " + (p.version ?? "") + ": recording in progress; deferred until it is uploaded"
                  + (kept.id == p.id ? "" : " (" + (kept.version ?? "") + " is held)"))
        p.send(statusJson("deferred", kept.version, nil))
    }

    /// After a recording is uploaded (Recorder.onFinished): the held update, unless a recording is running again (then
    /// it stays held for that one). A link that expired meanwhile fails without a download (the server resends).
    /// parity: AgentRecorder.cs SelfUpdater.RunDeferred
    public static func runDeferred(busy: () -> Bool, held: DeferredUpdates, now: Int64, install: (PendingUpdate) throws -> String?) {
        if busy() { return }
        guard let p = held.take() else { return }
        if busy() { _ = held.offer(p); return }
        if !isNewer(p.version, Program.version) { return }
        if let e = expired(p, now) {
            Log.write("update to " + (p.version ?? "") + " failed: " + e)
            p.send(reportJson(p.version, e))
            return
        }
        Log.write("update to " + (p.version ?? "") + ": recording uploaded; running the deferred update")
        apply(p, install)
    }

    static func apply(_ p: PendingUpdate, _ install: (PendingUpdate) throws -> String?) {
        let failure: String?
        do { failure = try install(p) }
        catch let e { failure = "installer not started: " + UpdateFailure.typeName(e) }
        Log.write("update to " + (p.version ?? "") + (failure == nil ? ": installer started" : " failed: " + failure!))
        p.send(reportJson(p.version, failure))
    }

    /// nil when the installer started, else the error for the report frame. Throws when the script could not be
    /// written or started (the cooldown then stays armed, as in C#). Never called while recording (handle / runDeferred
    /// hold the update instead). parity: AgentRecorder.cs SelfUpdater.Install
    public static func install(cfg: Config, server: String?, sha256: String?, url: String?, env: UpdateEnvironment) throws -> String? {
        if let e = installedCheck(executable: env.executable, home: env.home, dataDir: cfg.dir, defaultDataDir: env.defaultDataDir) { return e }
        guard let link = url, urlAllowed(link, server) else { return "update link rejected" }
        if !env.gate.begin() { return "an update is already in progress" }
        let data: Data
        do { data = try env.download(link) } catch {
            env.gate.reset()
            return "download failed: " + UpdateFailure.typeName(error)
        }
        if !hashMatches(data, sha256) { env.gate.reset(); return "sha256 mismatch" }
        try env.start(data, server ?? "")
        return nil
    }
}

/// One verified update command: what to install, until when its link works (unix s; 0 = unknown) and where its report
/// goes (the connection it came in on). parity: AgentRecorder.cs PendingUpdate
public struct PendingUpdate {
    public let version: String?, sha256: String?, url: String?, server: String?
    public let expires: Int64
    public let send: (String) -> Void
    /// Identity for "is this the one held" (C# compares references).
    let id = UUID()

    public init(version: String?, sha256: String?, url: String?, server: String?, expires: Int64, send: @escaping (String) -> Void) {
        self.version = version; self.sha256 = sha256; self.url = url; self.server = server; self.expires = expires; self.send = send
    }
}

/// The update held while recording: at most one, the newest version (the same version again replaces it: a later command
/// has a fresher link). parity: AgentRecorder.cs DeferredUpdates
public final class DeferredUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PendingUpdate?

    public init() {}

    /// Holds p unless a newer version is held; returns the one held afterwards.
    public func offer(_ p: PendingUpdate) -> PendingUpdate {
        lock.lock(); defer { lock.unlock() }
        if let c = current, SelfUpdater.isNewer(c.version, p.version) { return c }
        current = p
        return p
    }

    public func take() -> PendingUpdate? {
        lock.lock(); defer { lock.unlock() }
        let p = current
        current = nil
        return p
    }

    public var held: PendingUpdate? { lock.lock(); defer { lock.unlock() }; return current }
}

/// The rollback of install.sh --update (hello "update_defer_rollback"): it keeps the previous app as
/// ~/Applications/.Recitbot.app.rollback, swaps, starts the new recorder and waits up to windowSeconds for markerFile
/// (in the data folder) naming the new version, which the recorder writes once a connection is up and its hello went
/// out. Missing by then (or the recorder gone): the previous app is renamed back (same bundle id and signature: the
/// privacy grants stay), rollbackFile records the attempted version and the previous recorder starts again; it reports
/// {"type":"update","status":"rolled_back","version":<attempted>} on each account's next connect. config.dat is never
/// part of the swap. decide is install.sh's update_health.
/// parity: AgentRecorder.cs UpdateHealth, mac/installer/install.template.sh update_health
public enum UpdateHealth {
    public static let markerFile = "update-health.txt", rollbackFile = "update-rollback.txt", backupApp = ".Recitbot.app.rollback"
    public static let windowSeconds = 90

    public enum Verdict { case wait, healthy, rollBack }

    public static func markerText(_ version: String) -> String { return "version=" + version + "\n" }

    /// The x.y.z of the first "version=" line, or nil.
    public static func versionIn(_ text: String?) -> String? {
        for raw in (text ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard line.hasPrefix("version=") else { continue }
            let v = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            return SelfUpdater.parse(v) != nil ? v : nil
        }
        return nil
    }

    /// The installer's check after the swap: the marker names the new version = healthy; else, once the window is over
    /// or the new recorder is gone, roll back; else keep waiting.
    public static func decide(marker: String?, version: String?, running: Bool, elapsed: Double, window: Double) -> Verdict {
        if let v = version, versionIn(marker) == v { return .healthy }
        if !running || elapsed >= window { return .rollBack }
        return .wait
    }

    public static func rolledBackJson(_ version: String) -> String { return SelfUpdater.statusJson("rolled_back", version, nil) }

    /// Written once per run, after the first hello went out. Never throws.
    public static func writeMarker(dir: String, version: String) {
        do { try markerText(version).write(toFile: (dir as NSString).appendingPathComponent(markerFile), atomically: true, encoding: .utf8) }
        catch { Log.write("update health marker not written: " + UpdateFailure.typeName(error)) }
    }

    /// The version a rollback put this recorder back from, or nil (none recorded, or this recorder is that version or
    /// newer: then the record is stale and goes).
    public static func rolledBack(dir: String, current: String) -> String? {
        let f = (dir as NSString).appendingPathComponent(rollbackFile)
        guard FileManager.default.fileExists(atPath: f) else { return nil }
        if let v = versionIn(try? String(contentsOfFile: f, encoding: .utf8)), SelfUpdater.isNewer(v, current) { return v }
        clear(dir: dir)
        return nil
    }

    public static func clear(dir: String) {
        try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(rollbackFile))
    }
}

/// The 10-minute cooldown: one installer at a time; a failed download or hash check frees it at once.
/// parity: AgentRecorder.cs SelfUpdater.Gate / startedAt / Cooldown
public final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?
    let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) { self.now = now }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if let s = startedAt, t.timeIntervalSince(s) < SelfUpdater.cooldown { return false }
        startedAt = t
        return true
    }

    func reset() { lock.lock(); startedAt = nil; lock.unlock() }
}

/// What the install needs from the platform. The app fills it in (MacUpdate.environment); the selftest scripts it.
public struct UpdateEnvironment {
    /// The running binary, symlinks resolved.
    public var executable: String
    public var home: String
    public var defaultDataDir: String
    /// GET of the signed link: no redirects, 30 s timeouts, at most maxScriptBytes. Throws UpdateFailure.
    public var download: (String) throws -> Data
    /// Writes the verified script (0700, temp folder) and starts /bin/bash <script> --server <server> --update detached.
    public var start: (Data, String) throws -> Void
    public var gate: UpdateGate

    public init(executable: String, home: String, defaultDataDir: String, download: @escaping (String) throws -> Data,
                start: @escaping (Data, String) throws -> Void, gate: UpdateGate = SelfUpdater.gate) {
        self.executable = executable; self.home = home; self.defaultDataDir = defaultDataDir
        self.download = download; self.start = start; self.gate = gate
    }
}

/// An update step that failed, named like the .NET exception the C# reports (e.GetType().Name), so the report frame
/// reads the same on both platforms: WebException (no response, timeout, HTTP >= 400), InvalidDataException (installer
/// too large), IOException (script not written), Win32Exception (process not started).
public struct UpdateFailure: Error, CustomStringConvertible {
    public let typeName: String
    public init(_ typeName: String) { self.typeName = typeName }
    public var description: String { return typeName }

    static func typeName(_ e: Error) -> String {
        if let f = e as? UpdateFailure { return f.typeName }
        return String(describing: type(of: e))
    }
}
