import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

@MainActor
final class ItemsListSnapshotTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind, awaiting: ItemAwaiting?, title: String, state: ItemState = .open, comments: Int = 0, image: Bool = false) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil, awaiting: awaiting, rank: Double(num),
                    title: title, body: "Some body text that previews on one line and then gets cut off", originConvoID: "c1",
                    createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000),
                    closedAt: state == .closed ? .init(timeIntervalSince1970: 1_770_000_100) : nil, commentCount: comments, hasImage: image)
    }

    func testPopulatedList() {
        let model = ItemsListView.Model(
            needsYou: [t("q1", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", comments: 2, image: true)],
            tasks: [t("t1", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module"), t("t2", num: 14, kind: .task, awaiting: .agent, title: "Write the migration")],
            decisions: [t("d1", num: 11, kind: .decision, awaiting: nil, title: "Use SQLite for the cache")],
            done: [t("x1", num: 3, kind: .task, awaiting: nil, title: "Set up CI", state: .closed)],
            originTitles: [:], isSupported: true, isRefreshing: false)
        let view = ItemsListView(model: model, scope: .constant(.convo("c1")), convoID: "c1", thumbnail: { _ in nil },
                                 onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
            .frame(width: 360, height: 560)
        assertVariants(of: view, named: "ItemsList_populated")
    }

    func testEmptyAndUnsupported() {
        let empty = ItemsListView.Model(needsYou: [], tasks: [], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: false)
        assertVariants(of: ItemsListView(model: empty, scope: .constant(.all), convoID: "c1", thumbnail: { _ in nil }, onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in }).frame(width: 360, height: 300), named: "ItemsList_empty")
        var unsupported = empty; unsupported.isSupported = false
        assertVariants(of: ItemsListView(model: unsupported, scope: .constant(.all), convoID: "c1", thumbnail: { _ in nil }, onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in }).frame(width: 360, height: 300), named: "ItemsList_unsupported")
    }

    func testNeedsYouBadge() {
        assertVariants(of: HStack { NeedsYouBadge(count: 3); NeedsYouBadge(count: 120); NeedsYouBadge(count: 0) }.padding(), named: "NeedsYouBadge")
    }
}
