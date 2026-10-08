import XCTest
import MatronJournal
@testable import MatronShare

final class JournalShareTransportTests: XCTestCase {
    private let server = URL(string: "https://journal.example")!

    private func mediaOp(_ blobRef: String) -> ClientOp {
        .sendMedia(convoID: "c1", type: "file", blobRef: blobRef, name: "a.zip",
                   contentType: "application/zip", size: 4, caption: nil, batch: nil, localID: "l-\(blobRef)")
    }

    private func transport(_ socket: ShareFakeSocket, session: URLSession = ShareStubURLProtocol.session(),
                           timeout: Duration = .seconds(5)) -> JournalShareTransport {
        JournalShareTransport(serverURL: server, token: "tok", urlSession: session,
                              connector: ShareFakeConnector(socket: socket), confirmationTimeout: timeout)
    }

    func test_deliver_opensALiveOnlySocket_andReturnsOnceEverySendIsEchoed() async throws {
        let socket = ShareFakeSocket()
        socket.onSend = { socket, op in socket.echo(op) }

        try await transport(socket).deliver([mediaOp("b1"), mediaOp("b2")])

        let sent = socket.sent
        XCTAssertEqual(sent.first?["op"] as? String, "hello")
        XCTAssertTrue(sent.first?["cursor"] is NSNull, "a share asks for no replay")
        XCTAssertEqual(sent.dropFirst().map { $0["blob_ref"] as? String }, ["b1", "b2"])
        XCTAssertTrue(ShareStubURLProtocol.requests.isEmpty, "the echoes were enough")
    }

    func test_deliver_ignoresOtherConversationsTraffic() async throws {
        let socket = ShareFakeSocket()
        socket.onSend = { socket, op in
            socket.serve(["kind": "journal", "seq": 11, "convo_id": "other", "ts": 1, "sender": "user:someone",
                          "type": "file", "payload": ["blob_ref": "b1"]])
            socket.serve(["kind": "journal", "seq": 12, "convo_id": "c1", "ts": 1, "sender": "agent:box",
                          "type": "text", "payload": ["body": "working"]])
            socket.echo(op, seq: 13)
        }
        try await transport(socket).deliver([mediaOp("b1")])
    }

    func test_deliver_serverRejection_isReported() async {
        let socket = ShareFakeSocket()
        socket.onSend = { socket, _ in
            socket.serve(["kind": "control", "op": "error", "code": "forbidden", "ref": "send",
                          "detail": "sub-chat is read-only"])
        }
        do {
            try await transport(socket).deliver([mediaOp("b1")])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ShareSendError, .rejected("sub-chat is read-only"))
        }
    }

    /// A repeat of a send that already landed is not echoed. The
    /// conversation's own tail is what says it arrived.
    func test_deliver_withNoEcho_isConfirmedFromTheConversation() async throws {
        let socket = ShareFakeSocket()
        let session = ShareStubURLProtocol.session(json: ["events": [
            ["seq": 9, "convo_id": "c1", "ts": 1, "sender": "user:someone", "type": "file",
             "payload": ["blob_ref": "b1", "name": "a.zip"]],
        ]])

        try await transport(socket, session: session, timeout: .milliseconds(50)).deliver([mediaOp("b1")])

        XCTAssertEqual(ShareStubURLProtocol.requests.first?.url?.path, "/convo/c1/messages")
    }

    func test_deliver_withNoEchoAndNoTrace_isUnconfirmed() async {
        let socket = ShareFakeSocket()
        let session = ShareStubURLProtocol.session(json: ["events": []])
        do {
            try await transport(socket, session: session, timeout: .milliseconds(50)).deliver([mediaOp("b1")])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ShareSendError, .unconfirmed)
        }
    }

    func test_deliver_textSend_isMatchedByItsBody() async throws {
        let socket = ShareFakeSocket()
        socket.onSend = { socket, op in socket.echo(op) }
        try await transport(socket).deliver([.send(convoID: "c1", body: "https://example.com", localID: "l1")])
        XCTAssertEqual(socket.sent.last?["type"] as? String, "text")
    }

    func test_upload_streamsTheFile_andReturnsTheMediaID() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try Data([1, 2, 3, 4]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = ShareStubURLProtocol.session(json: ["media_id": "m1"])
        let file = SharedFile(url: url, filename: "a.zip", mimeType: "application/zip", sizeBytes: 4)

        let ref = try await transport(ShareFakeSocket(), session: session).upload(file) { _ in }

        XCTAssertEqual(ref, "m1")
        let request = try XCTUnwrap(ShareStubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/media")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func test_upload_refusedAsTooLarge_namesTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try Data([1]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = ShareStubURLProtocol.session(status: 413, json: ["error": "too_large"])
        let file = SharedFile(url: url, filename: "big.zip", mimeType: "application/zip", sizeBytes: 1)
        do {
            _ = try await transport(ShareFakeSocket(), session: session).upload(file) { _ in }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ShareSendError, .tooLarge(name: "big.zip"))
        }
    }

    func test_upload_withARevokedToken_saysSignedOut() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try Data([1]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = ShareStubURLProtocol.session(status: 401, json: ["error": "unauthenticated"])
        let file = SharedFile(url: url, filename: "a.zip", mimeType: "application/zip", sizeBytes: 1)
        do {
            _ = try await transport(ShareFakeSocket(), session: session).upload(file) { _ in }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ShareSendError, .signedOut)
        }
    }
}
