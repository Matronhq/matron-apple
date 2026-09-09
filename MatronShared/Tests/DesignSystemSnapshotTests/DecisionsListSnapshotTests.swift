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
}
