import SwiftUI
import MatronDesignSystem
import MatronModels

/// The latest briefing in full, as a sheet over the Projects tab: the
/// markdown with its links, the date, and "Open in chat". Every way out of
/// it — Done, "Open in chat", a link — closes the sheet first, so what the
/// link opens is not left hidden under it.
struct BriefingReaderSheet: View {
    let briefing: Briefing
    let session: UserSession?
    /// "Open in chat" and resolved item links; the tab root closes the
    /// sheet and hands them to the shell.
    let onAction: (ProjectsHomeAction) -> Void
    let onDone: () -> Void

    @Environment(\.appDependencies) private var deps
    /// The shell's conversation and page link openers, wrapped below so a
    /// tap closes the sheet before navigating.
    @Environment(\.openConversation) private var openConversation
    @Environment(\.openPageLink) private var openPageLink
    /// `[#12](matron://item/12)` taps in the briefing (see `TrackerItemLinkRelay`).
    @State private var itemLinkRelay = TrackerItemLinkRelay()

    var body: some View {
        NavigationStack {
            BriefingReaderView(markdown: briefing.body, createdAt: briefing.createdAt,
                               onOpenInChat: { onAction(.openConversation(convoID: briefing.convoID, seq: briefing.seq)) })
                .navigationTitle(BriefingFormat.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .environment(\.openConversation, closingOpenConversation)
        .environment(\.openPageLink, closingOpenPageLink)
        .trackerItemLinks(itemLinkRelay, resolve: { num in
            guard let deps, let session else { return .ignore }
            return await deps.trackerItemLinkOutcome(num: num, session: session)
        }, open: { onAction(.openItem($0)) })
    }

    private var closingOpenConversation: ((String) -> Void)? {
        guard let open = openConversation else { return nil }
        let done = onDone
        return { convoID in
            done()
            open(convoID)
        }
    }

    private var closingOpenPageLink: ((MatronPageLink) -> Void)? {
        guard let open = openPageLink else { return nil }
        let done = onDone
        return { link in
            done()
            open(link)
        }
    }
}
