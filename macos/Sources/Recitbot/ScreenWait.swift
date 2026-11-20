import AppKit
import CoreGraphics
import RecitbotCore

/// The agent side of the one-click Screen Recording onboarding (ScreenOnboarding has the decisions). A start without the
/// permission waits here instead of failing: saved as pending, the system prompt (or, once macOS stops showing it, the
/// Screen Recording pane) shown, the pill up with its hint, and a `--check-screen` child polled every 2 s. On the grant
/// the agent hands over to a fresh copy of itself (launchd's job via kickstart), which starts the saved command.
final class ScreenWait: @unchecked Sendable {
    let dir: String
    /// This binary and its own arguments (the respawn when launchd does not run this copy).
    let exe: String
    let argv: [String]
    private let gate = NSLock()
    private var pending: PendingStart?
    private var pill: RecordingPill?
    private var gen = 0
    /// status frames out (Agent.sendStatus)
    var send: (String?, String, String?) -> Void = { _, _, _ in }
    /// Starts a saved command in this process (this process already sees the permission).
    var startHere: (PendingStart) -> Void = { _ in }
    var makePill: () -> RecordingPill = { PillHost() }

    init(dir: String, exe: String, argv: [String]) {
        self.dir = dir; self.exe = exe; self.argv = argv
    }

    var waiting: Bool { gate.lock(); defer { gate.unlock() }; return pending != nil }
    /// The recording id of the start that waits (nil when none).
    var waitingId: String? { gate.lock(); defer { gate.unlock() }; return pending?.recordingId }

    static func now() -> Int64 { return Int64(Date().timeIntervalSince1970) }

    /// A start that cannot record yet. prompt: a new command (asks macOS); false for a saved one a relaunch could not
    /// start either (it keeps waiting without asking again).
    func begin(_ p: PendingStart, monitor: MonitorInfo?, monitors: [MonitorInfo], cfg: Config, prompt: Bool) {
        gate.lock()
        let old = pending, oldPill = pill
        gen += 1
        let g = gen
        pending = p
        pill = nil
        gate.unlock()
        oldPill?.close()
        if let o = old, o.recordingId != p.recordingId {
            Log.write("screen: start " + o.recordingId + " replaced by " + p.recordingId)
            send(o.recordingId, "failed", ScreenOnboarding.replacedError)
        }
        do { try PendingStore.save(dir, p) } catch { Log.write("screen: pending start not saved: " + Config.message(error)) }
        Log.write("screen: Screen Recording is off; start " + p.recordingId + " waits up to "
                  + String(p.expiresIn(ScreenWait.now())) + " s for it")
        if prompt { request() }
        if let m = monitor {
            let pl = makePill()
            let id = p.recordingId
            if pl.showWaiting(monitor: m, monitors: monitors, cfg: cfg, hint: ScreenOnboarding.hint, onStop: { [weak self] in
                DispatchQueue.global().async { _ = self?.cancel(id) }
            }) {
                gate.lock()
                let current = g == gen
                if current { pill = pl }
                gate.unlock()
                if !current { pl.close() }
            } else {
                Log.write("screen: hint pill not shown")
            }
        }
        let t = Thread { self.poll(g) }
        t.name = "screen-wait"
        t.start()
    }

    /// CGRequestScreenCaptureAccess adds Recitbot to the list (switch off) and shows the system prompt whose button opens
    /// the pane. macOS shows that prompt once per app; from then on the request is silent, so the pane is opened here.
    private func request() {
        let marker = (dir as NSString).appendingPathComponent(ScreenOnboarding.promptedFile)
        let promptedBefore = SecureFile.exists(marker)
        _ = CGRequestScreenCaptureAccess()
        try? SecureFile.write(marker, String(ScreenWait.now()))
        if promptedBefore {
            Log.write("screen: system prompt already shown once; opening the Screen Recording pane")
            ScreenWait.openPane()
        } else {
            Log.write("screen: asked macOS for Screen Recording (system prompt)")
        }
    }

    static func openPane() {
        guard let u = URL(string: ScreenOnboarding.paneUrl) else { return }
        onMainAsync { _ = NSWorkspace.shared.open(u) }
    }

    /// stop_recording (or the pill's Stop) for the waiting start: true when it was this one.
    func cancel(_ id: String?) -> Bool {
        gate.lock()
        guard let p = pending, p.recordingId == (id ?? "") else { gate.unlock(); return false }
        gate.unlock()
        finish(nil, ScreenOnboarding.stoppedError, "stopped while waiting for Screen Recording")
        return true
    }

    /// A logout / shutdown while waiting: fail it now rather than leave a start the next login would pick up.
    func abandon() {
        if waiting { finish(nil, ScreenOnboarding.deniedError, "session ending") }
    }

    /// Ends the wait (gen nil = whichever is current) and reports error to the Worker.
    private func finish(_ g: Int?, _ error: String, _ why: String) {
        gate.lock()
        if let g = g, g != gen { gate.unlock(); return }
        let p = pending, pl = pill
        pending = nil; pill = nil; gen += 1
        gate.unlock()
        pl?.close()
        PendingStore.clear(dir)
        guard let s = p else { return }
        Log.write("screen: start " + s.recordingId + " failed (" + why + ")")
        send(s.recordingId, "failed", error)
    }

    private func poll(_ g: Int) {
        while true {
            Thread.sleep(forTimeInterval: ScreenOnboarding.pollSeconds)
            gate.lock()
            let cur = g == gen ? pending : nil
            gate.unlock()
            guard let p = cur else { return }
            if !p.fresh(ScreenWait.now()) { finish(g, ScreenOnboarding.deniedError, "timed out"); return }
            let decision = ScreenOnboarding.onPoll(childGranted: checkChild(), inProcess: CGPreflightScreenCaptureAccess(), relaunches: p.relaunches)
            switch decision {
            case .wait: continue
            case .giveUp: finish(g, ScreenOnboarding.deniedError, "still off after relaunching"); return
            case .startHere:
                gate.lock()
                if g != gen { gate.unlock(); return }
                let pl = pill
                pending = nil; pill = nil; gen += 1
                gate.unlock()
                pl?.close()
                PendingStore.clear(dir)
                Log.write("screen: Screen Recording is on; starting " + p.recordingId)
                startHere(p)
                return
            case .relaunch:
                gate.lock()
                if g != gen { gate.unlock(); return }
                gate.unlock()
                var next = p
                next.relaunches += 1
                do { try PendingStore.save(dir, next) } catch {
                    finish(g, ScreenOnboarding.deniedError, "pending start not saved: " + Config.message(error)); return
                }
                Log.write("screen: Screen Recording is on; relaunching to start " + p.recordingId)
                relaunch()
                return
            }
        }
    }

    /// A fresh process sees the switch (this one keeps its first answer): `Recitbot --check-screen`, at most 5 s.
    func checkChild() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--check-screen"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { Log.write("screen: check failed to start: " + Config.message(error)); return false }
        if done.wait(timeout: .now() + ScreenOnboarding.checkTimeout) == .timedOut {
            p.terminate()
            return false
        }
        return ScreenOnboarding.parseCheck(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Hands over to a fresh copy and exits: a detached helper waits for this pid, then kickstarts launchd's job (or
    /// starts this binary again). Never two copies: kickstart leaves a running job alone and the new copy takes the lock.
    func relaunch() {
        ScreenWait.spawnHelper(exe: exe, argv: argv)
        gate.lock(); let pl = pill; pill = nil; gate.unlock()
        pl?.close()
        DispatchQueue.main.async { exit(Program.exitOk) }
    }

    /// The pending start stays on disk for the next copy (a quit while waiting: "Quit & Reopen" before the poll saw it).
    func handOver() {
        gate.lock(); let p = pending; gate.unlock()
        guard var s = p else { return }
        s.relaunches += 1
        try? PendingStore.save(dir, s)
        ScreenWait.spawnHelper(exe: exe, argv: argv)
        Log.write("screen: quitting while " + s.recordingId + " waits; the next copy starts it")
    }

    static func spawnHelper(exe: String, argv: [String]) {
        let target = ScreenOnboarding.relaunchTarget(xpcServiceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
                                                     uid: getuid(), label: InstallLayout.label)
        let a = ScreenOnboarding.helperArgv(waitFor: getpid(), kickstart: target, respawn: [exe] + argv)
        if let e = Detached.spawn(a) { Log.write("screen: relaunch helper failed: " + e) }
    }
}

/// posix_spawn in a new session, stdio on /dev/null, no inherited descriptors: outlives this process and its launchd job
/// (AbandonProcessGroup). Returns an error text, nil when started.
enum Detached {
    static func spawn(_ argv: [String]) -> String? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, &cargs, environ)
        return rc == 0 ? nil : String(cString: strerror(rc))
    }

    /// Runs argv and waits (at most `timeout` s); the exit status, or nil when it did not start or finish.
    static func run(_ argv: [String], timeout: Double) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        return p.terminationStatus
    }
}
