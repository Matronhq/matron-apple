import Foundation
import MatronJournal

/// `ShareTransport` against a journal server: files go up over HTTP, and
/// the message is posted over a short-lived socket of its own.
///
/// The socket asks for no replay (a nil cursor), so opening it costs the
/// same whether the account holds ten events or a million, and it never
/// touches the app's local store. That store belongs to the app, which may
/// be suspended while this runs.
public struct JournalShareTransport: ShareTransport {
    private let api: JournalAPI
    private let token: String
    private let connector: any WebSocketConnecting
    private let confirmationTimeout: Duration
    private let baseline = Baseline()

    public init(serverURL: URL, token: String, urlSession: URLSession = .shared,
                connector: (any WebSocketConnecting)? = nil,
                confirmationTimeout: Duration = .seconds(12)) {
        self.api = JournalAPI(serverURL: serverURL, urlSession: urlSession, token: token)
        self.token = token
        self.connector = connector ?? URLSessionWebSocketConnector(urlSession: urlSession)
        self.confirmationTimeout = confirmationTimeout
    }

    public func upload(_ file: SharedFile, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        do {
            return try await api.uploadMedia(fileAt: file.url, contentType: file.mimeType, progress: progress)
        } catch JournalAPIError.http(status: 413, _) {
            throw ShareSendError.tooLarge(name: file.filename)
        } catch {
            throw Self.mapped(error)
        }
    }

    public func deliver(_ ops: [ClientOp]) async throws {
        var awaiting = ops.compactMap(Expectation.init)
        guard !awaiting.isEmpty else { return }
        let convoID = awaiting[0].convoID
        let connection: JournalConnection
        let sentAfter: Int64
        do {
            let established = try await JournalConnection.establish(
                connector: connector, wsURL: api.wsURL, token: token, cursor: nil)
            connection = established.connection
            sentAfter = baseline.settle(established.headSeq)
        } catch {
            throw Self.mapped(error)
        }
        defer { connection.close() }
        // The socket closing is what ends the wait below: a receive in
        // flight cannot be cancelled any other way.
        let watchdog = Task { [confirmationTimeout] in
            try? await Task.sleep(for: confirmationTimeout)
            if !Task.isCancelled { connection.close() }
        }
        defer { watchdog.cancel() }
        do {
            // Nothing has been asked of the server until the last write
            // returns, so a failure here is an ordinary one to retry.
            for op in ops { try await connection.send(op) }
        } catch {
            throw Self.mapped(error)
        }
        do {
            for try await frame in connection.frames() {
                switch frame {
                case .journal(let event):
                    awaiting.removeAll { $0.matches(event) }
                case .error(let code, let ref, _, let detail) where ref == "send":
                    throw ShareSendError.rejected(detail ?? code)
                default:
                    break
                }
                if awaiting.isEmpty { return }
            }
        } catch let error as ShareSendError {
            throw error
        } catch {
            // Fall through: the socket went away (or timed out) before
            // every echo arrived, which says nothing about whether the
            // sends landed. The journal itself is asked below.
        }
        // A repeat of a send that already landed is not echoed again, and a
        // socket can die between the write and the echo. Either way the
        // conversation's own tail settles it.
        let recent: [JournalEvent]
        do {
            recent = try await api.messages(convoID: convoID, beforeSeq: nil, limit: 50)
        } catch {
            throw Self.mapped(error)
        }
        // Only events newer than this sheet's first connection count: an
        // older message with the same text is not this one arriving.
        for event in recent where event.seq > sentAfter { awaiting.removeAll { $0.matches(event) } }
        if !awaiting.isEmpty { throw ShareSendError.unconfirmed }
    }

    /// The journal's head when this transport first connected. Everything
    /// it sends lands after that point, including what an earlier attempt
    /// sent, so the first value is kept across retries.
    private final class Baseline: @unchecked Sendable {
        private let lock = NSLock()
        private var seq: Int64?
        func settle(_ head: Int64) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            if let seq { return seq }
            seq = head
            return head
        }
    }

    /// What the journal's echo of one operation looks like.
    struct Expectation {
        let convoID: String
        let blobRef: String?
        let body: String?

        init?(_ op: ClientOp) {
            switch op {
            case let .sendMedia(convoID, _, blobRef, _, _, _, _, _, _):
                self.convoID = convoID
                self.blobRef = blobRef
                self.body = nil
            case let .send(convoID, body, _):
                self.convoID = convoID
                self.blobRef = nil
                self.body = body
            default:
                return nil
            }
        }

        func matches(_ event: JournalEvent) -> Bool {
            guard event.convoID == convoID, event.sender.hasPrefix("user:") else { return false }
            let payload = event.payload
            if let blobRef { return payload["blob_ref"] as? String == blobRef }
            return event.type == JournalEventType.text && payload["body"] as? String == body
        }
    }

    static func mapped(_ error: Error) -> ShareSendError {
        switch error {
        case let error as ShareSendError:
            return error
        case JournalAPIError.unauthenticated, JournalConnectionError.authRejected:
            return .signedOut
        case JournalConnectionError.handshakeTimeout, JournalConnectionError.socketClosed,
             JournalConnectionError.badHandshake:
            return .failed("Couldn't reach the server. Check the connection and try again.")
        default:
            return .failed(error.localizedDescription)
        }
    }
}
