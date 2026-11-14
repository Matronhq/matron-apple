import Foundation
import os

/// One established, authenticated socket. Create via `establish`, consume
/// `frames()` until it throws, then let the sync engine reconnect — a
/// resume is indistinguishable from a continuation server-side.
public struct JournalConnection: Sendable {
    private let socket: any WebSocketConnection
    /// The Coordinator the journal reported in this connection's `hello_ok`.
    public let coordinatorHello: HelloCoordinator
    /// `hello_ok.archive`: `nil` from a journal that does not sync the
    /// archive, or when the hello did not ask (`archiveSince` nil).
    public let archiveHello: ArchiveDelta?
    /// The scope the journal gave this socket (`hello_ok.sync`); `nil` from
    /// a journal that predates sync scopes, which always sends everything.
    public let syncHello: SyncScope?
    /// Tells this connection from whichever one later replaces it.
    let id = UUID()

    private init(socket: any WebSocketConnection, coordinatorHello: HelloCoordinator, archiveHello: ArchiveDelta?,
                 syncHello: SyncScope?) {
        self.socket = socket
        self.coordinatorHello = coordinatorHello
        self.archiveHello = archiveHello
        self.syncHello = syncHello
    }

    /// A nil `cursor` asks for a live-only connection: no replay of what
    /// came before, for a caller that is here to send rather than to sync.
    /// `archiveSince` asks for the archive changes since that cursor, and
    /// `sync` names the scope.
    public static func establish(
        connector: any WebSocketConnecting, wsURL: URL, token: String, cursor: Int64?,
        archiveSince: Int64? = nil, sync: SyncScope? = nil,
        handshakeTimeout: Duration = .seconds(15)
    ) async throws -> (connection: JournalConnection, headSeq: Int64) {
        let socket = try await connector.connect(to: wsURL)
        let timedOut = TimeoutFlag()
        // receiveText() cannot observe cancellation, so a bounded handshake
        // works the other way around: the watchdog closes the socket, which
        // makes the suspended receive throw, and the catch below maps that
        // to .handshakeTimeout.
        let watchdog = Task {
            try? await Task.sleep(for: handshakeTimeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            socket.close()
        }
        defer { watchdog.cancel() }
        do {
            try await socket.sendText(ClientOp.hello(token: token, cursor: cursor, archiveSince: archiveSince, sync: sync).encoded())
            while true {
                let text = try await socket.receiveText()
                guard let frame = ServerFrame.decode(text) else { continue }
                switch frame {
                case .helloOK(let headSeq, let coordinator, let archive, let sync):
                    return (JournalConnection(socket: socket, coordinatorHello: coordinator,
                                              archiveHello: archive, syncHello: sync), headSeq)
                case .error(let code, _, _, _):
                    switch code {
                    case "auth": throw JournalConnectionError.authRejected
                    case "account_locked": throw JournalConnectionError.accountLocked
                    default: throw JournalConnectionError.badHandshake
                    }
                default:
                    throw JournalConnectionError.badHandshake
                }
            }
        } catch {
            socket.close()
            throw timedOut.isSet ? JournalConnectionError.handshakeTimeout : error
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public func frames() -> AsyncThrowingStream<ServerFrame, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let text = try await socket.receiveText()
                        if let frame = ServerFrame.decode(text) {
                            continuation.yield(frame)
                            // A `device_meta` frame also carries the box's
                            // lock state.
                            if case .deviceMeta = frame, let lock = ServerFrame.boxLock(inDeviceMeta: text) {
                                continuation.yield(lock)
                            }
                        }
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                socket.close()
            }
        }
    }

    public func send(_ op: ClientOp) async throws {
        try await socket.sendText(op.encoded())
    }

    /// One liveness round-trip, given up on after `timeout`. The transport's
    /// pong handler may not fire for minutes on a black-holed socket and a
    /// ping cannot observe cancellation, so the wait is raced rather than
    /// cancelled: a timeout returns at once and the ping is left to finish
    /// when the socket is closed.
    public func ping(timeout: Duration) async throws {
        let socket = self.socket
        let finished = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            @Sendable func finish(_ result: Result<Void, Error>) {
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            Task {
                do {
                    try await socket.ping()
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish(.failure(JournalConnectionError.pingTimeout))
            }
        }
    }

    public func close() {
        socket.close()
    }
}
