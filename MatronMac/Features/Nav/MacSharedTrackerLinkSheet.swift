import SwiftUI
import AppKit
import MatronDesignSystem
import MatronViewModels

/// Another person's shareable link, read-only, as a sheet on the window
/// the link was tapped in (or the window that took an incoming one). Links
/// in the shown text stay in the sheet, except one to the user's own
/// number, which closes it and opens in the window.
struct MacSharedTrackerLinkSheet: View {
    let viewModel: SharedTrackerLinkViewModel
    let onDone: () -> Void
    /// Closes the sheet and opens one of the user's own links in this
    /// window, as one from another app would.
    let openOwnLink: @MainActor @Sendable (URL) -> Void

    var body: some View {
        SharedTrackerLinkView(link: viewModel.link, state: viewModel.state,
                              onCopyLink: {
                                  NSPasteboard.general.clearContents()
                                  NSPasteboard.general.setString(viewModel.url.absoluteString, forType: .string)
                              },
                              onRetry: { Task { await viewModel.load() } },
                              onDone: onDone,
                              onOpenNumber: { num in Task { await viewModel.showSameOwner(num) } },
                              onOpenOthersLink: { link, url in Task { await viewModel.show(link, url: url) } },
                              onOpenOwnLink: openOwnLink)
            .task { await viewModel.load() }
    }
}
