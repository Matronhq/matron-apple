import Foundation

/// One established, authenticated socket. Create via `establish`, consume
/// `frames()` until it throws, then let the sync engine reconnect — a
/// resume is indistinguishable from a continuation server-side.
public struct JournalConnection: Sendable {
    private let socket: any WebSocketConnection

    public static func establish(
        connector: any WebSocketConnecting, wsURL: URL, token: String, cursor: Int64
    ) async throws -> (connection: JournalConnection, headSeq: Int64) {
        let socket = try await connector.connect(to: wsURL)
        try await socket.sendText(ClientOp.hello(token: token, cursor: cursor).encoded())
        // The first decodable frame after hello is hello_ok or an auth error.
        while true {
            let text = try await socket.receiveText()
            guard let frame = ServerFrame.decode(text) else { continue }
            switch frame {
            case .helloOK(let headSeq):
                return (JournalConnection(socket: socket), headSeq)
            case .error(let code, _):
                socket.close()
                throw code == "auth" ? JournalConnectionError.authRejected : JournalConnectionError.badHandshake
            default:
                socket.close()
                throw JournalConnectionError.badHandshake
            }
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
            continuation.onTermination = { _ in pump.cancel() }
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
