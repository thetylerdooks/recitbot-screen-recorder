import Foundation
import RecitbotCore

/// The resident agent: one outbound WebSocket per paired account (AccountLink) to the Worker's DeviceHub, verified
/// commands in, status/inventory/update frames out on the connection the command came in on. One recording per machine
/// across accounts (RecordingOwners). config.dat is watched: an account added by `--enroll`, refreshed or removed is
/// connected / reconnected / dropped without a restart. parity: AgentRecorder.cs Agent (and the recorder side of
/// worker/src/device-hub.ts).
final class Agent: RecorderHost, @unchecked Sendable {
    let cfg: Config
    let mac = MacCatalog()
    var capture: CaptureBackend { return mac }
    var catalog: DeviceCatalog { return mac }
    var dir: String { return cfg.dir ?? "" }
    var workDir: String { return (dir as NSString).appendingPathComponent("tmp") }
    private(set) var recorder: RecorderControl!
    let links = ReadyLinks()
    let uploader: RecordingUploader
    let linkOpener: ShareLinkOpener
    /// Starts that wait for Screen Recording (macOS's one-click onboarding).
    let screen: ScreenWait
    /// Which account each recording belongs to (its statuses, upload and stop go through that account only).
    let owners = RecordingOwners()
    /// A start saved by the copy before this one (it relaunched on the grant), started once its account is connected.
    private var resumeAfterConnect: PendingStart?
    private let resumeLock = NSLock()
    private var resumeTaken = false
    /// True from launch until that saved start is handed to the recorder: a "Quit & Reopen" click landing in that
    /// window is refused like one during a recording (the start is no longer on disk to hand over).
    var resuming: Bool { resumeLock.lock(); defer { resumeLock.unlock() }; return resumeAfterConnect != nil }

    /// The running connections, by account id.
    private let accountsLock = NSLock()
    private var accounts = [String: AccountLink]()
    /// config.dat as last applied (SecureFile.stamp), and its watch.
    private let watchQueue = DispatchQueue(label: "com.recitbot.agent.config")
    private var configStamp: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    /// Set by removeAll (under removingLock).
    private let removingLock = NSLock()
    private var removingAll = false
    /// The update the installer rolled back from (UpdateHealth.rolledBack), reported once per account; nil = none.
    private let rolledBack: String?
    private let healthLock = NSLock()
    private var healthWritten = false
    private var rolledBackSent = Set<String>()

    /// Application-level ping period, answered by the Durable Object's auto-response (no wake-up).
    static let pingSeconds: UInt64 = 45
    /// Reconnect backoff: 5 s doubling to 300 s, plus 0-2 s of jitter; back to 5 s after a successful connect.
    static let backoffStart = 5, backoffMax = 300
    /// Frames longer than this are dropped (C# ReceiveLoop's 16 KiB buffer cap).
    static let maxFrameBytes = 16384
    /// A data-folder event is applied after this pause (an enroll's write and rename land together); without events,
    /// config.dat is still checked this often.
    static let reloadDelay = 0.3, reloadFallbackSeconds = 60.0

    init(cfg: Config) {
        self.cfg = cfg
        rolledBack = UpdateHealth.rolledBack(dir: cfg.dir ?? "", current: Program.version)
        uploader = HttpUploader()
        linkOpener = MacLinkOpener()
        screen = ScreenWait(dir: cfg.dir ?? "", exe: Bundle.main.executablePath ?? CommandLine.arguments[0],
                            argv: Array(CommandLine.arguments.dropFirst()))
        let r = Recorder(host: self)
        r.onFinished = { [unowned self] in DispatchQueue.global().async { self.afterRecording() } }
        recorder = r
        if let v = rolledBack { Log.write("update to " + v + " was rolled back by the installer; this is " + Program.version) }
        screen.send = { [unowned self] id, status, error in self.sendStatus(id, status, error) }
        screen.startHere = { [unowned self] p in self.startSaved(p, prompt: false) }
        if let p = PendingStore.claim(cfg.dir ?? "", now: Agent.unixNow()) {
            if let a = AccountSet.account(ofFrame: p.frame), cfg.accounts.contains(where: { $0.accountId == a }), owners.claim(p.recordingId, account: a) {
                resumeAfterConnect = p
            } else {
                Log.write("screen: saved start " + p.recordingId + " belongs to no paired account; dropped")
            }
        }
    }

    static func unixNow() -> Int64 { return Int64(Date().timeIntervalSince1970) }

    /// Connects every account in config.dat and starts watching the file.
    func run() {
        watchQueue.sync {
            // Stamp first, then read: a change in between is seen by the watch.
            configStamp = SecureFile.stamp(cfg.filePath)
            let now: Config? = (try? Config.load(dir)) ?? nil
            apply(now?.accounts ?? cfg.accounts)
        }
        watchConfig()
    }

    // MARK: accounts

    /// Connects the accounts that are new or changed, ends the ones that are gone or changed.
    private func apply(_ wanted: [Account]) {
        accountsLock.lock()
        let d = AccountSet.diff(running: accounts.values.map { $0.account }, wanted: wanted)
        var stopped = [AccountLink](), started = [AccountLink]()
        for id in d.stop { if let l = accounts.removeValue(forKey: id) { stopped.append(l) } }
        for a in d.start {
            let l = AccountLink(agent: self, account: a)
            accounts[a.accountId] = l
            started.append(l)
        }
        accountsLock.unlock()
        for l in stopped {
            Log.write("account " + l.account.accountId + ": connection ended (removed or paired again)")
            l.stop()
        }
        for l in started {
            Log.write("account " + l.account.accountId + ": device " + l.account.deviceId)
            l.start()
        }
    }

    private func link(_ accountId: String?) -> AccountLink? {
        guard let a = accountId else { return nil }
        accountsLock.lock(); defer { accountsLock.unlock() }
        return accounts[a]
    }

    /// How many accounts would be left without this one.
    private func others(than l: AccountLink) -> Int {
        accountsLock.lock(); defer { accountsLock.unlock() }
        return accounts.keys.filter { $0 != l.account.accountId }.count
    }

    /// The data folder's vnode events (config.dat is replaced by a rename into it), plus a slow periodic check.
    private func watchConfig() {
        let fd = open(dir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: watchQueue)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        } else {
            Log.write("config watch not available; config.dat is checked every \(Int(Agent.reloadFallbackSeconds)) s")
        }
        fallbackCheck()
    }

    private func fallbackCheck() {
        watchQueue.asyncAfter(deadline: .now() + Agent.reloadFallbackSeconds) { [weak self] in
            self?.reloadIfChanged()
            self?.fallbackCheck()
        }
    }

    /// On watchQueue.
    private func scheduleReload() {
        if reloadPending { return }
        reloadPending = true
        watchQueue.asyncAfter(deadline: .now() + Agent.reloadDelay) { [weak self] in
            self?.reloadPending = false
            self?.reloadIfChanged()
        }
    }

    /// On watchQueue: reads config.dat again when it changed and applies its accounts. A missing file (an uninstall in
    /// progress) changes nothing.
    private func reloadIfChanged() {
        let s = SecureFile.stamp(cfg.filePath)
        if s == configStamp { return }
        configStamp = s
        guard s != nil else { return }
        do {
            guard let c = try Config.load(dir) else { return }
            apply(c.accounts)
        } catch {
            Log.write("config reload failed: " + Config.message(error))
        }
    }

    /// Removes one account from this install: its recording or waiting start ends, its entry and nonce file leave
    /// config.dat, its connection closes. The other accounts keep running.
    private func drop(_ l: AccountLink, why: String) {
        let a = l.account
        if let rid = recorder.current, owners.owns(rid, account: a.accountId) {
            Log.write("account " + a.accountId + " removed while recording " + rid + "; recording stopped")
            recorder.stop(id: rid)
        }
        if let w = screen.waitingId, owners.owns(w, account: a.accountId) { _ = screen.cancel(w) }
        do {
            let left = try Config.removeAccount(dir, accountId: a.accountId, deviceId: a.deviceId)
            Log.write("account " + a.accountId + " removed (" + why + "); " + String(left.count) + " left")
        } catch {
            Log.write("account " + a.accountId + " not removed from config.dat (" + why + "): " + Config.message(error))
        }
        accountsLock.lock()
        if accounts[a.accountId] === l { accounts.removeValue(forKey: a.accountId) }
        accountsLock.unlock()
        l.stop()
    }

    /// True once a full removal started: later revocations and uninstall commands change nothing (the process exits).
    private var removing: Bool { removingLock.lock(); defer { removingLock.unlock() }; return removingAll }

    /// The account ids whose sockets are connected now.
    private func connectedAccounts() -> [String] {
        accountsLock.lock(); defer { accountsLock.unlock() }
        return accounts.values.filter { $0.isConnected }.map { $0.account.accountId }
    }

    /// Sends SelfUninstaller.acks, all at once: the commanding connection's ack (waited for up to 5 s) and, for a full
    /// removal, {"type":"uninstall_ack","accounts_remaining":0} (no request_id) on every other connected account (waited
    /// for up to 2 s in all). Accounts that are not connected get nothing.
    private func sendAcks(_ l: AccountLink, requestId: String?, all: Bool, left: Int) {
        let begin = DispatchTime.now()
        let own = DispatchSemaphore(value: 0)
        let others = DispatchGroup()
        var waitOwn = false
        let me = l.account.accountId
        for ack in SelfUninstaller.acks(account: me, requestId: requestId, all: all, accountsRemaining: left, connected: connectedAccounts()) {
            if ack.account == me {
                waitOwn = true
                DispatchQueue.global().async { l.sendText(ack.frame); own.signal() }
            } else if let o = link(ack.account) {
                others.enter()
                DispatchQueue.global().async { o.sendText(ack.frame); others.leave() }
            }
        }
        if waitOwn && own.wait(timeout: begin + SelfUninstaller.ackWaitSeconds) == .timedOut { Log.write("uninstall: ack not sent within 5 s") }
        if others.wait(timeout: begin + SelfUninstaller.otherAcksWaitSeconds) == .timedOut {
            Log.write("uninstall: acks to the other accounts not all sent within 2 s")
        }
    }

    /// Removes Recitbot completely for every account: the acks first (sendAcks), then MacUninstall (exits). Once only.
    private func removeAll(_ l: AccountLink, requestId: String?, why: String) {
        removingLock.lock()
        let first = !removingAll
        removingAll = true
        removingLock.unlock()
        if !first { return }
        if recorder.busy { Log.write("uninstall: recording abandoned") }
        sendAcks(l, requestId: requestId, all: true, left: 0)
        MacUninstall.run(cfg: cfg, why: why)
    }

    /// A revoked device (410 device_revoked): scope "account" removes only its account (the last one removes the
    /// install); scope "all" (or none: a server from before scopes) removes the install for every account.
    func revoked(_ l: AccountLink, scope: SelfUninstaller.Scope) {
        if removing { return }
        let why = "device revoked, scope " + (scope == .all ? "all" : "account")
        if SelfUninstaller.removesAll(scope, accountsRemaining: others(than: l)) { removeAll(l, requestId: nil, why: why); return }
        drop(l, why: why)
    }

    /// The verified "uninstall" command: uninstall_ack first, before anything is removed. Scope "account" with other
    /// accounts left: the ack says how many, then only the account that sent it goes (its socket closes, the others keep
    /// running). Scope "all" (or none), or the last account: removeAll (the helper's launchctl bootout ends any capture;
    /// the server already failed a recording in progress). parity: AgentRecorder.cs Agent.OnUninstall
    private func uninstall(_ id: String?, _ scope: SelfUninstaller.Scope, _ l: AccountLink) {
        DispatchQueue.global().async {
            if self.removing { return }
            let left = self.others(than: l)
            if SelfUninstaller.removesAll(scope, accountsRemaining: left) {
                self.removeAll(l, requestId: id ?? "", why: "command " + (id ?? ""))
                return
            }
            self.sendAcks(l, requestId: id ?? "", all: false, left: left)
            self.drop(l, why: "uninstall command " + (id ?? ""))
        }
    }

    // MARK: commands

    /// Sends the monitor/mic/camera/window inventory on one connection (on connect and when its server asks).
    func reportDevices(_ requestId: String, via l: AccountLink) {
        if !l.beginReport() { return }
        defer { l.endReport() }
        do {
            let inv = try catalog.inventory(requestId: requestId)
            l.sendText(inv.json)
            Log.write("devices reported: \(inv.monitors) monitors, \(inv.mics) mics, \(inv.cameras) cameras, \(inv.windows) windows")
            // Probed here (on connect and on a device request) so a start command never waits for it.
            if !recorder.busy { capture.warm(pinnedEncoder: cfg.encoder) }
        } catch {
            Log.write("device inventory failed: " + Agent.message(error))
        }
    }

    /// A connection is up: the saved start of its account (if any) goes now.
    func connected(_ l: AccountLink) {
        DispatchQueue.global().async { self.updateHealth(l) }
        resumeLock.lock()
        let mine = resumeAfterConnect.map { owners.owns($0.recordingId, account: l.account.accountId) } ?? false
        resumeLock.unlock()
        // Connected first, so the "recording" status (and a stop) can reach the Worker.
        if mine { DispatchQueue.global().async { self.resume() } }
    }

    /// A connection is up and its hello went out: the installer's health marker (once per run) and, after a rollback, the
    /// "rolled_back" report on this account (once per account; the record goes after the first one is sent).
    /// parity: AgentRecorder.cs Agent.Connected
    private func updateHealth(_ l: AccountLink) {
        if !l.isConnected { return } // the hello did not get out: the next connect tries again
        healthLock.lock()
        let mark = !healthWritten
        healthWritten = true
        let report = rolledBack != nil && rolledBackSent.insert(l.account.accountId).inserted
        healthLock.unlock()
        if mark { UpdateHealth.writeMarker(dir: dir, version: Program.version) }
        guard report, let v = rolledBack else { return }
        l.sendText(UpdateHealth.rolledBackJson(v))
        Log.write("update to " + v + ": rolled_back reported (account " + l.account.accountId + ")")
        UpdateHealth.clear(dir: dir)
    }

    /// After a recording is uploaded (Recorder.onFinished): the held update, if any. parity: AgentRecorder.cs Agent
    /// (recorder.Finished)
    private func afterRecording() {
        SelfUpdater.runDeferred(busy: { self.recorder.busy }, held: SelfUpdater.deferred, now: Agent.unixNow()) { p in
            try SelfUpdater.install(cfg: self.cfg, server: p.server, sha256: p.sha256, url: p.url, env: MacUpdate.environment())
        }
    }

    /// One verified frame from l: it is handled for l's account only.
    func handle(_ text: String, from l: AccountLink) {
        let received = Clock.now()
        let f: JsonFields
        do { f = try Json.parseFlat(text) } catch { Log.write("ignored malformed frame"); return }
        // An uninstall with an unknown scope is rejected like a bad command (nothing removed).
        let reason = l.verifier.verify(f, Agent.unixNow()) ?? SelfUninstaller.scopeRejection(f)
        let uninstalling = SelfUninstaller.commanded(reason, f)
        if let reason = reason { Log.write("rejected command: " + reason); return }
        let type = f["type"] ?? nil, id = f["recording_id"] ?? nil
        let acct = l.account.accountId
        Log.write("command " + (type ?? "") + " " + (id ?? ""))
        if uninstalling, let scope = SelfUninstaller.scope(f) { uninstall(id, scope, l); return }
        switch type ?? "" {
        case "start":
            let waiting = owners.owner(screen.waitingId)
            if !owners.claim(id, account: acct) || RecordingOwners.busy(recording: recorder.busy, waitingFor: waiting, account: acct) {
                Log.write("start " + (id ?? "") + " refused: another recording is in progress on this computer")
                l.sendStatus(id, "failed", "BUSY")
                return
            }
            if !MacCatalog.screenAllowed() && !recorder.busy {
                let p = PendingStart(recordingId: id ?? "", frame: text, savedAt: Agent.unixNow())
                DispatchQueue.global().async { self.wait(p, f, prompt: true) }
                return
            }
            start(f, received)
        case "stop":
            // Another account's recording is not this connection's: the same silence as "not recording".
            if !owners.owns(id, account: acct) { return }
            if screen.cancel(id) { return }
            recorder.stop(id: id)
        case "devices":
            DispatchQueue.global().async { self.reportDevices(id ?? "", via: l) }
        case "ready":
            onReady(id, Fields.opt(f, "url"), l)
        case "update":
            let busy = recorder.busy
            let version = Fields.opt(f, "version"), sha = Fields.opt(f, "sha256"), url = Fields.opt(f, "url")
            let exp = Int64(Fields.opt(f, "exp") ?? "") ?? 0 // verified above
            DispatchQueue.global().async {
                SelfUpdater.run(cfg: self.cfg, server: l.account.server, busy: busy, version: version, sha256: sha, url: url, exp: exp,
                                env: MacUpdate.environment()) { l.sendText($0) }
            }
        default:
            break
        }
    }

    /// The start the previous copy saved, now that its account's socket is up (once; a reconnect finds nothing left).
    private func resume() {
        resumeLock.lock()
        let saved = resumeTaken ? nil : resumeAfterConnect
        resumeTaken = true
        resumeLock.unlock()
        guard let p = saved else { return }
        if p.fresh(Agent.unixNow()) {
            Log.write("screen: resuming start " + p.recordingId + " after relaunch")
            startSaved(p, prompt: false)
        } else {
            Log.write("screen: saved start " + p.recordingId + " expired before reconnecting")
            sendStatus(p.recordingId, "failed", ScreenOnboarding.deniedError)
        }
        resumeLock.lock(); resumeAfterConnect = nil; resumeLock.unlock()
    }

    private func start(_ f: JsonFields, _ received: Double) {
        let max = NetParse.int32(f["max_seconds"] ?? nil) ?? 0
        let o = StartOpts.from(f, configWebcam: cfg.webcam)
        recorder.start(id: f["recording_id"] ?? nil, maxSeconds: max, opts: o, uploadToken: f["upload_token"] ?? nil, received: received)
    }

    /// A saved start (verified when it arrived; its nonce is spent, so it is not verified again): records when this
    /// process sees Screen Recording, else waits again (prompt false: macOS was already asked for this one).
    func startSaved(_ p: PendingStart, prompt: Bool) {
        guard let f = try? Json.parseFlat(p.frame) else { Log.write("screen: saved start unreadable; dropped"); return }
        if !MacCatalog.screenAllowed() { wait(p, f, prompt: prompt); return }
        start(f, Clock.now())
    }

    /// No Screen Recording yet: the start waits (ScreenWait) with the pill on the monitor it asked for.
    private func wait(_ p: PendingStart, _ f: JsonFields, prompt: Bool) {
        let monitors = mac.monitors()
        let o = StartOpts.from(f, configWebcam: cfg.webcam)
        let m = DeviceMatch.monitor(monitors, o.monitor) ?? DeviceMatch.monitor(monitors, "primary")
        screen.begin(p, monitor: m, monitors: monitors, cfg: cfg, prompt: prompt)
    }

    /// The Worker's signed "ready" frame: open the owner's share link once, if this Mac uploaded that recording for this
    /// connection's account, the link passes LinkPolicy and auto_open_link is on. The URL is never written to the log
    /// (it is a bearer link).
    func onReady(_ id: String?, _ url: String?, _ l: AccountLink) {
        let shown = id ?? ""
        if !owners.owns(id, account: l.account.accountId) || !links.claim(id, Date()) {
            Log.write("ready " + shown + ": not waiting for it here (or already handled); nothing opened"); return
        }
        if !linkOpener.allowed(url: url, server: l.account.server, recordingId: id) {
            Log.write("ready " + shown + ": link rejected (not our viewer on an allowed host)"); return
        }
        if !cfg.readBool("auto_open_link", true) { Log.write("ready " + shown + ": auto_open_link is off; not opening"); return }
        linkOpener.open(url ?? "")
    }

    /// Uploads with the server of the account that started the recording (and that recording's upload token).
    func deliver(id: String, video: String, audio: String, hasTranscript: Bool, hasSystemAudio: Bool, token: String?, duration: Double, partBytes: Int64) throws {
        guard let l = link(owners.owner(id)) else { throw PendingError("UPLOAD_FAILED: the account of this recording is no longer paired here") }
        // Expected before the upload completes: the ready frame can arrive before /complete's response does.
        links.expect(id, Date())
        do {
            try uploader.upload(server: l.account.server, id: id, video: video, audio: audio, hasTranscript: hasTranscript, hasSystemAudio: hasSystemAudio,
                                token: token, duration: duration, partBytes: partBytes)
        } catch {
            links.forget(id)
            throw error
        }
        // Only after the MP4 is up; never fails the recording (Stills.run does not throw; docs/keyframes.md).
        let server = l.account.server, up = uploader
        Log.write(Stills.run(probe: MacStills.probe, grab: MacStills.grab,
                             put: { path, jpg in try up.putStill(server: server, id: id, token: token, path: path, jpg: jpg) },
                             video: video, fallbackSeconds: duration, dir: (video as NSString).deletingLastPathComponent, id: id))
    }

    /// A recording's status goes to the account that started it (dropped when that account is not connected).
    func sendStatus(_ id: String?, _ status: String, _ error: String?) {
        link(owners.owner(id))?.sendStatus(id, status, error)
    }

    static func message(_ e: Error) -> String {
        if let p = e as? PendingError { return p.description }
        if let s = e as? SocketError { return s.message }
        if let c = e as? CaptureError { return c.description }
        if let u = e as? UploadError { return u.description }
        return Config.message(e)
    }
}

/// One account's device connection: its own socket, send queue, reconnect backoff, ping and command key (verifier and
/// nonce file). Ends for good with stop() (account removed, revoked, or paired again).
final class AccountLink: @unchecked Sendable {
    let account: Account
    unowned let agent: Agent
    let verifier: CommandVerifier
    /// One frame at a time on the socket (C# sendLock).
    private let sendQueue = DispatchQueue(label: "com.recitbot.agent.send")
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var reporting = false

    init(agent: Agent, account: Account) {
        self.agent = agent
        self.account = account
        verifier = CommandVerifier(accountId: account.accountId, deviceId: account.deviceId, secret: account.deviceSecret,
                                   noncePath: Config.noncePath(agent.dir, deviceId: account.deviceId))
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func start() {
        let t = Task.detached { await self.run() }
        lock.lock(); task = t; lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = socket, t = task
        lock.unlock()
        t?.cancel()
        s?.cancel(with: .goingAway, reason: nil)
    }

    func beginReport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reporting { return false }
        reporting = true
        return true
    }

    func endReport() { lock.lock(); reporting = false; lock.unlock() }

    private func run() async {
        var backoff = Agent.backoffStart
        while !isStopped {
            var connected = false
            do {
                let (session, task) = try await WebSocketConnection.connect(server: account.server, token: account.deviceToken)
                connected = true
                backoff = Agent.backoffStart
                defer {
                    setSocket(nil)
                    task.cancel(with: .goingAway, reason: nil)
                    session.invalidateAndCancel()
                }
                if !setSocket(task) { return }
                Log.write("connected (account " + account.accountId + ")")
                let pinger = Task { await self.pingLoop() }
                defer { pinger.cancel() }
                await sendTextAsync(Program.helloJson())
                DispatchQueue.global().async { self.agent.reportDevices("", via: self) }
                agent.connected(self)
                try await receiveLoop(task)
            } catch {
                if isStopped { return }
                Log.write("connection error (account " + account.accountId + "): " + WebSocketConnection.describe(error))
                if !connected, let scope = await revoked(error) { agent.revoked(self, scope: scope); return }
            }
            if isStopped { return }
            if connected { Log.write("disconnected (account " + account.accountId + ")") }
            let wait = UInt64(backoff + Int.random(in: 0...2))
            do { try await Task.sleep(nanoseconds: wait * 1_000_000_000) } catch { return }
            backoff = min(backoff * 2, Agent.backoffMax)
        }
    }

    /// A refused handshake means "revoked" only for 410 plus a confirming probe that says device_revoked
    /// (URLSessionWebSocketTask does not hand over the refused upgrade's body); the probe's body also carries the scope.
    /// nil (not revoked) for every other failure. parity: AgentRecorder.cs AccountLink.Revoked
    private func revoked(_ error: Error) async -> SelfUninstaller.Scope? {
        guard let s = error as? SocketError, s.status == 410 else { return nil }
        let server = account.server, token = account.deviceToken
        let probe = await withCheckedContinuation { (c: CheckedContinuation<SelfUninstaller.Scope?, Never>) in
            DispatchQueue.global().async { c.resume(returning: RevocationProbe.check(server: server, token: token)) }
        }
        let said = probe.map { "says device_revoked, scope " + ($0 == .all ? "all" : "account") }
        Log.write("handshake: 410; probe " + (said ?? "does not confirm a revocation; reconnecting as usual"))
        return probe
    }

    /// Whether this account's socket is up now.
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && socket?.state == .running
    }

    /// false when the link was stopped meanwhile (the socket is not kept).
    @discardableResult
    private func setSocket(_ t: URLSessionWebSocketTask?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if t != nil && stopped { return false }
        socket = t
        return true
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: Agent.pingSeconds * 1_000_000_000) } catch { return }
            if Task.isCancelled { return }
            await sendTextAsync("ping")
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async throws {
        while task.state == .running && !isStopped {
            let m: URLSessionWebSocketTask.Message
            do { m = try await task.receive() } catch {
                if task.closeCode != .invalid || isStopped { return } // the server closed the socket (C#: a Close message)
                throw error
            }
            let text: String
            switch m {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            if text.utf8.count > Agent.maxFrameBytes { continue }
            if text == "pong" { continue }
            agent.handle(text, from: self)
        }
    }

    func sendStatus(_ id: String?, _ status: String, _ error: String?) {
        sendText(Frames.status(id, status, error))
    }

    /// Sends one text frame and waits for it (at most 15 s, like SendText(s).Wait(15000)). Dropped when not connected.
    func sendText(_ s: String) {
        let done = DispatchSemaphore(value: 0)
        sendQueue.async { self.sendNow(s); done.signal() }
        _ = done.wait(timeout: .now() + 15)
    }

    func sendTextAsync(_ s: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sendQueue.async { self.sendNow(s); c.resume() }
        }
    }

    /// On sendQueue only.
    private func sendNow(_ s: String) {
        lock.lock()
        let w = socket
        lock.unlock()
        guard let task = w, task.state == .running else { return }
        let sent = DispatchSemaphore(value: 0)
        task.send(.string(s)) { e in
            if let e = e { Log.write("send failed: " + Agent.message(e)) }
            sent.signal()
        }
        _ = sent.wait(timeout: .now() + 60)
    }
}
