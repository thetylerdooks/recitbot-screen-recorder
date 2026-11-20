import Foundation

/// Phase (a) selftests: canonical form + Worker HMAC vectors, Verify rejections, nonce replay and persistence, Json,
/// Config round-trip (secrets never plaintext), NormalizeSetting, HelloJson and the agent's frames.
/// Case names and vectors are copied from AgentRecorder.cs Program.SelfTest / AudioSelfTest / ChunkedSelfTest /
/// so both platforms prove the same thing (the update block is SelfTestUpdate, like SelfUpdateSelfTest).
enum SelfTestCases {
    static let key = "test-device-secret"
    static let acct = "BBBBBBBBBBBBBBBBBBBBBB", dev = "CCCCCCCCCCCCCCCCCCCCCC"

    /// The base start command of the C# selftest (`f`).
    static var base: JsonFields {
        return [
            "type": "start", "recording_id": "AAAAAAAAAAAAAAAAAAAAAA", "max_seconds": "30", "mic": "false",
            "nonce": "1731650000000", "exp": "1731650060", "account_id": acct,
            "device_id": dev, "upload_token": "1731651800.tok",
        ]
    }

    static func verifier(account: String = acct, secret: String = key, noncePath: String? = nil) -> CommandVerifier {
        return CommandVerifier(accountId: account, deviceId: dev, secret: secret, noncePath: noncePath)
    }

    static func mac(_ f: JsonFields) -> String { return CommandVerifier.hmacHex(key, CommandVerifier.canonical(f)) }

    static func commands(_ t: SelfTest) {
        var f = base
        let vector = "91b21b4b501c2352952e2591e8c7d738ae9d653f27672744673c47e824d1adfc"
        t.equal("canonical hmac matches worker vector", mac(f), vector)
        t.equal("canonical v1 form", CommandVerifier.canonical(f),
                "v1|start|AAAAAAAAAAAAAAAAAAAAAA|30|0|1731650000000|1731650060|BBBBBBBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCCCCCCC|1731651800.tok")
        f["mac"] = vector
        let v = verifier()
        t.check("valid command accepted", v.verify(f, 1731650000) == nil)
        t.equal("replayed command rejected", v.verify(f, 1731650000), "replayed nonce")
        let v2 = verifier()
        t.equal("expired command rejected", v2.verify(f, 1731650061), "expired")
        t.equal("other account rejected", verifier(account: "OTHERACCOUNTxxxxxxxxxx").verify(f, 1731650000), "wrong account")
        let v8 = CommandVerifier(accountId: acct, deviceId: "OTHERDEVICExxxxxxxxxxx", secret: key, noncePath: nil)
        t.equal("other device rejected", v8.verify(f, 1731650000), "wrong device")
        var forged = f
        forged["max_seconds"] = "120"
        t.equal("tampered command rejected", v2.verify(forged, 1731650000), "bad mac")
        t.equal("wrong key rejected", verifier(secret: "wrong-secret").verify(f, 1731650000), "bad mac")
        var noMac = f
        noMac.removeValue(forKey: "mac")
        t.equal("missing mac rejected", verifier().verify(noMac, 1731650000), "bad mac")
        var badExp = base
        badExp["exp"] = "soon"
        badExp["mac"] = mac(badExp)
        t.equal("unparseable exp rejected as expired", verifier().verify(badExp, 1731650000), "expired")
        t.check("hmac of empty key and message", CommandVerifier.hmacHex("", "")
                == "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad")

        // Nonce persistence: a new verifier over the same nonce.txt (the agent restarted) still rejects the replay.
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-" + UUID().uuidString)
        try? DataDir.create(dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let np = (dir as NSString).appendingPathComponent("nonce.txt")
        t.check("nonce: first use accepted and saved", verifier(noncePath: np).verify(f, 1731650000) == nil
                && (try? SecureFile.readText(np)) == "1731650000000")
        t.equal("nonce: replay after restart rejected", verifier(noncePath: np).verify(f, 1731650000), "replayed nonce")
        var next = f
        next["nonce"] = "1731650000001"
        next["mac"] = mac(next)
        t.check("nonce: next nonce after restart accepted", verifier(noncePath: np).verify(next, 1731650000) == nil)
        t.check("nonce.txt is 0600", mode(np) == 0o600)
    }

    static func blocks(_ t: SelfTest) {
        var f = base
        f["mac"] = "91b21b4b501c2352952e2591e8c7d738ae9d653f27672744673c47e824d1adfc"
        // Webcam block.
        var cam = f
        cam.removeValue(forKey: "mac")
        cam["webcam"] = "true"; cam["camera"] = "Full HD webcam"; cam["webcam_size"] = "large"
        t.equal("webcam canonical hmac matches worker vector", mac(cam), "21d8fbbc60cf22ee8ddb9d83b5cf0664f021b7e099c36cd17384af0974311809")
        var stripped = cam
        stripped["mac"] = mac(cam)
        stripped.removeValue(forKey: "webcam")
        t.equal("tampered webcam field rejected", verifier().verify(stripped, 1731650000), "bad mac")

        // Device parameters (monitor, mic_device) are signed in their own block, only when present.
        var dv = cam
        dv["monitor"] = "mon_0123456789"; dv["mic_device"] = "Microphone (HyperX Cloud Alpha Wireless)"
        t.check("device-param canonical form", CommandVerifier.canonical(dv)
                .hasSuffix("|cam|1|Full HD webcam|large|dev|mon_0123456789|Microphone (HyperX Cloud Alpha Wireless)"), CommandVerifier.canonical(dv))
        t.equal("device-param canonical hmac matches worker vector", mac(dv), "7973edc38381ad4e225e490d13e4cfd498e6ec3ebd84ed027f3c603aabbe2d73")
        var devOnly = f
        devOnly.removeValue(forKey: "mac")
        devOnly["monitor"] = "1"
        t.check("device block without webcam block", CommandVerifier.canonical(devOnly).hasSuffix("|1731651800.tok|dev|1|"), CommandVerifier.canonical(devOnly))
        dv["mac"] = mac(dv)
        let v6 = verifier()
        var swapped = dv
        swapped["monitor"] = "0"
        t.equal("tampered monitor rejected", v6.verify(swapped, 1731650000), "bad mac")
        var dropped = dv
        dropped.removeValue(forKey: "mic_device")
        t.equal("dropped mic_device rejected", v6.verify(dropped, 1731650000), "bad mac")
        t.check("signed device params accepted", v6.verify(dv, 1731650000) == nil)

        // Window block.
        var wf = f
        wf.removeValue(forKey: "mac")
        wf["webcam"] = "true"; wf["window"] = "win_0123456789"
        t.check("window canonical form", CommandVerifier.canonical(wf).hasSuffix("|1731651800.tok|cam|1|||win|win_0123456789"), CommandVerifier.canonical(wf))
        t.equal("window canonical hmac matches worker vector", mac(wf), "19642c756a0de3d60eb9372be9fd332f66affe9ec189c7d198d64e4f773770fa")
        wf["mac"] = mac(wf)
        let v7 = verifier()
        var otherWin = wf
        otherWin["window"] = "win_9999999999"
        var noWin = wf
        noWin.removeValue(forKey: "window")
        t.check("tampered / dropped window rejected", v7.verify(otherWin, 1731650000) == "bad mac" && v7.verify(noWin, 1731650000) == "bad mac")
        t.check("signed window accepted", v7.verify(wf, 1731650000) == nil)

        // 0.4 blocks: shared vectors with worker/test/audio-open.test.ts.
        var sa = f
        sa.removeValue(forKey: "mac")
        sa["webcam_size"] = "25"; sa["system_audio"] = "true"; sa["webcam_shape"] = "rect"
        t.check("0.4 canonical form", CommandVerifier.canonical(sa).hasSuffix("|1731651800.tok|cam|||25|sa|1|shape|rect"), CommandVerifier.canonical(sa))
        t.equal("0.4 canonical hmac matches worker vector", mac(sa), "8e45f1383fe538cc386058f75c74e978b26829b996f637d51f838e17eb8e3c05")
        sa["mac"] = mac(sa)
        let vs = verifier()
        var noSys = sa
        noSys["system_audio"] = "false"
        var dropSys = sa
        dropSys.removeValue(forKey: "system_audio")
        var square = sa
        square["webcam_shape"] = "circle"
        t.check("tampered / dropped system_audio or shape rejected", vs.verify(noSys, 1731650000) == "bad mac"
                && vs.verify(dropSys, 1731650000) == "bad mac" && vs.verify(square, 1731650000) == "bad mac")
        t.check("signed 0.4 start accepted", vs.verify(sa, 1731650000) == nil)
        var ready: JsonFields = [
            "type": "ready", "recording_id": "AAAAAAAAAAAAAAAAAAAAAA", "max_seconds": "0", "mic": "false",
            "nonce": "1731650000000", "exp": "1731650060", "account_id": acct,
            "device_id": dev, "upload_token": "",
            "url": "https://recitbot.com/v/AAAAAAAAAAAAAAAAAAAAAA?e=1731736400&s=sig&o=own",
        ]
        t.equal("ready canonical hmac matches worker vector", mac(ready), "5249a2d1308a0d5ab5e6ec4805c9ed1d2b2841e94585e0cccd2908f747f195bc")
        ready["mac"] = mac(ready)
        var swappedUrl = ready
        swappedUrl["url"] = "https://evil.example/v/AAAAAAAAAAAAAAAAAAAAAA?e=1731736400&s=sig&o=own"
        t.equal("ready with a swapped url rejected", verifier().verify(swappedUrl, 1731650000), "bad mac")

        // Chunked upload block.
        var mp = f
        mp.removeValue(forKey: "mac")
        mp["system_audio"] = "true"
        mp["upload_part_bytes"] = "33554432"
        t.check("mp canonical form", CommandVerifier.canonical(mp).hasSuffix("|1731651800.tok|sa|1|mp|33554432"), CommandVerifier.canonical(mp))
        t.equal("mp canonical hmac matches worker vector", mac(mp), "42de4f6cf95fd36b4eb8fdf59766dcabacb6091155c448a6b767f4477005a7a4")
        mp["mac"] = mac(mp)
        var mpStripped = mp
        mpStripped.removeValue(forKey: "upload_part_bytes")
        t.equal("mp: part size stripped -> rejected", verifier().verify(mpStripped, 1731650000), "bad mac")
        var changed = mp
        changed["upload_part_bytes"] = "1048576"
        t.equal("mp: part size changed -> rejected", verifier().verify(changed, 1731650000), "bad mac")
    }

    static func json(_ t: SelfTest) {
        let parsed = try? Json.parseFlat("{\"a\":\"x\\\"y\",\"b\":12,\"c\":true,\"d\":null}")
        t.check("json parse", parsed?["a"] == .some("x\"y") && parsed?["b"] == .some("12") && parsed?["c"] == .some("true")
                && parsed?["d"] == .some(nil) && parsed?.keys.contains("d") == true)
        let esc = try? Json.parseFlat(" { \"n\" : \"a\\nb\\tc\\u00e9\\ud83d\\ude00\\/\" }")
        t.check("json escapes (\\n \\t \\u, surrogate pair, \\/)", esc?["n"] == .some("a\nb\tc\u{e9}\u{1F600}/"))
        t.check("json empty object", (try? Json.parseFlat("{}"))?.isEmpty == true)
        func fails(_ s: String) -> Bool { return (try? Json.parseFlat(s)) == nil }
        t.check("json nested / truncated / garbage rejected", fails("{\"a\":{\"b\":1}}") && fails("{\"a\":[1]}") && fails("{\"a\":\"x")
                && fails("") && fails("ping") && fails("{\"a\":}") && fails("{\"a\":\"\\u12\"}"))
        t.equal("json esc", Json.esc("a\"b\\c\n\u{1}é"), "\"a\\\"b\\\\c\\u000a\\u0001é\"")
        t.equal("json esc null", Json.esc(nil), "\"\"")
        let round = try? Json.parseFlat("{\"k\":" + Json.esc("q\"\\\r\n\t\u{1f}x") + "}")
        t.check("json esc round-trips through parse", round?["k"] == .some("q\"\\\r\n\t\u{1f}x"))
    }

    static func config(_ t: SelfTest) {
        t.check("settings: auto_open_link values", Config.normalizeSetting("auto_open_link", "FALSE") == "false"
                && Config.normalizeSetting("auto_open_link", " on ") == "true" && Config.normalizeSetting("auto_open_link", "maybe") == nil
                && Config.normalizeSetting("device_token", "x") == nil && Config.normalizeSetting("server", "https://x") == nil)
        let none = Config(dir: (NSTemporaryDirectory() as NSString).appendingPathComponent("agent-recorder-none-" + UUID().uuidString))
        let logged = Log.pathName
        Log.pathName = nil // the "config read" line of the missing file goes nowhere
        t.check("settings: missing config file reads the default", none.readBool("auto_open_link", true))
        Log.pathName = logged

        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try DataDir.create(dir)
            let token = "dt_SECRETtoken.value+/=", secret = "0123456789abcdef-device-secret"
            let a = Account(server: "https://recitbot.com", accountId: acct, deviceId: dev, deviceToken: token, deviceSecret: secret)
            t.check("config: first enroll adds the account", try Config.upsertAccount(dir, a) == .added)
            let path = (dir as NSString).appendingPathComponent("config.dat")
            let text = try SecureFile.readText(path)
            t.check("config: secrets never in plaintext", !text.contains(token) && !text.contains(secret)
                    && text.contains("account.0.device_token=b64:") && text.contains("account.0.device_secret=b64:"))
            t.equal("config: file layout matches Windows", SecureFile.lines(text).map { String($0.prefix(while: { $0 != "=" })) },
                    ["config_version", "ffmpeg", "encoder", "fps", "webcam", "camera", "webcam_px", "mirror", "webcam_shape", "auto_open_link",
                     "account.0.server", "account.0.account_id", "account.0.device_id", "account.0.device_token", "account.0.device_secret"])
            t.check("config: config.dat 0600, data dir 0700", mode(path) == 0o600 && mode(dir) == 0o700)
            let l = try Config.load(dir)
            t.check("config: round-trip", l?.accounts == [a] && l?.fps == 30 && l?.webcam == false && l?.mirror == true
                    && l?.shape == "circle" && l?.webcamPx == 240 && l?.encoder == nil && l?.camera == nil && l?.videoPath == "auto")
            t.check("config: auto_open_link defaults to true", l?.readBool("auto_open_link", false) == true)

            let tokenLine = SecureFile.lines(text).first { $0.hasPrefix("account.0.device_token=") }
            l?.setPrefs("auto_open_link", "false", "popup_x", "-12", "device_token", "stolen", "account.0.device_token", "stolen",
                        "camera", "FaceTime\r\nHD")
            let after = try SecureFile.readText(path)
            let afterLines = SecureFile.lines(after)
            t.check("config: setPrefs keeps the secrets byte-for-byte and never writes them", tokenLine != nil
                    && afterLines.contains(tokenLine!) && !after.contains("stolen"))
            t.check("config: setPrefs updates in place and appends new keys", afterLines.contains("auto_open_link=false")
                    && afterLines.contains("popup_x=-12") && afterLines.contains("camera=FaceTimeHD") && afterLines.count == 16
                    && !SecureFile.exists(path + ".tmp") && mode(path) == 0o600)
            t.check("config: readBool sees --set values", l?.readBool("auto_open_link", true) == false)
            let l2 = try Config.load(dir)
            t.check("config: prefs load back", l2?.popupX == -12 && l2?.camera == "FaceTimeHD" && l2?.accounts.first?.deviceToken == token)

            try SecureFile.write(path, "server=x\r\nfps=240\r\nwebcam_px=9999\r\nwebcam_size=small\r\nvideo_path= GPU \r\nwebcam_shape=hex\r\n"
                                 + "mirror=false\r\nwebcam=true\r\nbubble_x=abc\r\nencoder=\r\n")
            let w = try Config.load(dir)
            t.check("config: Windows-style CRLF file, clamps and normalization", w?.accounts == [] && w?.fps == 60 && w?.webcamPx == 480
                    && w?.videoPath == "gpu" && w?.shape == "circle" && w?.mirror == false && w?.webcam == true && w?.bubbleX == nil && w?.encoder == nil)
            try SecureFile.write(path, "webcam_size=small\nfps=5\n")
            let legacy = try Config.load(dir)
            t.check("config: legacy webcam_size and fps floor", legacy?.webcamPx == 160 && legacy?.fps == 15)
            try SecureFile.write(path, "server=x\naccount_id=" + acct + "\ndevice_id=" + dev + "\ndevice_token=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA\n"
                                 + "device_secret=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA\n")
            let dp = try Config.load(dir)
            t.check("config: a DPAPI blob is unreadable here (account skipped, never read as plaintext)", dp != nil && dp?.accounts == []
                    && (try? SecureFile.readText(path))?.hasPrefix("server=x") == true)
            try? FileManager.default.removeItem(atPath: path)
            t.equal("config: not enrolled = nil", loadOutcome(dir), "nil")
        } catch {
            t.check("config: round-trip", false, Config.message(error))
        }
        t.check("webcam sizes", WebcamSize.pxForName("small") == 160 && WebcamSize.pxForName("medium") == 240 && WebcamSize.pxForName("large") == 360
                && WebcamSize.pxForName("huge") < 0 && WebcamSize.pxForName(nil) < 0)
        t.check("webcam px clamp", WebcamSize.clampPx(1000) == 480 && WebcamSize.clampPx(10) == 120 && WebcamSize.clampPx(300) == 300)
        t.check("video path: setting values", VideoPath.normalize(" GPU ") == "gpu" && VideoPath.normalize("cpu") == "cpu"
                && VideoPath.normalize("fast") == "auto" && VideoPath.normalize(nil) == "auto")
        t.check(".NET int parsing", NetParse.int32(" 25 ") == 25 && NetParse.int32("+7") == 7 && NetParse.int32("-3") == -3 && NetParse.int32("2.5") == nil
                && NetParse.int32("") == nil && NetParse.int32("99999999999") == nil && NetParse.int64("1731650000000") == 1731650000000
                && NetParse.int64("9223372036854775808") == nil && NetParse.int32("１") == nil)
    }

    static func protocolFrames(_ t: SelfTest) {
        t.equal("hello frame", Program.helloJson(),
                "{\"type\":\"hello\",\"version\":\"" + Program.version + "\",\"features\":[\"system_audio\",\"webcam_shape\",\"webcam_pct\",\"ready_push\",\"chunked_upload\",\"self_update\",\"self_uninstall\",\"multi_account\",\"update_defer_rollback\",\"keyframes\"]}")
        t.equal("status frame", Frames.status("AAAAAAAAAAAAAAAAAAAAAA", "failed", "BUSY"),
                "{\"type\":\"status\",\"recording_id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"status\":\"failed\",\"error\":\"BUSY\"}")
        t.equal("status frame without error", Frames.status("AAAAAAAAAAAAAAAAAAAAAA", "recording", nil),
                "{\"type\":\"status\",\"recording_id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"status\":\"recording\"}")
        t.check("socket url", Frames.socketUrl("https://recitbot.com/") == "wss://recitbot.com/device/ws"
                && Frames.socketUrl("http://127.0.0.1:8787") == "ws://127.0.0.1:8787/device/ws")
        t.equal("enroll code: alphanumerics only (BOM, dashes, spaces stripped)", Frames.sanitizeCode("\u{FEFF}ab-12 CD\r"), "ab12CD")
        t.equal("enroll body (name cut to 64)", Frames.enrollBody(code: "ABC123", name: String(repeating: "n", count: 70)),
                "{\"code\":\"ABC123\",\"name\":\"" + String(repeating: "n", count: 64) + "\",\"platform\":\"macos\"}")
        t.equal("enroll body first pair (no token): platform macos, no device_token key", Frames.enrollBody(code: "ABC123", name: "Office Mac"),
                "{\"code\":\"ABC123\",\"name\":\"Office Mac\",\"platform\":\"macos\"}")
        t.equal("enroll body first pair (empty token): no device_token key", Frames.enrollBody(code: "ABC123", name: "Office Mac", deviceToken: ""),
                "{\"code\":\"ABC123\",\"name\":\"Office Mac\",\"platform\":\"macos\"}")
        t.equal("enroll body re-pair: device_token and platform macos",
                Frames.enrollBody(code: "ABC123", name: "Office Mac", deviceToken: "fake-token-placeholder"),
                "{\"code\":\"ABC123\",\"name\":\"Office Mac\",\"platform\":\"macos\",\"device_token\":\"fake-token-placeholder\"}")
        t.equal("enroll error: 401 body error string", Frames.enrollError(401, "{\"error\":\"invalid or expired pairing code\"}"),
                "invalid or expired pairing code")
        t.equal("enroll error: 403 device-limit body error string",
                Frames.enrollError(403, "{\"error\":\"This account already has 2 devices. Remove one to pair another.\"}"),
                "This account already has 2 devices. Remove one to pair another.")
        t.check("enroll error: 503 empty or non-JSON body = status code", Frames.enrollError(503, "") == "503"
                && Frames.enrollError(503, "<html>Service Unavailable</html>") == "503" && Frames.enrollError(503, "{\"error\":\"\"}") == "503")
        t.check("loopback hosts", Frames.isLoopbackHost("localhost") && Frames.isLoopbackHost("127.0.0.1") && Frames.isLoopbackHost("[::1]")
                && !Frames.isLoopbackHost("recitbot.com") && !Frames.isLoopbackHost("127.0.0.1.evil.example") && !Frames.isLoopbackHost(nil))
        t.check("program args", Program.arg(["--data", "/x", "--set"], "--data") == "/x" && Program.arg(["--data", "/x", "--set"], "--set") == nil
                && Program.arg([], "--data") == nil)

        var f = base
        f["webcam"] = "false"; f["webcam_size"] = "25"; f["webcam_shape"] = "rect"; f["mic"] = "true"; f["system_audio"] = "true"
        f["monitor"] = "right"; f["upload_part_bytes"] = "33554432"
        let o = StartOpts.from(f, configWebcam: true)
        t.check("start options from a signed frame", o.mic && o.systemAudio && o.monitor == "right" && o.micDevice == nil && o.window == nil
                && !o.cam.on && o.cam.pct == 25 && o.cam.px == 0 && o.cam.shape == "rect" && o.partBytes == 33554432)
        var g = base
        g["webcam_size"] = "large"; g["webcam_shape"] = "hex"; g["upload_part_bytes"] = "-5"; g["camera"] = ""
        let p = StartOpts.from(g, configWebcam: true)
        t.check("start options: preset size, unknown shape, negative part size, config webcam", p.cam.on && p.cam.px == 360 && p.cam.pct == 0
                && p.cam.shape == nil && p.partBytes == 0 && p.cam.camera == nil && !p.mic)
        var h = base
        h["webcam_size"] = "250"
        t.check("start options: percent out of range ignored", StartOpts.from(h, configWebcam: false).cam.pct == 0)

        // Auto-open: once-per-recording (parity: C# AudioSelfTest "ready:" cases).
        let id = "AAAAAAAAAAAAAAAAAAAAAA"
        let rl = ReadyLinks()
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 15; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let t0 = cal.date(from: c)!
        t.check("ready: nothing opens for a recording this PC never uploaded", !rl.claim(id, t0))
        rl.expect(id, t0)
        t.check("ready: opens once, never twice (duplicate / replay after reconnect)", rl.claim(id, t0 + 5) && !rl.claim(id, t0 + 6))
        rl.expect(id, t0 + 7)
        t.check("ready: a second upload of the same id does not re-arm it", !rl.claim(id, t0 + 8))
        rl.expect("BBBBBBBBBBBBBBBBBBBBBB", t0)
        rl.forget("BBBBBBBBBBBBBBBBBBBBBB")
        rl.expect("CCCCCCCCCCCCCCCCCCCCCC", t0)
        t.check("ready: failed upload (forgotten) and stale (> 30 min) never open", !rl.claim("BBBBBBBBBBBBBBBBBBBBBB", t0 + 1)
                && !rl.claim("CCCCCCCCCCCCCCCCCCCCCC", t0 + 31 * 60))
        t.check("log timestamp is .NET round-trip UTC", Log.timestamp(t0 + 0.25) == "2026-11-15T12:00:00.2500000Z")
    }

    static func loadOutcome(_ dir: String) -> String {
        do { return try Config.load(dir) == nil ? "nil" : "config" } catch { return "error" }
    }

    static func mode(_ path: String) -> Int {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_mode & 0o777) : -1
    }
}
