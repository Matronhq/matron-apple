import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// App shell (spec §2): the cross-conversation "what needs you" list. The
/// Mac harness hosts views in a window (`MacSnapshotHost`), so the populated
/// baseline pins the `List` rows as well as the chrome. Empty and
/// unsupported states render fully.
@MainActor
final class DecisionsListSnapshotTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind, title: String, origin: String) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, awaiting: .user, rank: Double(num), title: title, body: "",
                    originConvoID: origin, createdAt: .init(timeIntervalSince1970: 1_770_000_000),
                    updatedAt: .init(timeIntervalSince1970: 1_770_000_000 + Double(num)))
    }

    /// A fixed "now" (2026-02-02T02:13:20Z) so the Decided rows' "Answered
    /// · 2h ago" captions render deterministically.
    private static let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func decided(_ id: String, num: Int, kind: ItemKind, title: String, origin: String,
                         resolution: ItemResolution, closedHoursAgo: Double) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: .closed, resolution: resolution, title: title, body: "",
                    originConvoID: origin, createdAt: .init(timeIntervalSince1970: 1_760_000_000),
                    updatedAt: Self.now.addingTimeInterval(-closedHoursAgo * 3600),
                    closedAt: Self.now.addingTimeInterval(-closedHoursAgo * 3600))
    }

    private func view(_ model: DecisionsListView.Model) -> some View {
        DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in }, onRefresh: {}, now: Self.now)
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

    /// The Decided section collapsed, showing only its header + count —
    /// its default state (Dan, 2026-09-29).
    func testDecidedSectionCollapsed() {
        let model = DecisionsListView.Model(
            rows: [.init(item: t("q1", num: 12, kind: .question, title: "Which auth library?", origin: "c1"), originTitle: "auth refactor")],
            decided: [], decidedTotalCount: 3, isDecidedExpanded: false, hasMoreDecided: false,
            isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_decidedCollapsed")
    }

    /// Expanded, with a mix of answered/decided/reversed rows (each
    /// showing "<Resolution> · <relative time>") and a "Show more" row.
    /// `rows: []` also doubles as the inline-empty-state coverage (Dan,
    /// 2026-09-29, review): no open items, so the inline "Nothing needs
    /// you" row renders ABOVE the (expanded) Decided section rather than
    /// the full-screen placeholder hiding it — see `testEmptyOpenDecidedCollapsed`
    /// for the collapsed pairing.
    func testDecidedSectionExpanded() {
        let rows: [DecisionsListView.Row] = [
            .init(item: decided("d1", num: 20, kind: .question, title: "Which auth library?", origin: "c1",
                                resolution: .answered, closedHoursAgo: 2), originTitle: "auth refactor"),
            .init(item: decided("d2", num: 19, kind: .decision, title: "Use SQLite for the cache", origin: "c2",
                                resolution: .decided, closedHoursAgo: 30), originTitle: nil),
            .init(item: decided("d3", num: 18, kind: .decision, title: "Drop the legacy importer", origin: "c1",
                                resolution: .reversed, closedHoursAgo: 200), originTitle: "auth refactor"),
        ]
        let model = DecisionsListView.Model(
            rows: [], decided: rows, decidedTotalCount: 5, isDecidedExpanded: true, hasMoreDecided: true,
            isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_decidedExpanded")
    }

    /// No open items AND the Decided section collapsed: the inline
    /// "Nothing needs you" row sits above just the section header (Dan,
    /// 2026-09-29, review item 4) — distinct from `testEmpty`, where there
    /// is nothing decided either and the FULL-SCREEN placeholder shows
    /// instead (no List, no header at all).
    func testEmptyOpenDecidedCollapsed() {
        let model = DecisionsListView.Model(
            rows: [], decided: [], decidedTotalCount: 4, isDecidedExpanded: false, hasMoreDecided: false,
            isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_emptyOpenDecidedCollapsed")
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
