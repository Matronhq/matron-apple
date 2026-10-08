import XCTest
import MatronJournal
import MatronModels
@testable import MatronShare

final class ShareSenderTests: XCTestCase {
    func test_oneFile_isSentWithTheMessageAsItsCaption_andNoBatch() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let file = makeSharedFile("archive.zip")

        try await sender.send(ShareRequest(convoID: "c1", message: " look at this ", files: [file])) { _ in }

        XCTAssertEqual(transport.uploads, ["archive.zip"])
        guard case let .sendMedia(convoID, type, blobRef, name, contentType, size, caption, batch, _)?
                = transport.delivered.first?.first else { return XCTFail("no media op") }
        XCTAssertEqual(convoID, "c1")
        XCTAssertEqual(type, "file")
        XCTAssertEqual(blobRef, "blob-archive.zip")
        XCTAssertEqual(name, "archive.zip")
        XCTAssertEqual(contentType, "application/zip")
        XCTAssertEqual(size, 100)
        XCTAssertEqual(caption, "look at this")
        XCTAssertNil(batch)
    }

    func test_severalFiles_shareABatch_andOnlyTheFirstCarriesTheMessage() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let files = [makeSharedFile("a.png", mimeType: "image/png"), makeSharedFile("b.pdf", mimeType: "application/pdf")]

        try await sender.send(ShareRequest(convoID: "c1", message: "two things", files: files)) { _ in }

        let ops = try XCTUnwrap(transport.delivered.first)
        XCTAssertEqual(ops.count, 2)
        guard case let .sendMedia(_, firstType, _, _, _, _, firstCaption, firstBatch, _) = ops[0],
              case let .sendMedia(_, secondType, _, _, _, _, secondCaption, secondBatch, _) = ops[1]
        else { return XCTFail("expected two media ops") }
        XCTAssertEqual(firstType, "image")
        XCTAssertEqual(secondType, "file")
        XCTAssertEqual(firstCaption, "two things")
        XCTAssertNil(secondCaption)
        XCTAssertEqual(firstBatch?.id, secondBatch?.id)
        XCTAssertEqual([firstBatch?.index, secondBatch?.index], [1, 2])
        XCTAssertEqual([firstBatch?.total, secondBatch?.total], [2, 2])
    }

    func test_messageWithNoFiles_isAPlainTextSend() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)

        try await sender.send(ShareRequest(convoID: "c1", message: "https://example.com", files: [])) { _ in }

        XCTAssertTrue(transport.uploads.isEmpty)
        guard case let .send(convoID, body, _)? = transport.delivered.first?.first
        else { return XCTFail("no text op") }
        XCTAssertEqual(convoID, "c1")
        XCTAssertEqual(body, "https://example.com")
    }

    func test_nothingToSend_doesNothing() async throws {
        let transport = RecordingTransport()
        try await ShareSender(transport: transport).send(ShareRequest(convoID: "c1", message: "  ", files: [])) { _ in }
        XCTAssertTrue(transport.delivered.isEmpty)
    }

    /// The second attempt must not upload what already went up, and must
    /// repeat each operation under the identifier it had the first time, so
    /// the server can tell a repeat from a second message.
    func test_retryAfterAFailure_keepsUploadsAndIdentifiers() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let files = [makeSharedFile("a.zip"), makeSharedFile("b.zip")]
        let request = ShareRequest(convoID: "c1", message: "", files: files)
        transport.failUpload(of: "b.zip", with: ShareSendError.failed("offline"))

        do {
            try await sender.send(request) { _ in }
            XCTFail("expected the upload to fail")
        } catch {}
        XCTAssertEqual(transport.uploads, ["a.zip"])
        XCTAssertTrue(transport.delivered.isEmpty)

        transport.failNextDelivery(with: ShareSendError.unconfirmed)
        do {
            try await sender.send(request) { _ in }
            XCTFail("expected the delivery to fail")
        } catch {}
        try await sender.send(request) { _ in }

        XCTAssertEqual(transport.uploads, ["a.zip", "b.zip"], "nothing uploads twice")
        XCTAssertEqual(transport.delivered.count, 2)
        XCTAssertEqual(transport.delivered[0], transport.delivered[1])
    }

    func test_progress_runsFromZeroToOne_withoutGoingBackwards() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let seen = Recorder()
        let files = [makeSharedFile("a.zip", size: 300), makeSharedFile("b.zip", size: 100)]

        try await sender.send(ShareRequest(convoID: "c1", message: "", files: files)) { seen.add($0) }

        let fractions = seen.values.map(\.fraction)
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(seen.values.first?.filename, "a.zip")
        XCTAssertEqual(seen.values.compactMap(\.fileIndex).max(), 2)
        XCTAssertNil(seen.values.last?.fileIndex)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [ShareProgress] = []
        func add(_ value: ShareProgress) { lock.lock(); _values.append(value); lock.unlock() }
        var values: [ShareProgress] { lock.lock(); defer { lock.unlock() }; return _values }
    }
}
