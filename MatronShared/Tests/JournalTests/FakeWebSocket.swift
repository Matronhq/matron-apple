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

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

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

/// Simulates the journal server: replies to hello with events > cursor from
/// a canonical journal, then kills the connection after a random number of
/// frames. Every reconnect resumes from whatever cursor the client sends —
/// exactly the real server's contract.
final class ChaosServerConnector: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let journal: [String]        // journalLine(seq:) strings, seq 1...N
    private let headSeq: Int64
    private(set) var connectCount = 0

    init(journal: [String], headSeq: Int64) {
        self.journal = journal
        self.headSeq = headSeq
    }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        lock.lock()
        connectCount += 1
        lock.unlock()
        return ChaosServerConnection(journal: journal, headSeq: headSeq)
    }
}

final class ChaosServerConnection: WebSocketConnection, @unchecked Sendable {
    private let inner = FakeWebSocketConnection()
    private let journal: [String]
    private let headSeq: Int64

    init(journal: [String], headSeq: Int64) {
        self.journal = journal
        self.headSeq = headSeq
    }

    func sendText(_ text: String) async throws {
        // Intercept the hello to learn the client's cursor; ignore other ops.
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["op"] as? String == "hello"
        else {
            try await inner.sendText(text)
            return
        }
        let cursor = (obj["cursor"] as? NSNumber)?.int64Value ?? 0
        inner.serve(#"{"kind":"control","op":"hello_ok","seq":\#(headSeq)}"#)
        let remaining = journal.dropFirst(Int(cursor))
        let cutAfter = Int.random(in: 1...12) // kill mid-replay, often mid-batch
        for (offset, line) in remaining.enumerated() {
            if offset == cutAfter {
                inner.closeFromServer()
                return
            }
            inner.serve(line)
        }
        // Served to the end without cutting: leave the connection open.
    }

    func receiveText() async throws -> String { try await inner.receiveText() }
    func ping() async throws { try await inner.ping() }
    func close() { inner.close() }
}
