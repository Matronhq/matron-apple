import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// App shell (spec §2): the cross-conversation "what needs you" list. Like
/// `ItemsListSnapshotTests`, `List` rows don't populate under the
/// `NSHostingView.fittingSize` harness, so the populated baseline pins the
/// chrome (Mac header + refresh button) while the row rendering is already
/// pinned by `ItemsListSnapshotTests.testRowVariants` (`ItemRow` with an
/// origin subtitle). Empty and unsupported states render fully.
@MainActor
final class DecisionsListSnapshotTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind, title: String, origin: String) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, awaiting: .user, rank: Double(num), title: title, body: "",
                    originConvoID: origin, createdAt: .init(timeIntervalSince1970: 1_770_000_000),
                    updatedAt: .init(timeIntervalSince1970: 1_770_000_000 + Double(num)))
    }

    private func view(_ model: DecisionsListView.Model) -> some View {
        DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in }, onRefresh: {})
            .frame(width: 360, height: 400)
    }

    func testPopulated() {
        let model = DecisionsListView.Model(
            rows: [
                .init(item: t("q1", num: 12, kind: .question, title: "Which auth library?", origin: "c1"), originTitle: "auth refactor"),
                .init(item: t("d1", num: 11, kind: .decision, title: "Use SQLite for the cache", origin: "c2"), originTitle: nil),
            ],
            isSupported: true, isRefreshing: true)
        assertVariants(of: view(model), named: "DecisionsList_populated")
    }

    func testEmpty() {
        assertVariants(of: view(.init(rows: [], isSupported: true, isRefreshing: false)), named: "DecisionsList_empty")
    }

    func testUnsupported() {
        assertVariants(of: view(.init(rows: [], isSupported: false, isRefreshing: false)), named: "DecisionsList_unsupported")
    }

    func testRowsAreIdentifiedByItemID() {
        let row = DecisionsListView.Row(item: t("q1", num: 1, kind: .question, title: "x", origin: "c1"), originTitle: nil)
        XCTAssertEqual(row.id, "q1")
    }

    /// Numbers are one namespace across items, missions and milestones, so
    /// the chip is a bare `#N` with the mission glyph — never "Mission 61".
    func testMissionChipTextOnlyAppearsForAnAssignedItem() {
        let assigned = TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                   title: "Which order?", originConvoID: "c1", missionID: "ms_1", missionNum: 61)
        XCTAssertEqual(ItemRow.missionChipText(for: assigned), "#61")
        let unassigned = TrackerItem(id: "it_2", num: 65, kind: .task, title: "Unfiled", originConvoID: "c1")
        XCTAssertNil(ItemRow.missionChipText(for: unassigned))
    }

    /// `.accessibilityElement(children: .combine)` followed by an explicit
    /// `.accessibilityLabel(...)` on the same container REPLACES the
    /// auto-generated combined text — a child's own `.accessibilityLabel`
    /// (e.g. one set directly on the mission chip) never merges in. So the
    /// mission chip must be folded into `ItemRow`'s own label string, and
    /// this pins that rule without rendering.
    func testAccessibilityLabelFoldsInTheMissionChip() {
        let assigned = TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                   title: "Which order?", originConvoID: "c1", missionID: "ms_1", missionNum: 61)
        XCTAssertEqual(ItemRow.accessibilityLabel(for: assigned), "Question 64, Which order?, needs you, mission #61")
        let unassigned = TrackerItem(id: "it_2", num: 65, kind: .task, title: "Unfiled", originConvoID: "c1")
        XCTAssertEqual(ItemRow.accessibilityLabel(for: unassigned), "Task 65, Unfiled")
    }

    func testDecisionsListWithAMissionChip() {
        let model = DecisionsListView.Model(rows: [
            .init(item: TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1",
                                    missionID: "ms_1", missionNum: 61),
                  originTitle: "dev-2 · Session"),
            .init(item: TrackerItem(id: "it_2", num: 65, kind: .decision, awaiting: .user,
                                    title: "Unfiled decision", originConvoID: "c2"),
                  originTitle: "dev-3 · Other"),
        ], isSupported: true, isRefreshing: false)
        assertVariants(of: DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in },
                                             onRefresh: {}).frame(width: 380, height: 260),
                       named: "decisions-mission-chip")
    }
}
