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
/// Behind `MacItemThreadFlag`.
struct MacItemNativeThread: View {
    let detail: ItemDetailView
    @State private var selection = MessageSelectionController()
    @State private var proxy = MacItemThreadProxy()

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
            detail: detail,
            environment: MacItemThreadEnvironment(
                openTrackerItem: openTrackerItem, openConversation: openConversation, openPageLink: openPageLink,
                trackerNumberLinks: trackerNumberLinks, conversationLinkHost: conversationLinkHost,
                markdownPreview: markdownPreview, itemCommentField: itemCommentField, fillsTitleBar: fillsTitleBar),
            selection: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !fillsTitleBar { detail.resolveControlRow() }
            MacItemThreadRepresentable(factory: factory, proxy: proxy)
                // On Decisions the thread runs up under the clear title
                // bar, as the SwiftUI thread does (`fillingTitleBar`).
                .ignoresSafeArea(.container, edges: fillsTitleBar ? .top : [])
                .overlay(alignment: .bottomTrailing) {
                    if proxy.showsJump { JumpToBottomButton { proxy.jump() } }
                }
                .animation(.easeInOut(duration: 0.18), value: proxy.showsJump)
            Divider()
            detail.replyComposer()
        }
        .background(MatronTimelineBackground())
        .onDisappear { selection.clear() }
    }
}

/// What the face reads back from the table: whether the reader is at the
/// bottom of a thread that overflows, and a way to send them there.
@MainActor @Observable
final class MacItemThreadProxy {
    var geometry = MacItemThreadController.Geometry()
    @ObservationIgnored weak var controller: MacItemThreadController?

    var showsJump: Bool {
        ItemDetailView.showsJumpToBottom(placed: geometry.placed, scrollable: geometry.scrollable,
                                         atBottom: geometry.atBottom)
    }

    func jump() { controller?.scrollToBottom() }
}

struct MacItemThreadRepresentable: NSViewControllerRepresentable {
    let factory: MacItemPieceFactory
    let proxy: MacItemThreadProxy

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

    static func dismantleNSViewController(_ controller: MacItemThreadController, coordinator: ()) {
        controller.tearDown()
    }
}
