import Darwin
import Foundation
import RecitbotCore

/// The platform half of the self-uninstall (SelfUninstaller in Core decides and writes the script; this starts it).
/// parity: AgentRecorder.cs SelfUninstaller.Run / Launch
enum MacUninstall {
    private static let lock = NSLock()
    private static var started = false

    /// Removes this install and exits the process. why goes to the log. Only an installed app deletes anything (dev runs
    /// log and exit), and only its own pieces: the bundle of the running executable and cfg.dir (0.5.3). The helper is written like the self-update script (MacUpdate.write: 0700, O_EXCL) and started in
    /// its own process group (MacUpdate.spawn), so the launchctl bootout it runs does not end it. If it cannot be
    /// started, config.dat is deleted so this Mac never reconnects with the dead token.
    static func run(cfg: Config, why: String) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let dataDir = cfg.dir ?? ""
        let config = (dataDir as NSString).appendingPathComponent("config.dat")
        if let refusal = SelfUninstaller.installedCheck(executable: exe, home: home, dataDir: dataDir, configExists: SecureFile.exists(config)) {
            Log.write("uninstall (" + why + "): " + refusal + "; nothing deleted, agent exiting")
            exit(Program.exitOk)
        }
        guard let app = SelfUninstaller.bundle(ofExecutable: exe) else {
            Log.write("uninstall (" + why + "): the running app bundle is unknown; nothing deleted, agent exiting")
            exit(Program.exitOk)
        }
        let script = SelfUninstaller.script(app: app, home: home, dataDir: dataDir, label: InstallLayout.label, agentPid: getpid(), resetPrivacy: true)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(SelfUninstaller.scriptName(UUID()))
        do {
            try MacUpdate.write(path, Data(script.utf8))
            do { _ = try MacUpdate.spawn([SelfUninstaller.shell, path]) } catch { unlink(path); throw error }
            Log.write("uninstall (" + why + "): helper started; removing the app, the LaunchAgent and " + dataDir)
        } catch {
            Log.write("uninstall (" + why + "): helper not started (" + Agent.message(error) + "); deleting config.dat so this Mac does not reconnect")
            SecureFile.delete(config)
        }
        exit(Program.exitOk)
    }
}

/// The confirming probe after a 410 handshake: one POST <server>/device/enroll with Revocation.probeBody (a dummy code and
/// the device token), 15 s, no redirects followed, no cookies, no cache. The server's pairDevice checks
/// isRevokedDeviceToken before it looks the code up, so a revoked token gets 410 {"error":"device_revoked","scope":...}
/// and no code is touched; a live token gets 401 (invalid code). The revocation's scope (Revocation.revokedScope) only for
/// 410 device_revoked; nil for anything else. The token is never logged. parity: AgentRecorder.cs Revocation.Probe
final class RevocationProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var body = Data()
    private var status = 0

    static func check(server: String?, token: String?) -> SelfUninstaller.Scope? {
        guard let u = URL(string: Frames.trimEndSlash(server ?? "") + "/device/enroll"), u.scheme == "https" || u.scheme == "http" else { return nil }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Revocation.probeTimeoutSeconds
        c.timeoutIntervalForResource = Revocation.probeTimeoutSeconds
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false
        let d = RevocationProbe()
        let session = URLSession(configuration: c, delegate: d, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = Revocation.probeTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Revocation.probeBody(token: token, platform: "macos").utf8)
        session.dataTask(with: req).resume()
        if d.done.wait(timeout: .now() + Revocation.probeTimeoutSeconds + 5) == .timedOut { return nil }
        return Revocation.revokedScope(d.status, String(decoding: d.body, as: UTF8.self))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count < 4096 { body.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { status = 0 }
        done.signal()
    }
}
