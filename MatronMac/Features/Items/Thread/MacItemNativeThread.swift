import AppKit
import SwiftUI
import Observation
import MatronDesignSystem
import MatronViewModels
import MatronChat
import MatronModels

/// The item view's thread drawn by `MacItemThreadController` instead of a
/// SwiftUI stack: the pinned resolve row, the table, the jump button and
/// the reply composer, laid out as `ItemDetailView`'s own thread is.
struct MacItemNativeThread: View {
    let detail: ItemDetailView
    @State private var selection = MessageSelectionController()
    @State private var proxy = MacItemThreadProxy()
    /// Ticks once a minute so the captions' relative dates move on while
    /// the thread is open and nothing else changes.
    @State private var clock = Date()

    @Environment(\.openTrackerItem) private var openTrackerItem
    @Environment(\.openConversation) private var openConversation
    @Environment(\.openPageLink) private var openPageLink
    @Environment(\.trackerNumberLinks) private var trackerNumberLinks
    @Environment(\.conversationLinkHost) private var conversationLinkHost
    @Environment(MarkdownPreviewModel.self) private var markdownPreview: MarkdownPreviewModel?
    @Environment(\.itemCommentField) private var itemCommentField
    @Environment(\.itemDetailFillsTitleBar) private var fillsTitleBar

    private var factory: MacItemPieceFactory {
        MacItemPieceFactory(
            detail: detail.captionsDrawn(at: clock),
            environment: MacItemThreadEnvironment(
                openTrackerItem: openTrackerItem, openConversation: openConversation, openPageLink: openPageLink,
                trackerNumberLinks: trackerNumberLinks, conversationLinkHost: conversationLinkHost,
                markdownPreview: markdownPreview, itemCommentField: itemCommentField, fillsTitleBar: fillsTitleBar),
            selection: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !fillsTitleBar { detail.resolveControlRow() }
            // The jump-to-top pill sits in the stack, not on the table, so
            // it stays below the title bar when the table runs up under it.
            ZStack(alignment: .topTrailing) {
                MacItemThreadRepresentable(factory: factory, proxy: proxy,
                                           linkAnswers: trackerNumberLinks?.titles?.answers ?? [:])
                    // On Decisions the thread runs up under the clear title
                    // bar, as the SwiftUI thread does (`fillingTitleBar`).
                    .ignoresSafeArea(.container, edges: fillsTitleBar ? .top : [])
                    .overlay(alignment: .bottomTrailing) {
                        if proxy.showsJump { JumpToBottomButton { proxy.jump() } }
                    }
                if proxy.showsJumpToTop {
                    JumpToTopButton { proxy.jumpToTop() }
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: proxy.showsJump)
            .animation(.easeInOut(duration: 0.18), value: proxy.showsJumpToTop)
            Divider()
            detail.replyComposer()
        }
        .background(MatronTimelineBackground())
        // Restarted when a newer comment lands, so its "now" turns into
        // "1 min ago" on time.
        .task(id: detail.captionDates.max()) {
            while !Task.isCancelled {
                let now = Date()
                clock = now
                let wake = ItemDetailView.nextCaptionRefresh(dates: detail.captionDates, now: now)
                try? await Task.sleep(for: .seconds(wake.timeIntervalSince(now) + 0.05))
            }
        }
        .onDisappear { selection.clear() }
    }
}

/// What the face reads back from the table: whether the reader is at the
/// top or the bottom of a thread that overflows, and a way to send them
/// to either end.
@MainActor @Observable
final class MacItemThreadProxy {
    var geometry = MacItemThreadController.Geometry()
    @ObservationIgnored weak var controller: MacItemThreadController?

    var showsJump: Bool {
        ItemDetailView.showsJumpToBottom(placed: geometry.placed, scrollable: geometry.scrollable,
                                         atBottom: geometry.atBottom)
    }

    var showsJumpToTop: Bool {
        ItemDetailView.showsJumpToTop(placed: geometry.placed, scrollable: geometry.scrollable, atTop: geometry.atTop)
    }

    func jump() { controller?.scrollToBottom() }

    func jumpToTop() { controller?.scrollToTop() }
}

struct MacItemThreadRepresentable: NSViewControllerRepresentable {
    let factory: MacItemPieceFactory
    let proxy: MacItemThreadProxy
    /// The session's tracker-link answers. Unused here, but a new answer
    /// is a new value, so SwiftUI updates the controller and the cards
    /// whose links it answers are built and measured again with their chip.
    var linkAnswers: [TrackerLinkTarget: TrackerLinkLookup] = [:]

    func makeNSViewController(context: Context) -> MacItemThreadController {
        let controller = MacItemThreadController(factory: factory)
        controller.onGeometryChange = { [weak proxy] geometry in
            if proxy?.geometry != geometry { proxy?.geometry = geometry }
        }
        proxy.controller = controller
        return controller
    }

    func updateNSViewController(_ controller: MacItemThreadController, context: Context) {
        controller.update(factory: factory, inSwiftUIUpdate: true)
    }

    /// Fills what it is given; see `FillingRepresentableSize`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: MacItemThreadController, context: Context) -> CGSize? {
        FillingRepresentableSize.size(for: proposal)
    }

    static func dismantleNSViewController(_ controller: MacItemThreadController, coordinator: ()) {
        controller.tearDown()
    }
}
