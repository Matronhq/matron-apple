import XCTest
@testable import MatronModels

final class ThreadImageAttachmentsTests: XCTestCase {
    private func att(_ ref: String, _ mime: String) -> TrackerAttachment {
        TrackerAttachment(blobRef: ref, mime: mime, name: "\(ref).file", size: 1)
    }

    private func comment(_ id: String, _ attachments: [TrackerAttachment]) -> TrackerComment {
        TrackerComment(id: id, itemID: "it_1", author: .user, body: "", attachments: attachments)
    }

    func test_itemImagesFirst_thenCommentImagesInThreadOrder_skippingOtherFiles() {
        let item = TrackerItem(id: "it_1", num: 1, kind: .task, title: "t",
                               attachments: [att("a", "image/png"), att("log", "text/plain")], originConvoID: "c1")
        let comments = [
            comment("c1", [att("voice", "audio/m4a"), att("b", "image/jpeg")]),
            comment("c2", []),
            comment("c3", [att("c", "image/heic"), att("d", "image/png")]),
        ]
        XCTAssertEqual(item.threadImageAttachments(comments: comments).map(\.blobRef), ["a", "b", "c", "d"])
    }

    func test_noImages_isEmpty() {
        let item = TrackerItem(id: "it_1", num: 1, kind: .task, title: "t",
                               attachments: [att("log", "text/plain")], originConvoID: "c1")
        XCTAssertTrue(item.threadImageAttachments(comments: []).isEmpty)
    }
}
