import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Pins the pure `ItemInlineCard.attachmentLine` helper that renders one
/// caption line per attachment under a `commented`/`reopened` reply body.
final class ItemInlineCardTests: XCTestCase {
    func test_audioWithTranscript_showsNameAndTranscript() {
        let a = TrackerAttachment(blobRef: "b1", mime: "audio/m4a", name: "Voice 1.m4a", size: 1, transcript: "use option A")
        XCTAssertEqual(ItemInlineCard.attachmentLine(a), "Voice note: Voice 1.m4a — use option A")
    }

    func test_audioPendingOnTheJournal_saysTranscribing() {
        let a = TrackerAttachment(blobRef: "b3", mime: "audio/m4a", name: "Voice 3.m4a", size: 1, transcript: nil, transcriptStatus: "pending")
        XCTAssertEqual(ItemInlineCard.attachmentLine(a), "Voice note: Voice 3.m4a — transcribing…")
    }

    func test_transcriptStatus_roundTripsAndFlagsFailure() {
        let a = TrackerAttachment(json: ["blob_ref": "b", "mime": "audio/mp4", "name": "v", "size": 1, "transcript_status": "failed"])
        XCTAssertEqual(a?.transcriptStatus, "failed")
        XCTAssertEqual(a?.transcriptionFailed, true)
        XCTAssertEqual(a?.json["transcript_status"] as? String, "failed")
        let done = TrackerAttachment(blobRef: "b", mime: "audio/mp4", name: "v", size: 1, transcript: "hi", transcriptStatus: "failed")
        XCTAssertFalse(done.transcriptionFailed) // words win
    }

    func test_audioWithoutTranscript_showsNameOnly() {
        let a = TrackerAttachment(blobRef: "b2", mime: "audio/m4a", name: "Voice 2.m4a", size: 1, transcript: nil)
        XCTAssertEqual(ItemInlineCard.attachmentLine(a), "Voice note: Voice 2.m4a")
    }

    func test_image_showsAttachmentPrefix() {
        let a = TrackerAttachment(blobRef: "b3", mime: "image/png", name: "screenshot.png", size: 1)
        XCTAssertEqual(ItemInlineCard.attachmentLine(a), "Attachment: screenshot.png")
    }

    func test_emptyName_fallsBackToGenericAttachment() {
        let a = TrackerAttachment(blobRef: "b4", mime: "application/pdf", name: "", size: 1)
        XCTAssertEqual(ItemInlineCard.attachmentLine(a), "Attachment: attachment")
    }
}
