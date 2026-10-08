import XCTest
import MatronModels
@testable import MatronEvents

final class MemoryMarkerEventTests: XCTestCase {
    func testParsesTheFullPayload() throws {
        let marker = try XCTUnwrap(MemoryMarkerEvent.parse(payload: [
            "memory_id": "me_1", "name": "avoid-atlas", "type": "feedback",
            "description": "Never start sessions on atlas.", "action": "saved", "created": true, "by": "agent",
        ]))
        XCTAssertEqual(marker, MemoryMarkerEvent(memoryID: "me_1", action: .saved, created: true, by: .agent,
                                                 name: "avoid-atlas", type: .feedback,
                                                 description: "Never start sessions on atlas."))
    }

    /// Across a privacy boundary the journal withholds name, type and
    /// description; the marker still parses.
    func testParsesTheRedactedPayload() throws {
        let marker = try XCTUnwrap(MemoryMarkerEvent.parse(payload: [
            "memory_id": "me_1", "action": "deleted", "created": false, "by": "user",
        ]))
        XCTAssertNil(marker.name)
        XCTAssertEqual(marker.noticeText, "🧠 You deleted a memory")
    }

    func testRejectsAPayloadWithoutAnIDOrAKnownAction() {
        XCTAssertNil(MemoryMarkerEvent.parse(payload: ["action": "saved"]))
        XCTAssertNil(MemoryMarkerEvent.parse(payload: ["memory_id": "me_1", "action": "exploded"]))
    }

    func testNoticeTextIsTheWebCopy() {
        XCTAssertEqual(MemoryMarkerEvent(memoryID: "me_1", action: .saved, created: true, by: .agent,
                                         name: "avoid-atlas", description: "Never start sessions on atlas.").noticeText,
                       "🧠 Agent saved a memory · avoid-atlas — Never start sessions on atlas.")
        XCTAssertEqual(MemoryMarkerEvent(memoryID: "me_1", action: .saved, created: false, by: .user,
                                         name: "avoid-atlas", description: "").noticeText,
                       "🧠 You updated a memory · avoid-atlas")
        // A delete names the memory but not its (gone) rule.
        XCTAssertEqual(MemoryMarkerEvent(memoryID: "me_1", action: .deleted, by: .agent,
                                         name: "avoid-atlas", description: "Never.").noticeText,
                       "🧠 Agent deleted a memory · avoid-atlas")
    }
}
