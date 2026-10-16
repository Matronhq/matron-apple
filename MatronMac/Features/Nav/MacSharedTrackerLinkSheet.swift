import SwiftUI
import AppKit
import MatronDesignSystem
import MatronViewModels

/// Another person's shareable link, read-only, as a sheet on the window
/// the link was tapped in (or the window that took an incoming one).
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
                              onDone: onDone)
            .task { await viewModel.load() }
    }
}
