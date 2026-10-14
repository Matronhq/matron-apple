import AppKit
import SwiftUI
import MatronDesignSystem
import MatronViewModels
import MatronChat
import MatronModels

/// What the native item thread's hosted pieces read from the host's
/// environment. An `NSHostingView` in a table cell does not inherit the
/// SwiftUI environment around the table, so the host captures these and
/// the factory puts them back on every piece.
struct MacItemThreadEnvironment {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    var openPageLink: ((MatronPageLink) -> Void)?
    var trackerNumberLinks: TrackerNumberLinks?
    var conversationLinkHost: ConversationLinkHost?
    var markdownPreview: MarkdownPreviewModel?
    var itemCommentField: ItemCommentFieldFactory?
    var fillsTitleBar = false
}

/// Builds the SwiftUI pieces the native item thread hosts: one part of the
/// item view (`ItemDetailView.showing(only:)`), with the environment it
/// would have had inside the SwiftUI thread.
@MainActor
struct MacItemPieceFactory {
    var detail: ItemDetailView
    var environment: MacItemThreadEnvironment
    var selection: MessageSelectionController

    func view(_ piece: ItemDetailView.Piece) -> AnyView {
        AnyView(detail.showing(only: piece)
            .environment(selection)
            .environment(environment.markdownPreview)
            .environment(\.openTrackerItem, environment.openTrackerItem)
            .environment(\.openConversation, environment.openConversation)
            .environment(\.openPageLink, environment.openPageLink)
            .environment(\.trackerNumberLinks, environment.trackerNumberLinks)
            .environment(\.conversationLinkHost, environment.conversationLinkHost)
            .environment(\.itemCommentField, environment.itemCommentField)
            .environment(\.itemDetailFillsTitleBar, environment.fillsTitleBar))
    }
}

/// Measures a hosted piece off-window: its height at a width, and the width
/// it takes there (a caption hugs its text). One reused hosting view; main
/// thread only.
@MainActor
final class MacItemPieceSizer {
    private let host = NSHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
    }

    func size(of view: AnyView, maxWidth: CGFloat) -> CGSize {
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }
}
