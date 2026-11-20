import Foundation
import RecitbotCore

/// Opens the device WebSocket (wss://server/device/ws, `Authorization: Bearer <device token>`) and reports when the
/// upgrade finished, like ClientWebSocket.ConnectAsync. No automatic keep-alive pings (KeepAliveInterval = 0 in C#):
/// the agent sends its own application-level "ping" text frame every 45 s.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: ((Error?) -> Void)?

    func onOpen(_ cb: @escaping (Error?) -> Void) {
        lock.lock(); opened = cb; lock.unlock()
    }

    private func fire(_ e: Error?) {
        lock.lock(); let cb = opened; opened = nil; lock.unlock()
        cb?(e)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        fire(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A refused upgrade (401 unauthorized, 426, ...) reads like the C# WebSocketException.
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            fire(SocketError(type: "WebSocketException",
                             message: "The server returned status code '\(http.statusCode)' when status code '101' was expected.",
                             status: http.statusCode))
            return
        }
        fire(error ?? SocketError(type: "WebSocketException", message: "The connection was closed before the WebSocket opened."))
    }
}

struct SocketError: Error {
    let type: String
    let message: String
    /// The refused upgrade's HTTP status (410 = maybe revoked, see Agent.revoked); 0 when there was no HTTP answer.
    /// parity: AgentRecorder.cs Revocation.HandshakeStatus
    var status = 0
}

enum WebSocketConnection {
    /// Connected task and its session (invalidate the session when done with the task).
    static func connect(server: String?, token: String?) async throws -> (URLSession, URLSessionWebSocketTask) {
        guard let url = URL(string: Frames.socketUrl(server ?? "")), url.scheme == "wss" || url.scheme == "ws" else {
            throw SocketError(type: "UriFormatException", message: "Invalid URI: The format of the URI could not be determined.")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + (token ?? ""), forHTTPHeaderField: "Authorization")
        let conf = URLSessionConfiguration.ephemeral
        conf.waitsForConnectivity = false
        conf.timeoutIntervalForRequest = 120 // > the 45 s ping period, so an idle socket never times out between pings
        conf.timeoutIntervalForResource = 365 * 24 * 3600 // the socket lives as long as the agent
        conf.httpCookieStorage = nil
        conf.urlCache = nil
        let d = SocketDelegate()
        let session = URLSession(configuration: conf, delegate: d, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                d.onOpen { e in
                    if let e = e { cont.resume(throwing: e) } else { cont.resume() }
                }
                task.resume()
            }
        } catch {
            task.cancel()
            session.invalidateAndCancel()
            throw error
        }
        return (session, task)
    }

    /// "<ExceptionType> <Message>" for the "connection error: ..." log line (never contains the token).
    static func describe(_ e: Error) -> String {
        if let s = e as? SocketError { return s.type + " " + s.message }
        let ns = e as NSError
        let type = ns.domain == NSURLErrorDomain ? "URLError" : ns.domain == NSPOSIXErrorDomain ? "POSIXError" : String(describing: Swift.type(of: e))
        return type + " " + ns.localizedDescription
    }
}
