import Foundation
@testable import MatronJournal

/// Scriptable fake socket. Push server frames with `serve(_:)`; closing
/// finishes the incoming stream so `receiveText` throws `socketClosed`.
final class FakeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private(set) var sent: [String] = []
    var pingError: Error?

    func serve(_ text: String) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
            lock.unlock()
        }
    }

    func closeFromServer() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: JournalConnectionError.socketClosed) }
    }

    func sendText(_ text: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw JournalConnectionError.socketClosed }
        sent.append(text)
    }

    func receiveText() async throws -> String {
        lock.lock()
        if !incoming.isEmpty {
            let next = incoming.removeFirst()
            lock.unlock()
            return next
        }
        if closed {
            lock.unlock()
            throw JournalConnectionError.socketClosed
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: JournalConnectionError.socketClosed)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func ping() async throws {
        if let pingError { throw pingError }
    }

    func close() { closeFromServer() }

    /// Convenience: last sent frame decoded as a JSON object.
    var lastSentObject: [String: Any]? {
        guard let last = sent.last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
    }
}

/// Hands out pre-built fake connections in order; records connect calls.
final class FakeConnector: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeWebSocketConnection]
    private(set) var connectCount = 0
    var connectError: Error?

    init(_ connections: [FakeWebSocketConnection]) { queue = connections }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        connectCount += 1
        if let connectError { throw connectError }
        guard !queue.isEmpty else { throw JournalConnectionError.socketClosed }
        return queue.removeFirst()
    }
}
