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
    /// .clipShape(...)`; bisecting showed that combination doesn't
    /// rasterize under this suite's `NSHostingView.fittingSize` offscreen
    /// snapshot harness when the source `Image` is a template/vector one
    /// (e.g. `Image(systemName:)`) — the row renders fully transparent
    /// regardless of `foregroundStyle`/`foregroundColor`. A real bitmap
    /// source (built here, or `AttachmentImage`'s decoded photo data in
    /// production) renders correctly through the identical modifier
    /// chain, confirmed by a throwaway bisection. Production `ItemRow`
    /// callers always supply a decoded bitmap, never an SF Symbol, so this
    /// is a harness-only gap for template images — the same category of
    /// finding as `MediaBrowserView.fileList`'s `List`-doesn't-populate
    /// doc comment (`MatronShared/Sources/DesignSystem/MediaBrowserView.swift:141-147`),
    /// just for a different SwiftUI primitive.
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

    /// `List` (NSTableView-backed on macOS) doesn't populate its rows when
    /// snapshotted via `NSHostingView.fittingSize` + `cacheDisplay` — see
    /// the doc comment on `MediaBrowserView.fileList`
    /// (`MatronShared/Sources/DesignSystem/MediaBrowserView.swift:141-147`)
    /// for the same finding on that view. So this baseline only pins the
    /// header chrome (scope picker, refreshing spinner, + button) above an
    /// empty-looking list body; row rendering itself is pinned separately
    /// by `testRowVariants`, which snapshots `ItemRow` directly in a plain
    /// `VStack` (pure SwiftUI, renders deterministically in this harness).
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
}
