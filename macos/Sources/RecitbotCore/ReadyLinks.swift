import Foundation

/// Recordings this Mac uploaded and may open once. A ready frame opens a link only for a recording that is waiting
/// (upload started here, at most 30 min ago) and only the first time: a failed or never-uploaded recording, a duplicate
/// frame or one replayed after a reconnect opens nothing. parity: AgentRecorder.cs ReadyLinks
public final class ReadyLinks: @unchecked Sendable {
    public static let maxWait: TimeInterval = 30 * 60
    let gate = NSLock()
    var waiting = [String: Date]()
    var claimed = Set<String>()

    public init() {}

    public func expect(_ id: String, _ now: Date) {
        gate.lock(); defer { gate.unlock() }
        if !claimed.contains(id) { waiting[id] = now }
    }

    public func forget(_ id: String) {
        gate.lock(); defer { gate.unlock() }
        waiting.removeValue(forKey: id)
    }

    public func claim(_ id: String?, _ now: Date) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard let id = id, !claimed.contains(id), let at = waiting[id] else { return false }
        waiting.removeValue(forKey: id)
        if now.timeIntervalSince(at) > ReadyLinks.maxWait { return false }
        claimed.insert(id)
        return true
    }
}
