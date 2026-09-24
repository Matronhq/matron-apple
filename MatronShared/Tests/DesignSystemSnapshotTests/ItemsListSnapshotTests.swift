import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ItemsListSnapshotTests: XCTestCase {
    /// A real bitmap `Image`, standing in for a decoded photo thumbnail.
    /// `ItemRow`'s thumbnail branch chains `.resizable().scaledToFill()…
    /// .clipShape(...).foregroundStyle(.tertiary)`. A template/vector
    /// source (e.g. `Image(systemName:)`) through that chain draws
    /// untinted solid white in both appearances under the windowed Mac
    /// harness (re-checked with `MacSnapshotHost`, #2840), so it would be
    /// invisible in the light reference. Production `ItemRow` callers
    /// always supply a decoded bitmap, never an SF Symbol, so the fixture
    /// uses one too.
    private var bitmapThumbnail: Image {
        let size = CGSize(width: 40, height: 40)
        #if os(macOS)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return Image(nsImage: img)
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: img)
        #endif
    }

    private func t(_ id: String, num: Int, kind: ItemKind, awaiting: ItemAwaiting?, title: String, state: ItemState = .open, comments: Int = 0, image: Bool = false) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil, awaiting: awaiting, rank: Double(num),
                    title: title, body: "Some body text that previews on one line and then gets cut off", originConvoID: "c1",
                    createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000),
                    closedAt: state == .closed ? .init(timeIntervalSince1970: 1_770_000_100) : nil, commentCount: comments, hasImage: image)
    }

    /// The whole list — header chrome (scope picker, refreshing spinner,
    /// + button) and the `List` sections and rows. `testRowVariants` pins
    /// the individual row states more densely in a plain `VStack`.
    func testPopulatedList() {
        let model = ItemsListView.Model(
            needsYou: [t("q1", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", comments: 2, image: true)],
            tasks: [t("t1", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module"), t("t2", num: 14, kind: .task, awaiting: .agent, title: "Write the migration")],
            decisions: [t("d1", num: 11, kind: .decision, awaiting: nil, title: "Use SQLite for the cache")],
            done: [t("x1", num: 3, kind: .task, awaiting: nil, title: "Set up CI", state: .closed)],
            originTitles: [:], isSupported: true, isRefreshing: true)
        let view = ItemsListView(model: model, scope: .constant(.convo("c1")), convoID: "c1", thumbnail: { _ in nil },
                                 onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
            .frame(width: 360, height: 560)
        assertVariants(of: view, named: "ItemsList_populated")
    }

    func testRowVariants() {
        let view = VStack(alignment: .leading, spacing: 12) {
            ItemRow(item: t("q1", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", comments: 2, image: true))
            ItemRow(item: t("t1", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module"))
            ItemRow(item: t("d1", num: 11, kind: .decision, awaiting: nil, title: "Use SQLite for the cache"))
            ItemRow(item: t("x1", num: 3, kind: .task, awaiting: nil, title: "Set up CI", state: .closed))
            ItemRow(item: t("t2", num: 14, kind: .task, awaiting: .agent, title: "Write the migration"), showsOrigin: "auth refactor")
            ItemRow(item: t("q2", num: 15, kind: .question, awaiting: .user, title: "Which cache TTL?", image: true), thumbnail: bitmapThumbnail)
            // Pending "create" rows (fix wave, item C), pinned directly in
            // a plain `VStack` like the rest of this test.
            PendingItemRow(row: .init(id: "p1", kind: .task, title: "Draft a migration plan", isFailed: false, error: nil))
            PendingItemRow(row: .init(id: "p2", kind: .question, title: "Which region for the new bucket?", isFailed: true, error: "offline"))
        }
        .frame(width: 360)
        .padding()
        assertVariants(of: view, named: "ItemRow_variants")
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

    /// App shell (spec §1): with no home conversation the "This chat / All"
    /// picker is meaningless and is hidden; only the refresh spinner and
    /// the `+` remain in the header.
    func testNoConversationHidesScopePicker() {
        let model = ItemsListView.Model(needsYou: [], tasks: [], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: true)
        let view = ItemsListView(model: model, scope: .constant(.all), convoID: nil, thumbnail: { _ in nil },
                                 onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
            .frame(width: 360, height: 200)
        assertVariants(of: view, named: "ItemsList_noConvo")
    }
}
