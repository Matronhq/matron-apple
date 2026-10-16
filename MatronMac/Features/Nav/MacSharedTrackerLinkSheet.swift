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
                              onOpenOwnLink: { url in
                                  // The window opens it once the sheet is gone,
                                  // as it does a link from another app.
                                  onDone()
                                  IncomingTrackerLinks.shared.receive(url)
                              })
            .task { await viewModel.load() }
    }
}
