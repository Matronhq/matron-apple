import Foundation

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
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw JournalConnectionError.socketClosed
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
