import Darwin
import Foundation
import RecitbotCore

/// The platform half of the self-update (SelfUpdater in Core decides; this fetches and starts).
/// parity: AgentRecorder.cs SelfUpdater.Install (the File.WriteAllBytes + Process.Start part) and SelfUpdater.Download
enum MacUpdate {
    static func environment() -> UpdateEnvironment {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        return UpdateEnvironment(executable: exe, home: home, defaultDataDir: DataDir.fullPath(DataDir.defaultPath),
                                 download: ScriptDownload.fetch, start: MacUpdate.start)
    }

    /// Writes the verified install.sh to $TMPDIR/recitbot-update-<guid>.sh (owner-only 0700, created fresh) and starts
    /// /bin/bash <script> --server <server> --update with stdin/stdout/stderr on /dev/null, no terminal, in its own process
    /// group: launchctl bootout (which install.sh runs to stop this agent) kills the job's process group, and the
    /// installer must outlive it. Not waited for (C#: using (Process.Start(psi)) { }); a reaper thread collects it if
    /// this process is still alive when it ends. install.sh deletes its own recitbot-update-*.sh when --update is done.
    static func start(_ data: Data, _ server: String) throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(SelfUpdater.scriptName(UUID()))
        try write(path, data)
        let argv = [SelfUpdater.shell] + SelfUpdater.arguments(path, server)
        let pid = try spawn(argv)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    /// File.WriteAllBytes, but 0700 and never through an existing file or link (O_EXCL | O_NOFOLLOW).
    static func write(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        if fd < 0 { throw UpdateFailure("IOException") }
        var ok = fchmod(fd, 0o700) == 0
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var off = 0
            while ok && off < b.count {
                let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; ok = false } else { off += n }
            }
        }
        if close(fd) != 0 { ok = false }
        if !ok { unlink(path); throw UpdateFailure("IOException") }
    }

    /// posix_spawn with a new process group, every inherited descriptor closed (POSIX_SPAWN_CLOEXEC_DEFAULT: not the
    /// instance lock, not the WebSocket) and 0/1/2 on /dev/null. The environment is passed on, like Process.Start.
    static func spawn(_ argv: [String]) throws -> pid_t {
        var attr: posix_spawnattr_t? = nil
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { throw UpdateFailure("Win32Exception") }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw UpdateFailure("Win32Exception") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var rc = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        if rc == 0 { rc = posix_spawnattr_setpgroup(&attr, 0) }
        if rc == 0 { rc = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        if rc == 0 { rc = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        if rc == 0 { rc = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
        if rc != 0 { throw UpdateFailure("Win32Exception") }

        let env = ProcessInfo.processInfo.environment.map { $0.key + "=" + $0.value }
        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer {
            for p in cargv { free(p) }
            for p in cenv { free(p) }
        }
        var pid: pid_t = 0
        rc = posix_spawn(&pid, argv[0], &actions, &attr, cargv, cenv)
        if rc != 0 { throw UpdateFailure("Win32Exception") }
        return pid
    }
}

/// GET of the signed install.sh link. parity: AgentRecorder.cs SelfUpdater.Download: Timeout and ReadWriteTimeout 30 s
/// (URLSession's idle timeout), AllowAutoRedirect = false (a 3xx is returned as it is: its body then fails the hash
/// check), HTTP >= 400 = WebException, more than MaxScriptBytes = InvalidDataException. No cookies, no cache.
final class ScriptDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var body = Data()
    private var status = 0
    private var tooLarge = false
    private var failed = false

    static func fetch(_ url: String) throws -> Data {
        guard let u = URL(string: url) else { throw UpdateFailure("UriFormatException") }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = SelfUpdater.timeoutSeconds
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false
        let d = ScriptDownload()
        let session = URLSession(configuration: c, delegate: d, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: u)
        req.timeoutInterval = SelfUpdater.timeoutSeconds
        session.dataTask(with: req).resume()
        d.done.wait()
        if d.tooLarge { throw UpdateFailure("InvalidDataException") }
        if d.failed || d.status == 0 || d.status >= 400 { throw UpdateFailure("WebException") }
        return d.body
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(status >= 400 ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if tooLarge { return }
        body.append(data)
        if body.count > SelfUpdater.maxScriptBytes { tooLarge = true; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil && !tooLarge && status < 400 { failed = true }
        done.signal()
    }
}
