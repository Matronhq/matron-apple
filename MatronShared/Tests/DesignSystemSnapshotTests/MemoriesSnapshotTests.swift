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

    // MARK: On your boxes

    private var boxesSection: LocalMemoriesSection {
        func ref(_ path: String) -> LocalMemoryRef { LocalMemoryRef(boxID: 1, path: path) }
        return LocalMemoriesSection(
            groups: [
                .init(id: "yearbook-app", title: "yearbook-app", path: "~/yearbook-app", countLine: "128 on 3 boxes",
                      isExpanded: true,
                      chips: [.init(boxID: 1, name: "ang", count: 46, isSelected: true),
                              .init(boxID: 2, name: "bev", count: 38, isSelected: false),
                              .init(boxID: 3, name: "greg", count: 44, isSelected: false)],
                      rows: [
                        .init(ref: ref("/c"), title: "CLAUDE.md", summary: "Repo instructions · 30 KB"),
                        .init(ref: ref("/a"), title: "Psalm needs the box to itself",
                              summary: "dies silently next to jest or a bloated php-fpm; rerun alone", isSelected: true),
                        .init(ref: ref("/b"), title: "Merge train: single CI run",
                              summary: "one CircleCI run per batch, not per PR", overlap: "merge-train-owns-merges"),
                      ],
                      hiddenCount: 43, selectedBoxName: "ang"),
                .init(id: "matron-bridge", title: "matron-bridge", path: "~/matron-bridge", countLine: "9 on 3 boxes",
                      isExpanded: false, chips: [], rows: []),
                .init(id: LocalMemoryRepoGroup.globalID, title: "Global CLAUDE.md", path: "~/.claude/CLAUDE.md",
                      countLine: "3 boxes", isExpanded: false, chips: [], rows: []),
            ],
            hasLoaded: true, isLoading: true, loadingBoxes: ["henry"], asleepBoxes: ["pat", "terry"],
            outdatedBoxes: ["mavis"])
    }

    private let noActions = LocalMemoriesSectionRows.Actions(toggleGroup: { _ in }, selectBox: { _, _ in },
                                                             showAll: { _ in }, open: { _ in })

    func testListWithTheBoxesSection() {
        let model = MemoriesListView.Model(memories: memories, isSupported: true, isLoading: false)
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now,
                                            local: boxesSection, localActions: noActions)
            .frame(width: 380, height: 760), named: "memories-list-boxes")
    }

    /// An older journal must not hide the boxes' own memories.
    func testListWithTheBoxesSectionOnAnUnsupportedJournal() {
        let model = MemoriesListView.Model(memories: nil, isSupported: false, isLoading: false)
        assertVariants(of: MemoriesListView(model: model, onSelect: { _ in }, onNew: {}, onRefresh: {}, now: now,
                                            local: boxesSection, localActions: noActions)
            .frame(width: 380, height: 620), named: "memories-list-boxes-unsupported")
    }

    func testLocalMemoryDetail() {
        let detail = LocalMemoryDetail(
            boxName: "ang", title: "Merge train: single CI run", repoTitle: "yearbook-app",
            shortPath: "~/.claude/projects/-home-danbarker-yearbook-app/memory/merge-train-single-ci-run.md",
            type: "project", modifiedAt: Date(timeIntervalSince1970: 1_790_500_000), isMemory: true,
            overlap: "merge-train-owns-merges",
            text: .loaded("---\nname: merge-train-single-ci-run\ndescription: one CircleCI run per batch\n---\n\nThe merge train runs **one** CircleCI run per batch, not one per PR.\n\n**Why:** credits.\n\n**How to apply:** queue the PR and wait for the batch."))
        assertVariants(of: LocalMemoryDetailView(model: detail, onRetry: {}, onOpenJournalMemory: { _ in })
            .frame(width: 460, height: 520), named: "local-memory-detail")
    }

    func testLocalMemoryDetailFailed() {
        let detail = LocalMemoryDetail(boxName: "ang", title: "CLAUDE.md", repoTitle: "yearbook-app",
                                       shortPath: "~/yearbook-app/CLAUDE.md", isMemory: false,
                                       text: .failed("The box is asleep or offline."))
        assertVariants(of: LocalMemoryDetailView(model: detail, onRetry: {})
            .frame(width: 460, height: 300), named: "local-memory-detail-failed")
    }

    func testLocalMemoryDetailLogic() {
        XCTAssertEqual(LocalMemoryDetailView.withoutFrontmatter("---\nname: x\n---\n\nBody\n---\nmore"), "Body\n---\nmore")
        XCTAssertEqual(LocalMemoryDetailView.withoutFrontmatter("# Title\n---\nrest"), "# Title\n---\nrest",
                       "a rule further down is not frontmatter")
        XCTAssertEqual(LocalMemoryDetailView.withoutFrontmatter("---\nname: x\nnever closed"), "---\nname: x\nnever closed")
        XCTAssertEqual(LocalMemoryDetailView.withoutFrontmatter("---\nname: x\n---\n"), "---\nname: x\n---\n",
                       "a file that is only frontmatter still shows something")
        XCTAssertEqual(LocalMemoriesSection.sizeText(590), "590 B")
        XCTAssertEqual(LocalMemoriesSection.sizeText(1203), "1.2 KB")
        XCTAssertEqual(LocalMemoriesSection.sizeText(30878), "30 KB")
        XCTAssertEqual(LocalMemoriesSectionRows.waitingLine(["henry", "mavis"]), "Waiting for henry, mavis…")
        let file = LocalMemoryDetail(boxName: "ang", title: "CLAUDE.md", repoTitle: "", shortPath: "/srv/app/CLAUDE.md",
                                     isMemory: false, text: .loading)
        XCTAssertEqual(LocalMemoryDetailView.metaLine(file), "/srv/app/CLAUDE.md")
    }
}
