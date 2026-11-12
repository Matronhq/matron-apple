import XCTest
@testable import MatronEvents

final class AskUserEventTests: XCTestCase {
    func test_optionValueDefaultsToLabel() {
        // Journal prompt and permission options are plain labels: the
        // reply sends the label text, so an option with no `value` must
        // answer with its label.
        XCTAssertEqual(AskUserEvent.Option(id: "a", label: "main.rs").value, "main.rs")
        XCTAssertEqual(AskUserEvent.Option(id: "a", label: "Cancel", value: "cancel:0").value, "cancel:0")
    }

    func test_initDefaultsToTextReplyChannel() {
        let evt = AskUserEvent(prompt: "x", kind: .text, expiresAt: nil)
        XCTAssertEqual(evt.replyChannel, .textReply)
        XCTAssertNil(evt.queuedReleasePromptID)
        XCTAssertNil(evt.queuedEdit)
    }
}
