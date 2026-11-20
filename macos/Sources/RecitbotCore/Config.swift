import Foundation

/// Small value helpers the config and the start command share with the (later) webcam bubble and video path code.
/// parity: AgentRecorder.cs WebcamBubble.MinPx/MaxPx/DefaultPx/PxForName/ClampPx
public enum WebcamSize {
    public static let minPx = 120, maxPx = 480, defaultPx = 240
    static let names = ["small", "medium", "large"]
    static let namePx = [160, 240, 360]

    /// small/medium/large (the MCP webcam_size enum) as a diameter in px at 100 % scale; -1 when unknown.
    public static func pxForName(_ name: String?) -> Int {
        guard let n = name, let i = names.firstIndex(of: n) else { return -1 }
        return namePx[i]
    }

    public static func clampPx(_ px: Int) -> Int { return max(minPx, min(maxPx, px)) }
}

/// parity: AgentRecorder.cs VideoChain.Normalize (the video_path key; unused on macOS but kept and normalized the same).
public enum VideoPath {
    public static func normalize(_ v: String?) -> String {
        let s = NetParse.lowerInvariant(NetParse.trim(v ?? ""))
        return s == "gpu" || s == "cpu" ? s : "auto"
    }
}

/// One Recitbot account this install is paired with: to that account it is its own device (own id, token and command
/// key, own WebSocket). parity: AgentRecorder.cs Config.Account
public struct Account: Equatable, Sendable {
    public var server: String, accountId: String, deviceId: String, deviceToken: String, deviceSecret: String

    public init(server: String, accountId: String, deviceId: String, deviceToken: String, deviceSecret: String) {
        self.server = server; self.accountId = accountId; self.deviceId = deviceId; self.deviceToken = deviceToken; self.deviceSecret = deviceSecret
    }
}

/// Persisted config (config.dat in the data dir), same keys and line format as Windows.
/// v2 (0.6.0): `config_version=2` first, the machine-wide settings, then one block per paired account
/// (`account.<n>.server/account_id/device_id/device_token/device_secret`). A v1 file (one account in the top-level
/// server/account_id/device_id/device_token/device_secret keys) is read as one account and written back as v2.
/// Secrets: Windows wraps device_token/device_secret with DPAPI. macOS has no DPAPI and the Keychain would prompt after
/// every ad-hoc-signed update, so they are stored as `b64:<base64>` in the 0600 file inside the 0700 data dir.
/// parity: AgentRecorder.cs Config
public final class Config: @unchecked Sendable {
    public var accounts: [Account] = []
    public var ffmpeg: String?, encoder: String?
    public var fps = 30
    /// "auto" (default), or "gpu" / "cpu" (config video_path). Kept for format parity; macOS always encodes with AVAssetWriter.
    public var videoPath = "auto"
    public var dir: String?
    // UI preferences (non-secret), changed from the bubble/pill and persisted with setPrefs.
    public var webcam = false, mirror = true
    /// "circle" or "rect".
    public var shape = "circle"
    public var camera: String?
    public var webcamPx = WebcamSize.defaultPx
    public var bubbleX: Int?, bubbleY: Int?
    /// kit-install's StopPopup position. Parsed for format compatibility; the pill (wes-8b83b0f) ignores it and uses pillAt.
    public var popupX: Int?, popupY: Int?
    /// Where the control pill was dropped, per monitor id: offset of the pill from the monitor's top-left
    /// (pill_at_<id>=x,y; macOS: points). parity: AgentRecorder.cs Config.PillAt (wes-8b83b0f)
    public var pillAt: [String: IPoint] = [:]
    static let fileGate = NSLock()

    public init(dir: String? = nil) { self.dir = dir }

    public var filePath: String { return Config.configPath(dir ?? "") }

    static let secretPrefix = "b64:"

    /// macOS stand-in for DPAPI Protect: never plaintext in the file, readable only through the 0600/0700 modes.
    public static func protect(_ s: String?) -> String {
        return secretPrefix + Data((s ?? "").utf8).base64EncodedString()
    }

    public static func unprotect(_ s: String) throws -> String {
        guard s.hasPrefix(secretPrefix), let d = Data(base64Encoded: String(s.dropFirst(secretPrefix.count))) else {
            throw NSError(domain: "Recitbot", code: 1, userInfo: [NSLocalizedDescriptionKey: "protected value is not readable on this Mac"])
        }
        return String(decoding: d, as: UTF8.self)
    }

    static func configPath(_ dir: String) -> String { return (dir as NSString).appendingPathComponent("config.dat") }

    /// The cross-process lock beside config.dat (the agent and an `--enroll` run both rewrite the file).
    static func lockPath(_ dir: String) -> String { return (dir as NSString).appendingPathComponent("config.lock") }

    /// Every read-modify-write of config.dat: the in-process gate, then the file lock.
    static func locked<T>(_ dir: String, _ body: () throws -> T) rethrows -> T {
        fileGate.lock()
        defer { fileGate.unlock() }
        return try SecureFile.withLock(lockPath(dir), body)
    }

    public static let versionLine = "config_version=2"
    /// The per-account keys: top-level in a v1 file, `account.<n>.<key>` in v2.
    static let accountKeys = ["server", "account_id", "device_id", "device_token", "device_secret"]
    static let accountPrefix = "account."

    /// The machine-wide lines of a new file (same keys and order as the v1 file had).
    static func defaultLines(ffmpeg: String?) -> [String] {
        return ["ffmpeg=" + (ffmpeg ?? ""), "encoder=", "fps=30", "webcam=0", "camera=", "webcam_px=" + String(WebcamSize.defaultPx),
                "mirror=1", "webcam_shape=circle", "auto_open_link=true"]
    }

    static func key(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return line }
        return String(line[..<eq])
    }

    /// A line that belongs to an account (v1 top-level account keys, v2 account blocks) or the version marker.
    static func isAccountLine(_ line: String) -> Bool {
        let k = key(line)
        return k == "config_version" || k.hasPrefix(accountPrefix) || accountKeys.contains(k)
    }

    static func accountLines(_ accounts: [Account]) -> [String] {
        var out = [String]()
        for (i, a) in accounts.enumerated() {
            let p = accountPrefix + String(i) + "."
            out += [p + "server=" + a.server, p + "account_id=" + a.accountId, p + "device_id=" + a.deviceId,
                    p + "device_token=" + protect(a.deviceToken), p + "device_secret=" + protect(a.deviceSecret)]
        }
        return out
    }

    /// The v2 file: the version line, every machine-wide line of `lines` byte-for-byte, then the accounts.
    static func v2Text(_ lines: [String], _ accounts: [Account]) -> String {
        return joinLines([versionLine] + lines.filter { !isAccountLine($0) } + accountLines(accounts))
    }

    /// The accounts in config.dat's lines, in file order: the v2 blocks, else (v1) the top-level keys. An entry missing
    /// a field, or whose secret does not decode here, is skipped (logged; it could never connect).
    static func parseAccounts(_ lines: [String]) -> [Account] {
        var v1 = [String: String]()
        var blocks = [Int: [String: String]]()
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
            if accountKeys.contains(k) { v1[k] = v; continue }
            guard k.hasPrefix(accountPrefix) else { continue }
            let rest = k.dropFirst(accountPrefix.count)
            guard let dot = rest.firstIndex(of: "."), let n = NetParse.int32(String(rest[..<dot])), n >= 0 else { continue }
            let field = String(rest[rest.index(after: dot)...])
            if accountKeys.contains(field) { blocks[n, default: [:]][field] = v }
        }
        let raw = lines.contains(versionLine) ? blocks.keys.sorted().map { blocks[$0]! } : (v1.isEmpty ? [] : [v1])
        var out = [Account]()
        for (i, b) in raw.enumerated() {
            guard let s = b["server"], let a = b["account_id"], let d = b["device_id"], let t = b["device_token"], let x = b["device_secret"],
                  !a.isEmpty, !d.isEmpty else {
                Log.write("config: account " + String(i) + " incomplete; skipped")
                continue
            }
            do {
                let acct = Account(server: s, accountId: a, deviceId: d, deviceToken: try unprotect(t), deviceSecret: try unprotect(x))
                if acct.deviceToken.isEmpty || out.contains(where: { $0.accountId == a }) { continue }
                out.append(acct)
            } catch {
                Log.write("config: account " + a + " unreadable; skipped: " + message(error))
            }
        }
        return out
    }

    /// nonce-<device id>.txt: each account's last accepted command nonce (its DeviceHub signs with its own counter).
    public static func noncePath(_ dir: String, deviceId: String) -> String {
        return (dir as NSString).appendingPathComponent("nonce-" + Frames.sanitizeCode(deviceId) + ".txt")
    }

    /// The v1 nonce.txt belongs to the v1 account: it moves with the migration so a replay is still refused.
    static func migrateNonce(_ dir: String, _ accounts: [Account]) {
        let old = (dir as NSString).appendingPathComponent("nonce.txt")
        guard let a = accounts.first, SecureFile.exists(old) else { return }
        if rename(old, noncePath(dir, deviceId: a.deviceId)) != 0 { SecureFile.delete(old) }
    }

    public enum Enrolled: Equatable { case added, refreshed }

    /// Adds the account an enroll returned, or refreshes the entry of the same account (new device id/token/secret):
    /// every other account and every machine-wide line stay as they are. A new file gets the default settings.
    /// ffmpeg (Windows: the install's ffmpeg) replaces the machine-wide value when given.
    public static func upsertAccount(_ dir: String, _ a: Account, ffmpeg: String? = nil) throws -> Enrolled {
        return try locked(dir) { () throws -> Enrolled in
            let path = configPath(dir)
            var lines = try SecureFile.exists(path) ? SecureFile.readLines(path) : defaultLines(ffmpeg: ffmpeg)
            if let f = ffmpeg {
                let line = "ffmpeg=" + f
                if let at = lines.firstIndex(where: { key($0) == "ffmpeg" }) { lines[at] = line } else { lines.append(line) }
            }
            var accounts = parseAccounts(lines)
            if !lines.contains(versionLine) { migrateNonce(dir, accounts) }
            let outcome: Enrolled
            if let at = accounts.firstIndex(where: { $0.accountId == a.accountId }) {
                if accounts[at].deviceId != a.deviceId { SecureFile.delete(noncePath(dir, deviceId: accounts[at].deviceId)) }
                accounts[at] = a
                outcome = .refreshed
            } else {
                accounts.append(a)
                outcome = .added
            }
            SecureFile.delete(noncePath(dir, deviceId: a.deviceId))
            try SecureFile.replace(path, v2Text(lines, accounts))
            return outcome
        }
    }

    /// Drops one account (its entry and nonce file); the accounts left. Only the entry of that device: an entry the
    /// same account got from a newer pairing (another device id) stays. Nothing changes when it is not listed.
    public static func removeAccount(_ dir: String, accountId: String, deviceId: String) throws -> [Account] {
        return try locked(dir) { () throws -> [Account] in
            let path = configPath(dir)
            guard SecureFile.exists(path) else { return [] }
            let lines = try SecureFile.readLines(path)
            var accounts = parseAccounts(lines)
            guard let at = accounts.firstIndex(where: { $0.accountId == accountId && $0.deviceId == deviceId }) else { return accounts }
            let gone = accounts.remove(at: at)
            try SecureFile.replace(path, v2Text(lines, accounts))
            SecureFile.delete(noncePath(dir, deviceId: gone.deviceId))
            return accounts
        }
    }

    /// The device_token an enroll sends: only the token held for the account the installer names (`--account`), so
    /// one account's token never goes out with another account's pairing code. nil = pair without a token.
    public static func enrollToken(_ accounts: [Account], account: String?) -> String? {
        guard let want = account, !want.isEmpty else { return nil }
        return accounts.first { $0.accountId == want }?.deviceToken
    }

    /// File.WriteAllLines: every line followed by a line break.
    static func joinLines(_ lines: [String]) -> String { return lines.map { $0 + "\n" }.joined() }

    /// Updates non-secret keys in place. Every other line (including the accounts and their protected secrets) is kept
    /// byte-for-byte, and the file is swapped atomically so a crash mid-write cannot lose the device credentials.
    /// kv = key, value, key, value, ...
    public func setPrefs(_ kv: String?...) {
        guard let d = dir else { return }
        do {
            try Config.locked(d) { () throws -> Void in
                var lines = try SecureFile.readLines(Config.configPath(d))
                var i = 0
                while i + 1 < kv.count {
                    let k = kv[i] ?? ""
                    defer { i += 2 }
                    if Config.isAccountLine(k + "=") { continue } // never rewritten from here
                    let line = k + "=" + (kv[i + 1] ?? "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    if let at = lines.firstIndex(where: { $0.hasPrefix(k + "=") }) { lines[at] = line } else { lines.append(line) }
                }
                try SecureFile.replace(Config.configPath(d), Config.joinLines(lines))
            }
        } catch {
            Log.write("config prefs not saved: " + Config.message(error))
        }
    }

    /// nil when config.dat does not exist. A v1 file is migrated: its one account is written back as v2 (same account,
    /// device id, token and secret: it stays paired) and nonce.txt moves to that account's nonce file.
    public static func load(_ dir: String) throws -> Config? {
        return try locked(dir) { () throws -> Config? in
            let c = Config(dir: dir)
            guard SecureFile.exists(c.filePath) else { return nil }
            let lines = try SecureFile.readLines(c.filePath)
            c.parse(lines)
            if !lines.contains(versionLine) && !c.accounts.isEmpty {
                do {
                    migrateNonce(dir, c.accounts)
                    try SecureFile.replace(c.filePath, v2Text(lines, c.accounts))
                    Log.write("config: migrated to v2 (" + String(c.accounts.count) + " account)")
                } catch {
                    Log.write("config: v2 migration not written: " + message(error))
                }
            }
            return c
        }
    }

    /// The accounts and the machine-wide settings of config.dat's lines.
    func parse(_ lines: [String]) {
        accounts = Config.parseAccounts(lines)
        var havePx = false
        var legacyPx = -1
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
            switch k {
            case "ffmpeg": ffmpeg = v
            case "encoder": if !v.isEmpty { encoder = v }
            case "fps": if let n = NetParse.int32(v) { fps = max(15, min(60, n)) }
            case "video_path": videoPath = VideoPath.normalize(v)
            case "webcam": webcam = v == "1" || v == "true"
            case "camera": if !v.isEmpty { camera = v }
            case "webcam_px": if let n = NetParse.int32(v) { webcamPx = WebcamSize.clampPx(n); havePx = true }
            case "webcam_size": legacyPx = WebcamSize.pxForName(v) // pre-0.2 configs: small/medium/large
            case "mirror": mirror = v != "0" && v != "false"
            case "webcam_shape": shape = v == "rect" ? "rect" : "circle"
            case "bubble_x": if let n = NetParse.int32(v) { bubbleX = n }
            case "bubble_y": if let n = NetParse.int32(v) { bubbleY = n }
            case "popup_x": if let n = NetParse.int32(v) { popupX = n }
            case "popup_y": if let n = NetParse.int32(v) { popupY = n }
            default:
                if k.hasPrefix("pill_at_") && k.count > 8 {
                    let xy = v.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    if xy.count == 2, let x = NetParse.int32(xy[0]), let y = NetParse.int32(xy[1]) { pillAt[String(k.dropFirst(8))] = IPoint(x, y) }
                }
            }
        }
        if !havePx && legacyPx > 0 { webcamPx = legacyPx }
    }

    /// Settings changeable with `Recitbot --set key=value` (non-secret, read when used, so a running agent picks them up
    /// without a restart).
    public static let settable = ["auto_open_link"]

    /// Normalized value for a settable key, or nil when the key or value is not allowed.
    public static func normalizeSetting(_ key: String?, _ value: String?) -> String? {
        guard let key = key, settable.contains(key), let value = value else { return nil }
        let v = NetParse.lowerInvariant(NetParse.trim(value))
        if v == "true" || v == "1" || v == "on" || v == "yes" { return "true" }
        if v == "false" || v == "0" || v == "off" || v == "no" { return "false" }
        return nil
    }

    /// A boolean setting straight from config.dat (default when absent or unreadable).
    public func readBool(_ key: String, _ def: Bool) -> Bool {
        guard let d = dir else { return def }
        do {
            let lines = try Config.locked(d) { try SecureFile.readLines(Config.configPath(d)) }
            for line in lines where line.hasPrefix(key + "=") {
                return Config.normalizeSetting(key, String(line.dropFirst(key.count + 1))) != "false"
            }
        } catch {
            Log.write("config read: " + Config.message(error))
        }
        return def
    }

    /// Exception.Message equivalent for log lines.
    public static func message(_ e: Error) -> String {
        if let j = e as? JsonFormatError { return j.description }
        return (e as NSError).localizedDescription
    }
}
