import Foundation

/// One established, authenticated socket. Create via `establish`, consume
/// `frames()` until it throws, then let the sync engine reconnect — a
/// resume is indistinguishable from a continuation server-side.
public struct JournalConnection: Sendable {
    private let socket: any WebSocketConnection

    public static func establish(
        connector: any WebSocketConnecting, wsURL: URL, token: String, cursor: Int64,
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
            try await socket.sendText(ClientOp.hello(token: token, cursor: cursor).encoded())
            while true {
                let text = try await socket.receiveText()
                guard let frame = ServerFrame.decode(text) else { continue }
                switch frame {
                case .helloOK(let headSeq):
                    return (JournalConnection(socket: socket), headSeq)
                case .error(let code, _):
                    throw code == "auth"
                        ? JournalConnectionError.authRejected
                        : JournalConnectionError.badHandshake
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

    public func ping() async throws {
        try await socket.ping()
    }

    public func close() {
        socket.close()
    }
}
