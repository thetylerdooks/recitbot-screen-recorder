import Foundation

/// Multi-account (0.6.0, hello "multi_account"): the v1 -> v2 config.dat migration of a file exactly as 0.5.3 wrote it,
/// adding and refreshing accounts, the enroll token rule, per-account command routing and the machine-wide busy rule,
/// the uninstall scope and its ack, removing one account (uninstall or revocation) vs the last one, the agent's account
/// diff and the installer's add-account decision. Same case names as AgentRecorder.cs MultiAccountSelfTest.
enum SelfTestAccounts {
    static let acctA = "AAAAAAAAAAAAAAAAAAAAAA", devA = "DAAAAAAAAAAAAAAAAAAAAA"
    static let acctB = "BBBBBBBBBBBBBBBBBBBBBB", devB = "DBBBBBBBBBBBBBBBBBBBBB"
    static let tokenA = "ardt_DAAAAAAAAAAAAAAAAAAAAA_tokenAtokenAtokenAtokenAtokenAtokenA"
    static let tokenB = "ardt_DBBBBBBBBBBBBBBBBBBBBB_tokenBtokenBtokenBtokenBtokenBtokenB"

    static func accounts(_ t: SelfTest) {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("config.dat")
        let a = Account(server: "https://recitbot.com", accountId: acctA, deviceId: devA, deviceToken: tokenA, deviceSecret: "secret-A")
        let b = Account(server: "https://recitbot.com", accountId: acctB, deviceId: devB, deviceToken: tokenB, deviceSecret: "secret-B")
        do {
            try DataDir.create(dir)
            // config.dat exactly as 0.5.3 writes it (Config.save, then setPrefs from the pill and --set), plus its nonce.txt.
            let v1 = [
                "server=https://recitbot.com", "account_id=" + acctA, "device_id=" + devA, "ffmpeg=", "encoder=", "fps=30",
                "device_token=" + Config.protect(tokenA), "device_secret=" + Config.protect("secret-A"),
                "webcam=1", "camera=FaceTime HD Camera", "webcam_px=360", "mirror=0", "webcam_shape=rect", "auto_open_link=false",
                "pill_at_mon_f7b81f0c95=12,-3",
            ]
            try SecureFile.write(path, v1.map { $0 + "\n" }.joined())
            try SecureFile.write((dir as NSString).appendingPathComponent("nonce.txt"), "1731650000000")
            let m = try Config.load(dir)
            t.check("accounts: v1 config.dat (0.5.3) loads as one account, same ids, token and secret", m?.accounts == [a], "\(m?.accounts ?? [])")
            t.check("accounts: v1 machine-wide settings kept", m?.webcam == true && m?.camera == "FaceTime HD Camera" && m?.webcamPx == 360
                    && m?.mirror == false && m?.shape == "rect" && m?.pillAt["mon_f7b81f0c95"] == IPoint(12, -3)
                    && m?.readBool("auto_open_link", true) == false)
            let text = try SecureFile.readText(path)
            let lines = SecureFile.lines(text)
            t.check("accounts: v1 written back as v2 (version line first, no top-level account keys, secrets protected)",
                    lines.first == Config.versionLine && !lines.contains { Config.accountKeys.contains(Config.key($0)) }
                    && lines.contains("account.0.account_id=" + acctA) && lines.contains("account.0.device_id=" + devA)
                    && !text.contains(tokenA) && !text.contains("secret-A") && SelfTestCases.mode(path) == 0o600, text)
            t.check("accounts: v1 nonce.txt moves to the account's nonce file",
                    !SecureFile.exists((dir as NSString).appendingPathComponent("nonce.txt"))
                    && (try? SecureFile.readText(Config.noncePath(dir, deviceId: devA))) == "1731650000000")
            let again = try Config.load(dir)
            t.check("accounts: v2 re-load gives the same account and settings, file unchanged",
                    again?.accounts == [a] && again?.camera == "FaceTime HD Camera" && (try? SecureFile.readText(path)) == text)
            let nv = CommandVerifier(accountId: acctA, deviceId: devA, secret: "secret-A", noncePath: Config.noncePath(dir, deviceId: devA))
            var old: JsonFields = ["type": "stop", "recording_id": "R1R1R1R1R1R1", "nonce": "1731650000000", "exp": "1731650060",
                                   "account_id": acctA, "device_id": devA]
            old["mac"] = CommandVerifier.hmacHex("secret-A", CommandVerifier.canonical(old))
            t.equal("accounts: migrated account still refuses a replay of its last nonce", nv.verify(old, 1731650000), "replayed nonce")

            // Adding a second account keeps the migrated one; pairing it again refreshes only its own entry.
            t.check("accounts: add account (pairing code of another account)", try Config.upsertAccount(dir, b) == .added)
            let two = try Config.load(dir)
            t.check("accounts: add account keeps the migrated entry first and unchanged", two?.accounts == [a, b]
                    && two?.camera == "FaceTime HD Camera" && two?.readBool("auto_open_link", true) == false)
            var b2 = b
            b2.deviceToken = "ardt_DBBBBBBBBBBBBBBBBBBBBB_newtokennewtokennewtokennewtokennewtok"
            b2.deviceSecret = "secret-B2"
            t.check("accounts: refresh account (same account paired again)", try Config.upsertAccount(dir, b2) == .refreshed)
            t.check("accounts: refresh replaces only that entry", (try Config.load(dir))?.accounts == [a, b2])

            // The enroll token rule: only the token of the account the installer names.
            let held = [a, b2]
            t.check("accounts: enroll sends the token of the named account only",
                    Config.enrollToken(held, account: acctA) == tokenA && Config.enrollToken(held, account: acctB) == b2.deviceToken)
            t.check("accounts: enroll without --account, or for an account not paired here, sends no token",
                    Config.enrollToken(held, account: nil) == nil && Config.enrollToken(held, account: "") == nil
                    && Config.enrollToken(held, account: "CCCCCCCCCCCCCCCCCCCCCC") == nil && Config.enrollToken([], account: acctA) == nil)
            let body = Frames.enrollBody(code: "ABCDEFGHIJ12", name: "Mac", deviceToken: Config.enrollToken(held, account: acctA))
            t.check("accounts: enroll body for account A never carries account B's token", body.contains(tokenA) && !body.contains(b2.deviceToken))

            // Secrets that do not decode here skip only their entry.
            var withBad = SecureFile.lines(try SecureFile.readText(path))
            if let bt = withBad.firstIndex(where: { $0.hasPrefix("account.1.device_token=") }) { withBad[bt] = "account.1.device_token=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA" }
            try SecureFile.write(path, Config.joinLines(withBad))
            t.check("accounts: an account whose DPAPI blob does not decrypt is skipped, the others load", (try Config.load(dir))?.accounts == [a])
            t.check("accounts: pairing again replaces the unreadable entry", try Config.upsertAccount(dir, b2) == .added
                    && (try Config.load(dir))?.accounts == [a, b2])

            // Removing one account (scoped uninstall or a revoked device) keeps the others.
            try SecureFile.write(Config.noncePath(dir, deviceId: devB), "5")
            t.check("accounts: remove of another device of the account changes nothing",
                    try Config.removeAccount(dir, accountId: acctB, deviceId: devA) == [a, b2])
            t.check("accounts: remove one account keeps the other", try Config.removeAccount(dir, accountId: acctB, deviceId: devB) == [a]
                    && (try Config.load(dir))?.accounts == [a] && !SecureFile.exists(Config.noncePath(dir, deviceId: devB))
                    && (try Config.load(dir))?.camera == "FaceTime HD Camera")
            t.check("accounts: removing the last account leaves no account", try Config.removeAccount(dir, accountId: acctA, deviceId: devA) == []
                    && (try Config.load(dir))?.accounts == [])
            t.check("accounts: config.lock is the user's only", SelfTestCases.mode((dir as NSString).appendingPathComponent("config.lock")) == 0o600)
        } catch {
            t.check("accounts: v1 config.dat (0.5.3) loads as one account, same ids, token and secret", false, Config.message(error))
        }

        // Routing: every recording belongs to the account that started it.
        let o = RecordingOwners()
        t.check("accounts: per-account routing (a recording's owner is the account that started it)",
                o.claim("RECA00000001", account: acctA) && o.claim("RECB00000001", account: acctB)
                && o.owner("RECA00000001") == acctA && o.owner("RECB00000001") == acctB && o.owner("RECX00000001") == nil)
        t.check("accounts: another account cannot claim, stop or see a recording", !o.claim("RECA00000001", account: acctB)
                && !o.owns("RECA00000001", account: acctB) && o.owns("RECA00000001", account: acctA) && o.owner("RECA00000001") == acctA)
        for i in 0..<70 { _ = o.claim("RECZ" + String(format: "%08d", i), account: acctB) }
        t.check("accounts: only the recent recordings are remembered", o.owner("RECA00000001") == nil && o.owner("RECZ00000069") == acctB)
        t.check("accounts: machine-wide busy (a recording of any account refuses every start)",
                RecordingOwners.busy(recording: true, waitingFor: nil, account: acctA) && RecordingOwners.busy(recording: true, waitingFor: nil, account: acctB))
        t.check("accounts: a start waiting for Screen Recording blocks other accounts, not its own",
                RecordingOwners.busy(recording: false, waitingFor: acctA, account: acctB) && !RecordingOwners.busy(recording: false, waitingFor: acctA, account: acctA)
                && !RecordingOwners.busy(recording: false, waitingFor: nil, account: acctB))
        var startA: JsonFields = ["type": "start", "recording_id": "RECA00000004", "max_seconds": "30", "mic": "false", "nonce": "1731650000000",
                                  "exp": "1731650060", "account_id": acctA, "device_id": devA, "upload_token": "1731651800.tok"]
        startA["mac"] = CommandVerifier.hmacHex("secret-A", CommandVerifier.canonical(startA))
        t.check("accounts: a command signed for one account is refused on another account's connection",
                CommandVerifier(accountId: acctB, deviceId: devB, secret: "secret-B", noncePath: nil).verify(startA, 1731650000) == "bad mac"
                && CommandVerifier(accountId: acctA, deviceId: devA, secret: "secret-A", noncePath: nil).verify(startA, 1731650000) == nil)
        t.check("accounts: a start with another account's recording id is refused", !o.claim("RECZ00000069", account: acctA))
        t.equal("accounts: busy answer is the existing BUSY status", Frames.status("RECB00000002", "failed", "BUSY"),
                "{\"type\":\"status\",\"recording_id\":\"RECB00000002\",\"status\":\"failed\",\"error\":\"BUSY\"}")

        // The uninstall scope (signed) and the ack.
        var un: JsonFields = ["type": "uninstall", "recording_id": "Unin5tall01", "nonce": "1731650000000", "exp": "1731650060",
                              "account_id": SelfTestCases.acct, "device_id": SelfTestCases.dev]
        t.check("accounts: uninstall without scope = all (a server from before scopes: full removal)",
                SelfUninstaller.scope(un) == .all && SelfUninstaller.scopeRejection(un) == nil)
        un["scope"] = "account"
        t.equal("accounts: scope is a signed block", CommandVerifier.canonical(un),
                "v1|uninstall|Unin5tall01||0|1731650000000|1731650060|" + SelfTestCases.acct + "|" + SelfTestCases.dev + "||scope|account")
        t.check("accounts: scope account = only this account", SelfUninstaller.scope(un) == .account && SelfUninstaller.scopeRejection(un) == nil)
        un["scope"] = "all"
        un["mac"] = SelfTestCases.mac(un)
        t.check("accounts: signed scope all verifies", SelfTestCases.verifier().verify(un, 1731650000) == nil && SelfUninstaller.scope(un) == .all)
        var forged = un
        forged["scope"] = "account"
        t.equal("accounts: scope changed in transit rejected", SelfTestCases.verifier().verify(forged, 1731650000), "bad mac")
        var odd = un
        odd["scope"] = "device"
        odd["mac"] = SelfTestCases.mac(odd)
        let oddReason = SelfTestCases.verifier().verify(odd, 1731650000) ?? SelfUninstaller.scopeRejection(odd)
        t.check("accounts: unknown scope (signed) rejected as an invalid command, nothing removed", SelfUninstaller.scope(odd) == nil
                && oddReason == "unknown uninstall scope" && !SelfUninstaller.commanded(oddReason, odd), oddReason ?? "nil")
        var nul = un
        nul["scope"] = .some(nil)
        let empty: JsonFields = ["type": "uninstall", "scope": ""]
        let startScope: JsonFields = ["type": "start", "scope": "device"]
        t.check("accounts: null or empty scope rejected; the scope check is for uninstall commands only", SelfUninstaller.scope(nul) == nil
                && SelfUninstaller.scopeRejection(nul) != nil && SelfUninstaller.scopeRejection(empty) != nil && SelfUninstaller.scopeRejection(startScope) == nil)
        t.check("accounts: scoped uninstall removes one account while others remain",
                !SelfUninstaller.removesAll(.account, accountsRemaining: 1) && !SelfUninstaller.removesAll(.account, accountsRemaining: 3))
        t.check("accounts: last account (or scope all) = full removal", SelfUninstaller.removesAll(.account, accountsRemaining: 0)
                && SelfUninstaller.removesAll(.all, accountsRemaining: 2))
        t.equal("accounts: ack carries accounts_remaining", SelfUninstaller.ackJson("Unin5tall01", accountsRemaining: 1),
                "{\"type\":\"uninstall_ack\",\"request_id\":\"Unin5tall01\",\"accounts_remaining\":1}")
        let ackf = (try? Json.parseFlat(SelfUninstaller.ackJson("Unin5tall01", accountsRemaining: 0))) ?? JsonFields()
        t.check("accounts: full-removal ack says 0 accounts remaining", Fields.opt(ackf, "accounts_remaining") == "0"
                && Fields.opt(ackf, "type") == "uninstall_ack")
        let bare = "{\"type\":\"uninstall_ack\",\"accounts_remaining\":0}"
        t.equal("accounts: full-removal ack on the other sockets has no request_id", SelfUninstaller.ackJson(nil, accountsRemaining: 0), bare)
        t.check("accounts: revoke of one account keeps the rest (last one = full removal)",
                !SelfUninstaller.removesAll(.account, accountsRemaining: 1) && SelfUninstaller.removesAll(.account, accountsRemaining: 0))

        // Which sockets get an ack: the commanding one always; for a full removal also every other connected account.
        let acctC = "EEEEEEEEEEEEEEEEEEEEEE"
        let ridAck = SelfUninstaller.ackJson("Unin5tall01", accountsRemaining: 0)
        t.equal("accounts: scope all acks the command, then request_id-less acks on every other connected socket",
                SelfUninstaller.acks(account: acctA, requestId: "Unin5tall01", all: true, accountsRemaining: 2, connected: [acctB, acctA, acctC]),
                [SelfUninstaller.Ack(account: acctA, frame: ridAck), SelfUninstaller.Ack(account: acctB, frame: bare), SelfUninstaller.Ack(account: acctC, frame: bare)])
        t.equal("accounts: scope account with accounts left acks the commanding socket only (no acks on the others)",
                SelfUninstaller.acks(account: acctA, requestId: "Unin5tall01", all: false, accountsRemaining: 2, connected: [acctA, acctB, acctC]),
                [SelfUninstaller.Ack(account: acctA, frame: SelfUninstaller.ackJson("Unin5tall01", accountsRemaining: 2))])
        t.equal("accounts: full removal: accounts whose sockets are not connected get nothing",
                SelfUninstaller.acks(account: acctA, requestId: "Unin5tall01", all: true, accountsRemaining: 0, connected: [acctA]),
                [SelfUninstaller.Ack(account: acctA, frame: ridAck)])
        t.equal("accounts: 410 full removal sends request_id-less acks on the other connected sockets only",
                SelfUninstaller.acks(account: acctB, requestId: nil, all: true, accountsRemaining: 0, connected: [acctA, acctC]),
                [SelfUninstaller.Ack(account: acctA, frame: bare), SelfUninstaller.Ack(account: acctC, frame: bare)])
        t.equal("accounts: 410 for one account (others left) sends no ack",
                SelfUninstaller.acks(account: acctB, requestId: nil, all: false, accountsRemaining: 1, connected: [acctA, acctC]), [SelfUninstaller.Ack]())

        // 410 device_revoked: its scope says what goes.
        let r410 = { (body: String) in Revocation.revokedScope(410, body) }
        t.check("accounts: 410 scope account removes only that account (others left)",
                r410("{\"error\":\"device_revoked\",\"scope\":\"account\"}") == .account && !SelfUninstaller.removesAll(.account, accountsRemaining: 1))
        t.check("accounts: 410 scope account for the last account = full removal",
                SelfUninstaller.removesAll(r410("{\"error\":\"device_revoked\",\"scope\":\"account\"}") ?? .all, accountsRemaining: 0))
        t.check("accounts: 410 scope all removes everything", r410("{\"error\":\"device_revoked\",\"scope\":\"all\"}") == .all
                && SelfUninstaller.removesAll(.all, accountsRemaining: 2))
        t.check("accounts: 410 without scope (a server from before scopes) removes everything",
                r410("{\"error\":\"device_revoked\"}") == .all && r410("{\"error\":\"device_revoked\",\"scope\":null}") == .all)
        t.check("accounts: 410 with an unknown scope removes only that account",
                r410("{\"error\":\"device_revoked\",\"scope\":\"device\"}") == .account)
        t.check("accounts: 410 scope parsing needs device_revoked", r410("{\"error\":\"gone\",\"scope\":\"all\"}") == nil
                && Revocation.revokedScope(401, "{\"error\":\"device_revoked\",\"scope\":\"all\"}") == nil)

        // Cross-check with the Worker: the frame exactly as DeviceHub.signAndSend serializes it, and the string
        // worker/src/device-hub.ts canonicalCommand builds for those fields (literals read off that function).
        let wire = "{\"type\":\"uninstall\",\"recording_id\":\"Un1nstallRq\",\"max_seconds\":0,\"mic\":false,\"nonce\":1731650000000,"
            + "\"exp\":1731650060,\"account_id\":\"" + SelfTestCases.acct + "\",\"device_id\":\"" + SelfTestCases.dev + "\",\"upload_token\":\"\""
        let workerAccount = "v1|uninstall|Un1nstallRq|0|0|1731650000000|1731650060|BBBBBBBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCCCCCCC||scope|account"
        let workerNone = "v1|uninstall|Un1nstallRq|0|0|1731650000000|1731650060|BBBBBBBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCCCCCCC|"
        for (name, json, want, scope) in [("scope account", wire + ",\"scope\":\"account\"}", workerAccount, SelfUninstaller.Scope.account),
                                          ("no scope", wire + "}", workerNone, SelfUninstaller.Scope.all)] {
            var wf = (try? Json.parseFlat(json)) ?? JsonFields()
            t.equal("accounts: canonical uninstall (" + name + ") = worker canonicalCommand", CommandVerifier.canonical(wf), want)
            wf["mac"] = CommandVerifier.hmacHex(SelfTestCases.key, want)
            let wr = SelfTestCases.verifier().verify(wf, 1731650000) ?? SelfUninstaller.scopeRejection(wf)
            t.check("accounts: uninstall (" + name + ") signed over the worker's string verifies", wr == nil && SelfUninstaller.commanded(wr, wf)
                    && SelfUninstaller.scope(wf) == scope, wr ?? "nil")
        }

        // The agent's connections follow config.dat.
        var b3 = b
        b3.deviceToken = "ardt_DBBBBBBBBBBBBBBBBBBBBB_othertokenothertokenothertokenothertoke"
        t.check("accounts: account added while running is connected", AccountSet.diff(running: [a], wanted: [a, b]) == AccountSet.Diff(start: [b], stop: []))
        t.check("accounts: removed account is disconnected", AccountSet.diff(running: [a, b], wanted: [a]) == AccountSet.Diff(start: [], stop: [acctB]))
        t.check("accounts: refreshed account reconnects with its new token",
                AccountSet.diff(running: [a, b], wanted: [a, b3]) == AccountSet.Diff(start: [b3], stop: [acctB]))
        t.check("accounts: unchanged list changes nothing", AccountSet.diff(running: [a, b], wanted: [b, a]) == AccountSet.Diff())
        t.check("accounts: saved start's account", AccountSet.account(ofFrame: "{\"type\":\"start\",\"account_id\":\"" + acctB + "\"}") == acctB
                && AccountSet.account(ofFrame: "nope") == nil)

        // install.sh: a code on a Mac with this version (or newer) installed only adds the account.
        t.check("accounts: installer adds the account to a same or newer app",
                InstallLayout.addAccountOnly(installed: "0.6.0", installer: "0.6.0", update: false)
                && InstallLayout.addAccountOnly(installed: "0.7.1", installer: "0.6.0", update: false))
        t.check("accounts: installer updates an older app in place (or installs when there is none)",
                !InstallLayout.addAccountOnly(installed: "0.5.3", installer: "0.6.0", update: false)
                && !InstallLayout.addAccountOnly(installed: nil, installer: "0.6.0", update: false)
                && !InstallLayout.addAccountOnly(installed: "garbage", installer: "0.6.0", update: false)
                && !InstallLayout.addAccountOnly(installed: "0.6.0", installer: "0.6.0", update: true))
    }
}
