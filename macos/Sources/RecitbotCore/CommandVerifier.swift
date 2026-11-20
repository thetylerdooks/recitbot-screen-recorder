import CryptoKit
import Foundation

/// Verifies signed commands: HMAC, account/device binding, expiry and a monotonic nonce (replay protection).
/// parity: AgentRecorder.cs CommandVerifier (same canonical string, same rejection reasons, nonce.txt persistence).
public final class CommandVerifier: @unchecked Sendable {
    let accountId: String?, deviceId: String?, secret: String, noncePath: String?
    var lastNonce: Int64 = 0

    public init(accountId: String?, deviceId: String?, secret: String?, noncePath: String?) {
        self.accountId = accountId; self.deviceId = deviceId; self.secret = secret ?? ""; self.noncePath = noncePath
        if let p = noncePath, let t = try? SecureFile.readText(p), let n = NetParse.int64(NetParse.trim(t)) { lastNonce = n }
    }

    /// Keep in sync with worker/src/device-hub.ts `canonicalCommand`.
    public static func canonical(_ f: JsonFields) -> String {
        let g = { (k: String) in Fields.get(f, k) }
        let has = { (k: String) in Fields.has(f, k) }
        var s = [
            "v1", g("type"), g("recording_id"), g("max_seconds"), g("mic") == "true" ? "1" : "0",
            g("nonce"), g("exp"), g("account_id"), g("device_id"), g("upload_token"),
        ].joined(separator: "|")
        // Optional blocks are signed only when present, so commands without them keep the original v1 form.
        if has("webcam") || has("camera") || has("webcam_size") {
            let w = g("webcam")
            s += "|cam|" + (w == "true" ? "1" : w == "false" ? "0" : "") + "|" + g("camera") + "|" + g("webcam_size")
        }
        if has("monitor") || has("mic_device") { s += "|dev|" + g("monitor") + "|" + g("mic_device") }
        if has("window") { s += "|win|" + g("window") }
        // 0.4 blocks (the Worker sends them only to recorders whose hello announced the feature).
        if has("system_audio") { s += "|sa|" + (g("system_audio") == "true" ? "1" : "0") }
        if has("webcam_shape") { s += "|shape|" + g("webcam_shape") }
        if has("url") { s += "|url|" + g("url") }
        // Chunked upload (hello "chunked_upload"): the part size for files larger than one PUT.
        if has("upload_part_bytes") { s += "|mp|" + g("upload_part_bytes") }
        // Self-update (hello "self_update"), only on "update" commands; the download link is the url block.
        if has("version") || has("sha256") { s += "|upd|" + g("version") + "|" + g("sha256") }
        // Uninstall scope (hello "multi_account"), only on "uninstall" commands that carry one.
        if has("scope") { s += "|scope|" + g("scope") }
        return s
    }

    /// HMAC-SHA256 of the UTF-8 message under the UTF-8 key, lowercase hex.
    public static func hmacHex(_ key: String, _ msg: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func fixedTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf16), y = Array(b.utf16)
        if x.count != y.count { return false }
        var diff: UInt16 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// nil when valid, otherwise the rejection reason.
    public func verify(_ f: JsonFields, _ nowUnix: Int64) -> String? {
        if !CommandVerifier.fixedTimeEquals(Fields.get(f, "mac"), CommandVerifier.hmacHex(secret, CommandVerifier.canonical(f))) { return "bad mac" }
        if Fields.get(f, "account_id") != (accountId ?? "\u{0}") { return "wrong account" }
        if Fields.get(f, "device_id") != (deviceId ?? "\u{0}") { return "wrong device" }
        guard let exp = NetParse.int64(Fields.get(f, "exp")), exp >= nowUnix else { return "expired" }
        guard let nonce = NetParse.int64(Fields.get(f, "nonce")), nonce > lastNonce else { return "replayed nonce" }
        lastNonce = nonce
        if let p = noncePath { try? SecureFile.write(p, String(nonce)) }
        return nil
    }
}
