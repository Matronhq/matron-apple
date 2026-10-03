import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class JournalVoiceSenderTests: XCTestCase {
    final class Log: @unchecked Sendable {
        var uploads: [(Data, String)] = []
        var transcripts: [(String, Int)] = []
        var ops: [ClientOp] = []
        var comments: [(itemID: String, body: String, attachments: [TrackerAttachment], action: String?)] = []
    }

    func makeSender(_ log: Log, transcript: Result<String?, Error> = .success("Merge it.")) -> JournalVoiceSender {
        JournalVoiceSender(
            uploadMedia: { data, type in log.uploads.append((data, type)); return "m-1" },
            mediaTranscript: { ref, wait in log.transcripts.append((ref, wait)); return try transcript.get() },
            sendOp: { log.ops.append($0) },
            enqueueComment: { log.comments.append(($0, $1, $2, $3)) })
    }

    func testUploadIsAnAudioBlob() async throws {
        let log = Log()
        let ref = try await makeSender(log).upload(Data("aac".utf8))
        XCTAssertEqual(ref, "m-1")
        XCTAssertEqual(log.uploads.first?.1, "audio/mp4")
    }

    func testTranscriptPassesTheWaitAndSwallowsErrors() async {
        let log = Log()
        let words = await makeSender(log).transcript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertEqual(words, "Merge it.")
        XCTAssertEqual(log.transcripts.first?.1, 8)
        struct Boom: Error {}
        let none = await makeSender(log, transcript: .failure(Boom())).transcript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertNil(none)
    }

    /// The same frame `ComposerViewModel.sendVoiceNote` produces.
    func testAVoiceNoteToAConversationIsAFileSend() async throws {
        let log = Log()
        try await makeSender(log).sendVoiceNote(blobRef: "m-1", size: 9, to: .conversation("c1"))
        guard case .sendMedia(let convoID, let type, let blobRef, let name, let contentType, let size, let caption, let batch, _)? = log.ops.first else {
            return XCTFail("expected a media send")
        }
        XCTAssertEqual(convoID, "c1"); XCTAssertEqual(type, "file"); XCTAssertEqual(blobRef, "m-1")
        XCTAssertEqual(name, "voice-note.m4a"); XCTAssertEqual(contentType, "audio/mp4"); XCTAssertEqual(size, 9)
        XCTAssertNil(caption); XCTAssertNil(batch)
    }

    /// The same comment `ItemDetailViewModel.sendVoiceNote` queues.
    func testAVoiceNoteToAnItemIsAnAttachmentOnlyComment() async throws {
        let log = Log()
        try await makeSender(log).sendVoiceNote(blobRef: "m-1", size: 9, to: .item("it_1"))
        XCTAssertEqual(log.comments.first?.itemID, "it_1")
        XCTAssertEqual(log.comments.first?.body, "")
        XCTAssertEqual(log.comments.first?.attachments,
                       [TrackerAttachment(blobRef: "m-1", mime: "audio/mp4", name: "voice-note.m4a", size: 9)])
        XCTAssertNil(log.comments.first?.action)
    }

    /// The same comment `ItemDetailViewModel.chooseAction` queues.
    func testAnItemActionIsTheLabelAsBodyAndAction() async {
        let log = Log()
        await makeSender(log).sendItemAction(itemID: "it_1", label: "Go")
        XCTAssertEqual(log.comments.first?.body, "Go")
        XCTAssertEqual(log.comments.first?.action, "Go")
        XCTAssertEqual(log.comments.first?.attachments, [])
    }

    func testAPromptReplyIsThePromptReplyOp() async throws {
        let log = Log()
        try await makeSender(log).sendPromptReply(convoID: "c3", seq: 30, choice: "pg", text: nil)
        try await makeSender(log).sendPromptReply(convoID: "c3", seq: 31, choice: nil, text: "Use MySQL.")
        XCTAssertEqual(log.ops, [.promptReply(convoID: "c3", targetSeq: 30, choice: "pg", text: nil),
                                 .promptReply(convoID: "c3", targetSeq: 31, choice: nil, text: "Use MySQL.")])
    }
}
