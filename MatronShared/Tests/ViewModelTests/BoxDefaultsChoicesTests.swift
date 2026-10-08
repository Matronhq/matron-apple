import XCTest
@testable import MatronViewModels
import MatronJournal

/// The words Settings ▸ Devices ▸ New sessions shows for a box.
final class BoxDefaultsChoicesTests: XCTestCase {
    func test_summary() {
        XCTAssertEqual(BoxDefaults().summary, "Box default")
        XCTAssertEqual(BoxDefaults(agent: "codex").summary, "Codex · Codex's own model")
        XCTAssertEqual(BoxDefaults(agent: "codex", model: "gpt-5.1-codex", effort: "high").summary,
                       "Codex · gpt-5.1-codex · High")
        XCTAssertEqual(BoxDefaults(agent: "codex", effort: "minimal").summary, "Codex · Codex's own model · Minimal")
        XCTAssertEqual(BoxDefaults(agent: "claude", model: "opus", effort: "high").summary, "Claude · Opus · High")
        XCTAssertEqual(BoxDefaults(agent: "claude").summary, "Claude · Your default model")
        // A model the list doesn't know shows under its own name.
        XCTAssertEqual(BoxDefaults(agent: "claude", model: "claude-opus-4-1").summary, "Claude · claude-opus-4-1")
    }

    func test_choicesFollowTheAgent() {
        XCTAssertEqual(BoxDefaults.agentChoices.map(\.value), [nil, "claude", "codex"])
        let claude = BoxDefaults(agent: "claude")
        XCTAssertEqual(claude.modelChoices, NewChatDefaults.modelChoices)
        XCTAssertEqual(claude.effortChoices.map(\.value), [nil, "low", "medium", "high", "xhigh", "max"])
        let codex = BoxDefaults(agent: "codex")
        XCTAssertEqual(codex.effortChoices.map(\.value), [nil, "minimal", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(codex.effortChoices.first?.label, "Codex default")
        // A stored value outside the list is offered under its own name.
        XCTAssertEqual(BoxDefaults(agent: "claude", model: "claude-opus-4-1").modelChoices.last?.value,
                       "claude-opus-4-1")
        XCTAssertEqual(BoxDefaults(agent: "codex", effort: "max").effortChoices.last?.value, "max")
    }

    func test_codexModelDraft() {
        XCTAssertEqual(BoxDefaults.codexModel(fromDraft: "  GPT-5.1-Codex "), .valid("gpt-5.1-codex"))
        XCTAssertEqual(BoxDefaults.codexModel(fromDraft: "   "), .valid(nil), "blank = Codex default")
        XCTAssertEqual(BoxDefaults.codexModel(fromDraft: "gpt 5"), .invalid)
        XCTAssertEqual(BoxDefaults.codexModel(fromDraft: "-gpt"), .invalid)
        XCTAssertEqual(BoxDefaults.codexModel(fromDraft: String(repeating: "a", count: 65)), .invalid)
    }

    /// Bugbot on PR 332: the editors save the typed Codex id on every way
    /// out of the field, through this.
    func test_codexModelSaveOnLeavingTheField() {
        let codex = BoxDefaults(agent: "codex", model: "gpt-5.1-codex")
        XCTAssertEqual(codex.codexModelSave(draft: " GPT-5.1-Codex "), .unchanged)
        XCTAssertEqual(codex.codexModelSave(draft: "gpt-5.2-codex"), .save("gpt-5.2-codex"))
        XCTAssertEqual(codex.codexModelSave(draft: ""), .save(nil), "emptied = back to Codex default")
        XCTAssertEqual(BoxDefaults(agent: "codex").codexModelSave(draft: "  "), .unchanged)
        XCTAssertEqual(codex.codexModelSave(draft: "gpt 5"), .invalid)
    }
}
