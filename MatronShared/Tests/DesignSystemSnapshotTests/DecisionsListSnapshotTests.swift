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

    /// A fixed "now" (2026-02-02T02:13:20Z) so the Closed rows' "Answered
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

    /// A closed item with no `resolution` at all (the journal doesn't
    /// guarantee one is always set) falls back to "Closed · <age>" rather
    /// than `nil` — review, 2026-09-29: a `nil` caption used to render
    /// nothing at all, making the row indistinguishable from an open item.
    func testClosedCaptionFallsBackToClosedWhenResolutionIsNil() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let closedNoResolution = TrackerItem(id: "it_1", num: 1, kind: .decision, state: .closed, title: "T",
                                             originConvoID: "c1", closedAt: now.addingTimeInterval(-3600))
        // `RelativeDateTimeFormatter`'s exact wording ("1h ago" vs "1 hr
        // ago") depends on the locale/OS version running the test, so this
        // only pins the shape — a "Closed" prefix plus SOME non-empty
        // relative-time text — never the formatter's literal output.
        let caption = ItemGlyph.closedCaption(closedNoResolution, now: now)
        XCTAssertNotNil(caption)
        XCTAssertTrue(caption?.hasPrefix("Closed \u{00B7} ") ?? false, "expected a \"Closed · <age>\" caption, got \(caption ?? "nil")")
        let age = caption?.dropFirst("Closed \u{00B7} ".count) ?? ""
        XCTAssertFalse(age.isEmpty, "the relative-time portion must not be empty")

        let open = TrackerItem(id: "it_2", num: 2, kind: .decision, title: "T", originConvoID: "c1")
        XCTAssertNil(ItemGlyph.closedCaption(open, now: now), "never a caption for an open item")
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

    /// The Closed tab: a mix of answered/decided/reversed rows (each
    /// showing "<Resolution> · <relative time>") and a "Show more" row.
    /// The second row was closed by an agent two hours ago but last
    /// answered by the user thirty hours ago: its caption shows the
    /// thirty, the time the tab is ordered by.
    func testClosedTab() {
        let lateClose = TrackerItem(id: "d2", num: 19, kind: .decision, state: .closed, resolution: .decided,
                                    title: "Use SQLite for the cache", originConvoID: "c2",
                                    createdAt: .init(timeIntervalSince1970: 1_760_000_000),
                                    updatedAt: Self.now.addingTimeInterval(-2 * 3600),
                                    closedAt: Self.now.addingTimeInterval(-2 * 3600),
                                    lastUserInputAt: Self.now.addingTimeInterval(-30 * 3600))
        let rows: [DecisionsListView.Row] = [
            .init(item: decided("d1", num: 20, kind: .question, title: "Which auth library?", origin: "c1",
                                resolution: .answered, closedHoursAgo: 2), originTitle: "auth refactor"),
            .init(item: lateClose, originTitle: nil),
            .init(item: decided("d3", num: 18, kind: .decision, title: "Drop the legacy importer", origin: "c1",
                                resolution: .reversed, closedHoursAgo: 200), originTitle: "auth refactor"),
        ]
        let model = DecisionsListView.Model(
            rows: [.init(item: t("q1", num: 12, kind: .question, title: "Which auth library?", origin: "c1"), originTitle: nil)],
            closed: rows, closedTotalCount: 5, tab: .closed, hasMoreClosed: true,
            isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_closedTab")
    }

    /// The Closed tab with nothing closed yet.
    func testClosedTabEmpty() {
        let model = DecisionsListView.Model(rows: [], tab: .closed, isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_closedTabEmpty")
    }

    func testTabLabels() {
        XCTAssertEqual(ForYouTab.allCases.map(\.title), ["Needs you", "Done"])
        XCTAssertEqual(DecisionsListView.closedEmptyTitle, "Nothing done yet")
    }

    func testClosedCaptionUsesTheGivenTime() {
        let item = decided("d1", num: 20, kind: .question, title: "x", origin: "c1", resolution: .answered, closedHoursAgo: 2)
        XCTAssertEqual(ItemGlyph.closedCaption(item, now: Self.now), "Answered \u{00B7} 2h ago")
        XCTAssertEqual(ItemGlyph.closedCaption(item, at: Self.now.addingTimeInterval(-5 * 3600), now: Self.now),
                       "Answered \u{00B7} 5h ago")
    }

    func testDecisionsListWithAMissionChip() {
        let model = DecisionsListView.Model(rows: [
            .init(item: TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1",
                                    missionID: "ms_1", missionNum: 61),
                  originTitle: "box-2 · Session"),
            .init(item: TrackerItem(id: "it_2", num: 65, kind: .decision, awaiting: .user,
                                    title: "Unfiled decision", originConvoID: "c2"),
                  originTitle: "box-3 · Other"),
        ], isSupported: true, isRefreshing: false)
        assertVariants(of: DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in },
                                             onRefresh: {}).frame(width: 380, height: 260),
                       named: "decisions-mission-chip")
    }

    // MARK: - For you

    /// The list is "For you" now: it holds questions, things to read and
    /// secret requests, not only decisions.
    func testForYouCopy() {
        XCTAssertEqual(DecisionsListView.title, "For you")
        XCTAssertEqual(DecisionsListView.emptyTitle, "Nothing needs you")
        XCTAssertEqual(DecisionsListView.emptyDescription,
                       "Questions, things to read and secret requests from every conversation appear here.")
    }

    /// A notice is something to read: the eye glyph, a lighter row, and
    /// "To read" where a question says "Needs you".
    func testNoticeGlyphAndLabel() {
        XCTAssertEqual(ItemGlyph.symbol(.notice), "eye")
        XCTAssertEqual(ItemGlyph.label(.notice), "To read")
        let n = TrackerItem(id: "it_1", num: 70, kind: .notice, awaiting: .user, title: "Deploy finished",
                            originConvoID: "c1", actions: ["Seen"])
        XCTAssertEqual(ItemRow.accessibilityLabel(for: n), "To read 70, Deploy finished, needs you")
    }

    /// A notice row beside a question: lighter title, eye glyph, and its
    /// one-tap Seen button.
    func testNoticeRow() {
        let model = DecisionsListView.Model(rows: [
            .init(item: TrackerItem(id: "it_1", num: 70, kind: .notice, awaiting: .user,
                                    title: "Deploy finished: 3 warnings", originConvoID: "c1",
                                    updatedAt: Self.now, actions: ["Seen"]),
                  originTitle: "box-2 · Release"),
            .init(item: t("q1", num: 12, kind: .question, title: "Which auth library?", origin: "c1"),
                  originTitle: "auth refactor"),
        ], isSupported: true, isRefreshing: false)
        assertVariants(of: view(model), named: "DecisionsList_notice")
    }
}
