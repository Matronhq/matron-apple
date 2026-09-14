#if os(macOS)
import SwiftUI
import XCTest
import MatronModels
import MatronDesignSystem
@testable import MatronMac

/// Chrome-without-VM snapshot, same pattern as `MacSummariesPanelSnapshotTests`:
/// `MacItemsPaneChrome` wraps `ItemsListView` with static `Model` data, so
/// the test needs no `ItemsPanelViewModel`/`AppDependencies`/`UserSession`.
final class MacItemsPaneSnapshotTests: XCTestCase {
    @MainActor
    func testPaneListPopulated() {
        let items = [
            TrackerItem(id: "q", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", originConvoID: "c1", commentCount: 1),
            TrackerItem(id: "t", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module", originConvoID: "c1"),
        ]
        let model = ItemsListView.Model(needsYou: [items[0]], tasks: [items[1]], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: false)
        let view = MacItemsPaneChrome(title: "Tasks & decisions", onClose: {}) {
            ItemsListView(model: model, scope: .constant(.convo("c1")), convoID: "c1", thumbnail: { _ in nil },
                          onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
        }
        .frame(width: 400, height: 500)
        assertVariants(of: view, named: "MacItemsPane_list")
    }
}
#endif
