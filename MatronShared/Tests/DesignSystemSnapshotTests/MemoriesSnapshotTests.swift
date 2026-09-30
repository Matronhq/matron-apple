import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

/// The Memories list and editor (spec 2026-09-27 memories; wording from
/// matron-web PR #38).
final class MemoriesSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_560_000)

    private var memories: [Memory] {
        [
            Memory(id: "me_1", name: "avoid-eric-and-fatima", type: .feedback,
                   description: "Start sessions on eric or fatima only as a last resort.",
                   body: "**Why:** Dan keeps them for his own work.\n**How to apply:** pick another box first.",
                   createdBy: .agent, updatedBy: .agent,
                   createdAt: now.addingTimeInterval(-3 * 86_400), updatedAt: now.addingTimeInterval(-2 * 3_600)),
            Memory(id: "me_2", name: "fable-maxed-boxes-can-use-opus", type: .user,
                   description: "A box at 100% Fable can still take Opus 5.5 sessions.",
                   createdBy: .user, updatedBy: .user,
                   createdAt: now.addingTimeInterval(-5 * 60), updatedAt: now.addingTimeInterval(-5 * 60)),
        ]
    }

    // MARK: Pure logic

    func testRowMetaLines() {
        XCTAssertEqual(MemoryRowView.updatedLine(memories[0], now: now), "Updated 2 hours ago by an agent")
        XCTAssertEqual(MemoryRowView.updatedLine(memories[1], now: now), "Updated 5 minutes ago by you")
        XCTAssertEqual(MemoryRowView.historyLine(memories[0], now: now),
                       "Saved 3 days ago by an agent, updated 2 hours ago by an agent")
        XCTAssertEqual(MemoryRowView.relative(now.addingTimeInterval(-10), now: now), "just now")
    }

    func testEmptyStateWording() {
        XCTAssertEqual(MemoriesListView.emptyTitle, "No memories yet")
        XCTAssertEqual(MemoriesListView.emptyHint,
                       "Tell an agent a rule about how you want work done and it saves one here, or add one yourself.")
    }

    func testEditorDraftStartsFromTheMemoryOrBlankWithTheDefaultType() {
        XCTAssertEqual(MemoryEditorView.Draft(memory: memories[1]),
                       MemoryEditorView.Draft(name: "fable-maxed-boxes-can-use-opus", type: .user,
                                              description: "A box at 100% Fable can still take Opus 5.5 sessions.",
                                              body: ""))
        XCTAssertEqual(MemoryEditorView.Draft().type, .feedback)
    }

    // MARK: Snapshots

    func testRow() {
        assertVariants(of: MemoryRowView(memory: memories[0], now: now).frame(width: 380).padding(), named: "memory-row")
    }

    func testList() {
        let model = MemoriesListView.Model(memories: memories, isSupported: true, isLoading: false)
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now)
            .frame(width: 380, height: 360), named: "memories-list")
    }

    func testListEmpty() {
        let model = MemoriesListView.Model(memories: [], isSupported: true, isLoading: false)
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now)
            .frame(width: 380, height: 320), named: "memories-empty")
    }

    func testListUnsupported() {
        let model = MemoriesListView.Model(memories: nil, isSupported: false, isLoading: false)
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now)
            .frame(width: 380, height: 280), named: "memories-unsupported")
    }

    func testListStaleAfterAFailedRefresh() {
        let model = MemoriesListView.Model(memories: memories, isSupported: true, isLoading: false, loadError: "offline")
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now)
            .frame(width: 380, height: 360), named: "memories-stale")
    }

    func testEditorForAnExistingMemory() {
        assertVariants(of: MemoryEditorView(memory: memories[0], onSave: { _ in nil }, onDelete: { nil }, now: now)
            .frame(width: 420, height: 720), named: "memory-editor")
    }

    func testEditorForANewMemory() {
        assertVariants(of: MemoryEditorView(memory: nil, onSave: { _ in nil }, onDelete: { nil }, now: now)
            .frame(width: 420, height: 720), named: "memory-editor-new")
    }
}
