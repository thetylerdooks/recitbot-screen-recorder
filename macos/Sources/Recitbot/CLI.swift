import Foundation
import RecitbotCore
import SystemConfiguration

/// The one-shot command-line modes of Program.Main. parity: AgentRecorder.cs Program.Enroll / SetSetting / ListDevices
enum CLI {
    /// --set key=value [--data DIR]: changes one setting in config.dat (Config.settable, e.g. auto_open_link=false).
    /// Works while the agent runs; it reads these settings when it uses them. Exit 0 = saved, 6 = bad key/value,
    /// 3 = not installed/enrolled here.
    static func setSetting(_ kv: String?, _ dir: String) -> Int32 {
        var key: String?, value: String?
        if let kv = kv, let eq = kv.firstIndex(of: "="), eq > kv.startIndex {
            key = NetParse.trim(String(kv[..<eq]))
            value = Config.normalizeSetting(key, String(kv[kv.index(after: eq)...]))
        }
        guard let k = key, let v = value else {
            Log.write("--set: unknown setting or value (allowed: " + Config.settable.joined(separator: ", ") + " = true|false)")
            return Program.exitBadSetting
        }
        if !SecureFile.exists((dir as NSString).appendingPathComponent("config.dat")) {
            Log.write("--set: not enrolled in " + dir)
            return Program.exitNotEnrolled
        }
        Config(dir: dir).setPrefs(k, v)
        Log.write("setting " + k + " = " + v)
        return Program.exitOk
    }

    /// The computer name (System Settings > General > Sharing), the macOS counterpart of Environment.MachineName.
    static func machineName() -> String {
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName
    }

    /// --enroll --server URL [--name NAME] [--account ID]; the pairing code is read from stdin (never argv, never
    /// logged). The account the code pairs is added to config.dat, or its entry refreshed when it is already there; the
    /// other accounts stay. Prints `device=<id>` (the paired device id) on success.
    static func enroll(_ args: [String], _ dir: String) -> Int32 {
        let server = Program.arg(args, "--server")
        // The ffmpeg key stays in config.dat for format parity; macOS records without ffmpeg.
        let ffmpeg = Program.arg(args, "--ffmpeg")
        // The account the installer says the code is for: only its token is sent (Config.enrollToken).
        let account = Program.arg(args, "--account")
        let name = Program.arg(args, "--name") ?? machineName()
        let code = Frames.sanitizeCode(readLine(strippingNewline: true))
        guard let srv = server, !code.isEmpty else { Log.write("enroll: missing server or code"); return Program.exitBadArgs }
        guard let comps = URLComponents(string: srv), let scheme = comps.scheme?.lowercased(), let host = comps.host, !host.isEmpty else {
            Log.write("enroll failed: Invalid URI: The format of the URI could not be determined.")
            return Program.exitEnrollFailed
        }
        if scheme != "https" && !Frames.isLoopbackHost(host) { Log.write("enroll: server must be https"); return Program.exitBadArgs }
        guard let url = URL(string: Frames.trimEndSlash(srv) + "/device/enroll") else {
            Log.write("enroll failed: Invalid URI: The format of the URI could not be determined.")
            return Program.exitEnrollFailed
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A re-pair sends the token held for that account only; anything else (no --account, an account not paired here,
        // no config or an unreadable one) pairs without a token.
        var held: String? = nil
        do { held = Config.enrollToken(try Config.load(dir)?.accounts ?? [], account: account) } catch {
            Log.write("enroll: existing config unreadable, pairing as new: " + Config.message(error))
        }
        req.httpBody = Data(Frames.enrollBody(code: code, name: name, deviceToken: held).utf8)
        req.timeoutInterval = 100 // HttpWebRequest's default
        var (data, response, error) = syncRequest(req)
        // The token held here was revoked (the Mac was uninstalled from the account): an install is running, so this is
        // not an uninstall; pair once more as a new device. parity: AgentRecorder.cs Program.Enroll (EnrollRetryBody)
        if error == nil, let http = response as? HTTPURLResponse,
           let retry = Frames.enrollRetryBody(status: http.statusCode, body: String(decoding: data ?? Data(), as: UTF8.self), code: code, name: name, held: held) {
            Log.write("enroll: the pairing held here was revoked; pairing as a new device")
            req.httpBody = Data(retry.utf8)
            (data, response, error) = syncRequest(req)
        }
        if let e = error { Log.write("enroll failed: " + Config.message(e)); return Program.exitEnrollFailed }
        guard let http = response as? HTTPURLResponse else { Log.write("enroll failed: no response"); return Program.exitEnrollFailed }
        if !(200..<300).contains(http.statusCode) {
            Log.write("enroll failed: " + Frames.enrollError(http.statusCode, String(decoding: data ?? Data(), as: UTF8.self)))
            return Program.exitEnrollFailed
        }
        do {
            let f = try Json.parseFlat(String(decoding: data ?? Data(), as: UTF8.self))
            for k in ["account_id", "device_id", "device_token", "device_secret"] where !Fields.has(f, k) {
                throw PendingError("The given key was not present in the dictionary.")
            }
            let a = Account(server: Frames.trimEndSlash(srv), accountId: Fields.get(f, "account_id"), deviceId: Fields.get(f, "device_id"),
                            deviceToken: Fields.get(f, "device_token"), deviceSecret: Fields.get(f, "device_secret"))
            let outcome = try Config.upsertAccount(dir, a, ffmpeg: ffmpeg)
            Log.write("enrolled device " + a.deviceId + " (account " + a.accountId + (outcome == .added ? " added)" : " paired again)"))
            print("device=" + a.deviceId)
            return Program.exitOk
        } catch {
            Log.write("enroll failed: " + Agent.message(error))
            return Program.exitEnrollFailed
        }
    }

    /// One HTTP request, waited for (no cookies, no cache).
    static func syncRequest(_ req: URLRequest) -> (Data?, URLResponse?, Error?) {
        let conf = URLSessionConfiguration.ephemeral
        conf.httpCookieStorage = nil
        conf.urlCache = nil
        let session = URLSession(configuration: conf)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: req) { d, r, e in
            out = (d, r, e)
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    /// Dev modes the later phases bring (they need capture or UI). Until then: a line on stderr and exit 1.
    static func pending(_ flag: String, _ phase: String) -> Int32 {
        FileHandle.standardError.write(Data((flag + ": not available yet on this Mac recorder (phase " + phase + ")\n").utf8))
        return Program.exitFailed
    }
}

/// Single instance per data dir: an flock on a lock file there (the Windows named mutex "Local\AgentRecorder-<hash>",
/// same name derivation). Held for the life of the process; the kernel drops it when the process dies.
final class InstanceLock {
    let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    enum Outcome { case acquired(InstanceLock), held, failed(String) }

    static func name(_ dir: String) -> String {
        return "AgentRecorder-" + String(CommandVerifier.hmacHex("mutex", dir.lowercased()).prefix(16)) + ".lock"
    }

    static func acquire(_ dir: String) -> Outcome {
        let path = (dir as NSString).appendingPathComponent(name(dir))
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 { return .failed(String(cString: strerror(errno))) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            return e == EWOULDBLOCK ? .held : .failed(String(cString: strerror(e)))
        }
        return .acquired(InstanceLock(fd: fd))
    }
}
