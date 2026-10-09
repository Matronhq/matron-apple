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

    /// Under the first attempt's identifiers the server would take an
    /// edited retry for the original and drop the edit.
    func test_retryAfterAnEdit_isANewMessage_butDoesNotUploadAgain() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let files = [makeSharedFile("a.zip"), makeSharedFile("b.zip")]
        transport.failNextDelivery(with: ShareSendError.unconfirmed)
        do {
            try await sender.send(ShareRequest(convoID: "c1", message: "first", files: files)) { _ in }
            XCTFail("expected the delivery to fail")
        } catch {}

        try await sender.send(ShareRequest(convoID: "c2", message: "second", files: files)) { _ in }

        XCTAssertEqual(transport.uploads, ["a.zip", "b.zip"], "nothing uploads twice")
        guard case let .sendMedia(_, _, firstBlob, _, _, _, _, firstBatch, firstID) = transport.delivered[0][0],
              case let .sendMedia(convoID, _, secondBlob, _, _, _, caption, secondBatch, secondID) = transport.delivered[1][0]
        else { return XCTFail("expected media ops") }
        XCTAssertEqual(convoID, "c2")
        XCTAssertEqual(caption, "second")
        XCTAssertEqual(firstBlob, secondBlob)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNotEqual(firstBatch?.id, secondBatch?.id)
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

    // MARK: New conversation

    private func convoIDs(_ ops: [ClientOp]) -> [String] {
        ops.compactMap {
            switch $0 {
            case let .sendMedia(convoID, _, _, _, _, _, _, _, _): return convoID
            case let .send(convoID, _, _): return convoID
            default: return nil
            }
        }
    }

    func test_newConversation_isStartedAfterTheUploads_andTheFilesGoIntoIt() async throws {
        let transport = RecordingTransport()
        let sender = ShareSender(transport: transport)
        let request = ShareRequest(destination: .newConversation(boxID: 7), message: "hello",
                                   files: [makeSharedFile("a.zip")])

        try await sender.send(request) { _ in }

        XCTAssertEqual(transport.starts, [7])
        XCTAssertEqual(convoIDs(try XCTUnwrap(transport.delivered.first)), ["new-7-1"])
    }

    func test_newConversation_failedUpload_startsNothing() async throws {
        let transport = RecordingTransport()
        transport.failUpload(of: "a.zip", with: ShareSendError.failed("offline"))
        let sender = ShareSender(transport: transport)
        let request = ShareRequest(destination: .newConversation(boxID: 7), message: "",
                                   files: [makeSharedFile("a.zip")])

        do {
            try await sender.send(request) { _ in }
            XCTFail("expected a throw")
        } catch {}

        XCTAssertTrue(transport.starts.isEmpty)
    }

    func test_newConversation_isStartedOnce_acrossARetryAndAnEdit() async throws {
        let transport = RecordingTransport()
        transport.failNextDelivery(with: ShareSendError.failed("dropped"))
        let sender = ShareSender(transport: transport)
        let file = makeSharedFile("a.zip")
        let request = ShareRequest(destination: .newConversation(boxID: 7), message: "one", files: [file])

        do {
            try await sender.send(request) { _ in }
            XCTFail("expected a throw")
        } catch {}
        try await sender.send(request) { _ in }
        try await sender.send(ShareRequest(destination: .newConversation(boxID: 7), message: "two",
                                           files: [file])) { _ in }

        XCTAssertEqual(transport.starts, [7])
        XCTAssertEqual(transport.delivered.flatMap(convoIDs), ["new-7-1", "new-7-1", "new-7-1"])
    }

    func test_newConversation_failedStart_isAskedAgainOnRetry() async throws {
        let transport = RecordingTransport()
        transport.failNextStart(with: ShareSendError.failed("asleep"))
        let sender = ShareSender(transport: transport)
        let request = ShareRequest(destination: .newConversation(boxID: 7), message: "hi", files: [])

        do {
            try await sender.send(request) { _ in }
            XCTFail("expected a throw")
        } catch {}
        XCTAssertTrue(transport.delivered.isEmpty)
        try await sender.send(request) { _ in }

        XCTAssertEqual(transport.starts, [7])
    }

    func test_newConversation_anUnansweredStart_isNeverAskedAgain() async throws {
        let transport = RecordingTransport()
        transport.failNextStart(with: ShareSendError.startUnanswered)
        let sender = ShareSender(transport: transport)
        let request = ShareRequest(destination: .newConversation(boxID: 7), message: "hi", files: [])

        for _ in 0..<2 {
            do {
                try await sender.send(request) { _ in }
                XCTFail("expected a throw")
            } catch {
                XCTAssertEqual(error as? ShareSendError, .startUnanswered)
            }
        }
        XCTAssertTrue(transport.starts.isEmpty, "the box may already have started one")

        try await sender.send(ShareRequest(destination: .newConversation(boxID: 9), message: "hi", files: [])) { _ in }
        XCTAssertEqual(transport.starts, [9])
    }

    func test_newConversation_progressNamesTheStartAndTheWake() async throws {
        let transport = RecordingTransport()
        transport.asleepFor = 1
        let sender = ShareSender(transport: transport)
        let steps = ProgressLog()

        try await sender.send(ShareRequest(destination: .newConversation(boxID: 7), message: "hi", files: [])) {
            steps.add($0)
        }

        XCTAssertEqual(steps.all.map(\.step), [.starting, .waking, .posting, .posting])
        XCTAssertEqual(steps.all.map(\.fraction), steps.all.map(\.fraction).sorted())
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ShareProgress] = []
    func add(_ progress: ShareProgress) { lock.lock(); entries.append(progress); lock.unlock() }
    var all: [ShareProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}
