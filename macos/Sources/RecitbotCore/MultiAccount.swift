import Foundation

/// One install, several Recitbot accounts (hello "multi_account", 0.6.0): one device WebSocket per account, every
/// command answered on the connection it came in on, one recording per machine. The decisions live here (covered by
/// the selftest); the sockets are the app's Agent / AccountLink.
/// parity: AgentRecorder.cs RecordingOwners / AccountSet
public final class RecordingOwners: @unchecked Sendable {
    private let lock = NSLock()
    /// recording id -> account id, newest last (only the last `keep` are remembered).
    private var owners = [(id: String, account: String)]()
    static let keep = 64

    public init() {}

    /// Ties a recording id to the account whose connection sent it. false when the id already belongs to another
    /// account (that account's recording is never touched from here).
    public func claim(_ id: String?, account: String) -> Bool {
        let rid = id ?? ""
        lock.lock(); defer { lock.unlock() }
        if let o = owners.first(where: { $0.id == rid }) { return o.account == account }
        owners.append((rid, account))
        if owners.count > RecordingOwners.keep { owners.removeFirst(owners.count - RecordingOwners.keep) }
        return true
    }

    public func owner(_ id: String?) -> String? {
        let rid = id ?? ""
        lock.lock(); defer { lock.unlock() }
        return owners.last(where: { $0.id == rid })?.account
    }

    /// stop / a status for this recording from `account`: only the account that started it.
    public func owns(_ id: String?, account: String) -> Bool { return owner(id) == account }

    /// One recording per machine, across accounts: a start is refused (the existing "BUSY" status) while a recording
    /// runs, or while another account's start waits for Screen Recording (the same account's newer start replaces its
    /// own waiting one, as before).
    public static func busy(recording: Bool, waitingFor: String?, account: String) -> Bool {
        return recording || (waitingFor != nil && waitingFor != account)
    }
}

/// The connections the agent runs against the accounts in config.dat (read again whenever the file changes).
public enum AccountSet {
    /// What to change: accounts to connect, and account ids whose connection ends. An account whose device id, token,
    /// secret or server changed (a refresh) is ended and connected again with the new entry.
    public struct Diff: Equatable {
        public var start = [Account]()
        public var stop = [String]()
    }

    public static func diff(running: [Account], wanted: [Account]) -> Diff {
        var d = Diff()
        for r in running where !wanted.contains(r) { d.stop.append(r.accountId) }
        for w in wanted where !running.contains(w) { d.start.append(w) }
        return d
    }

    /// The account a saved (pending) start frame was signed for.
    public static func account(ofFrame frame: String) -> String? {
        guard let f = try? Json.parseFlat(frame) else { return nil }
        return Fields.opt(f, "account_id")
    }
}
