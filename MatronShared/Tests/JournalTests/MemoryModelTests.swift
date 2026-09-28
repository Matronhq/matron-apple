import XCTest
import MatronModels

final class MemoryModelTests: XCTestCase {
    static let memoryJSON: [String: Any] = [
        "id": "me_0123456789abcdef", "user_id": 1, "name": "avoid-eric-and-fatima", "type": "feedback",
        "description": "Never start sessions on eric or fatima.", "body": "**Why:** reserved.",
        "origin_convo_id": NSNull(), "origin_device_id": NSNull(), "origin_private": false,
        "created_by": "agent", "updated_by": "user",
        "created_at": 1_790_550_000_000, "updated_at": 1_790_560_000_000,
    ]

    func testDecodesEveryField() throws {
        let memory = try XCTUnwrap(Memory(json: Self.memoryJSON))
        XCTAssertEqual(memory.id, "me_0123456789abcdef")
        XCTAssertEqual(memory.name, "avoid-eric-and-fatima")
        XCTAssertEqual(memory.type, .feedback)
        XCTAssertEqual(memory.description, "Never start sessions on eric or fatima.")
        XCTAssertEqual(memory.body, "**Why:** reserved.")
        XCTAssertEqual(memory.createdBy, .agent)
        XCTAssertEqual(memory.updatedBy, .user)
        XCTAssertEqual(memory.createdAt, Date(timeIntervalSince1970: 1_790_550_000))
        XCTAssertEqual(memory.updatedAt, Date(timeIntervalSince1970: 1_790_560_000))
    }

    func testRowsMissingAKeyFieldOrWithAnUnknownTypeDoNotDecode() {
        for key in ["id", "name", "type", "description", "created_at", "updated_at"] {
            var json = Self.memoryJSON
            json.removeValue(forKey: key)
            XCTAssertNil(Memory(json: json), "decoded without \(key)")
        }
        var json = Self.memoryJSON
        json["type"] = "secret"
        XCTAssertNil(Memory(json: json))
    }

    func testAbsentBodyDecodesEmpty() throws {
        var json = Self.memoryJSON
        json.removeValue(forKey: "body")
        XCTAssertEqual(try XCTUnwrap(Memory(json: json)).body, "")
    }

    func testTypeLabelsAreTheWebTrackersWords() {
        XCTAssertEqual(MemoryType.user.label, "About you")
        XCTAssertEqual(MemoryType.feedback.label, "How to work")
        XCTAssertEqual(MemoryType.project.label, "Project")
        XCTAssertEqual(MemoryType.reference.label, "Reference")
        XCTAssertEqual(MemoryType.pickerOrder.first, .feedback, "the journal's default on create leads the picker")
        XCTAssertEqual(Set(MemoryType.pickerOrder), Set(MemoryType.allCases))
    }

    // MARK: - Validation, mirroring the journal's src/memories.js

    func testNameRule() {
        for good in ["a", "0", "avoid-eric", "a-", "fable-maxed-boxes-can-use-opus", String(repeating: "a", count: 64)] {
            XCTAssertTrue(MemoryRules.isValidName(good), good)
        }
        for bad in ["", "-a", "Avoid", "avoid_eric", "avoid eric", "é", "a.b", String(repeating: "a", count: 65)] {
            XCTAssertFalse(MemoryRules.isValidName(bad), bad)
        }
    }

    func testFormErrorOrderAndMessages() {
        let ok = (name: "avoid-eric", description: "Never start sessions on eric.", body: "")
        XCTAssertNil(MemoryRules.formError(name: ok.name, description: ok.description, body: ok.body))
        XCTAssertEqual(MemoryRules.formError(name: "Bad Name", description: "", body: ""),
                       "Name must be lowercase letters, digits and dashes (up to 64), starting with a letter or digit.")
        XCTAssertEqual(MemoryRules.formError(name: ok.name, description: "   ", body: ""), "Description is required.")
        XCTAssertEqual(MemoryRules.formError(name: ok.name, description: String(repeating: "x", count: 201), body: ""),
                       "Description must be at most 200 characters.")
        XCTAssertEqual(MemoryRules.formError(name: ok.name, description: "two\nlines", body: ""),
                       "Description must be a single line.")
        XCTAssertEqual(MemoryRules.formError(name: ok.name, description: ok.description,
                                             body: String(repeating: "x", count: 8193)),
                       "Notes must be at most 8 KB.")
    }

    func testDescriptionIsMeasuredTrimmedAndInUTF16UnitsLikeTheJournal() {
        // 200 characters plus surrounding whitespace: the journal trims first.
        XCTAssertNil(MemoryRules.formError(name: "a", description: "  " + String(repeating: "x", count: 200) + "\n", body: ""))
        // 100 emoji are 200 UTF-16 units (JavaScript `.length`) — accepted;
        // one more is over.
        XCTAssertNil(MemoryRules.formError(name: "a", description: String(repeating: "😀", count: 100), body: ""))
        XCTAssertNotNil(MemoryRules.formError(name: "a", description: String(repeating: "😀", count: 101), body: ""))
    }

    func testEveryJournalLineBreakingCharacterIsRefused() {
        for scalar in [0x00, 0x09, 0x0D, 0x1F, 0x7F, 0x85, 0x9F, 0x2028, 0x2029] {
            let c = String(Character(Unicode.Scalar(UInt32(scalar))!))
            XCTAssertEqual(MemoryRules.formError(name: "a", description: "one\(c)line", body: ""),
                           "Description must be a single line.", String(format: "U+%04X", scalar))
        }
    }

    func testBodyCapIsUTF8Bytes() {
        // "é" is 2 bytes: 4096 of them is exactly 8192 bytes.
        XCTAssertNil(MemoryRules.formError(name: "a", description: "d", body: String(repeating: "é", count: 4096)))
        XCTAssertNotNil(MemoryRules.formError(name: "a", description: "d", body: String(repeating: "é", count: 4097)))
    }
}
