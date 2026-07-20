import Foundation
import os

public protocol WebSocketConnecting: Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection
}

public protocol WebSocketConnection: AnyObject, Sendable {
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    /// One liveness round-trip; throws if the peer is gone.
    func ping() async throws
    func close()
}

public enum JournalConnectionError: Error, Equatable, Sendable {
    case authRejected
    case badHandshake
    case socketClosed
    case handshakeTimeout
}

public final class URLSessionWebSocketConnector: WebSocketConnecting {
    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "ws-transport")
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func sendText(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            logRejectedUpgrade(error)
            throw error
        }
    }

    func receiveText() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: throw JournalConnectionError.socketClosed
            }
        } catch {
            logRejectedUpgrade(error)
            throw error
        }
    }

    /// A refused HTTP upgrade (proxy 4xx/5xx in front of the journal
    /// server, wrong endpoint, captive portal…) surfaces as a generic
    /// URLError with the status only on `task.response`. Log it un-gated:
    /// the 2026-07-13 phone incident retried a rejected upgrade silently
    /// for 90 minutes with nothing in the persisted log.
    private func logRejectedUpgrade(_ error: Error) {
        guard let http = task.response as? HTTPURLResponse else { return }
        Self.logger.warning("ws upgrade rejected: HTTP \(http.statusCode, privacy: .public) from \(http.url?.host ?? "?", privacy: .public) (\(error.localizedDescription, privacy: .public))")
    }

    func ping() async throws {
        try await Self.awaitPong { task.sendPing(pongReceiveHandler: $0) }
    }

    /// `URLSessionWebSocketTask.sendPing` can invoke its pong handler a second
    /// time when the socket dies mid-ping; `CheckedContinuation` traps on the
    /// second resume (three MatronMac crashes on 2026-07-20), so forward only
    /// the first callback.
    static func awaitPong(_ sendPing: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                let isFirst = resumed.withLock { alreadyResumed in
                    defer { alreadyResumed = true }
                    return !alreadyResumed
                }
                guard isFirst else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
