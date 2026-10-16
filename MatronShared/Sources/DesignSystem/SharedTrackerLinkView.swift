import SwiftUI
import MatronModels

/// Another person's shareable link (`https://<journal>/u/<them>/<n>`),
/// read-only: what the journal lets the signed-in user see of it (the
/// item with its comments, or the mission with its milestones), or a line
/// saying it is not shared with them. The web app cannot show another
/// person's rows either, so this is where such a link lands rather than
/// the browser. A dumb projection like `GoToNumberView`: the state lives in
/// `SharedTrackerLinkViewModel`.
///
/// Links in the shown text are that person's: a `matron://item/<n>` or
/// `matron://mission/<n>` names *their* number `n`, so it goes to
/// `onOpenNumber` (shown here in turn), never to the window's own openers.
/// An https link to anyone else's number goes to `onOpenOthersLink`; one to
/// the signed-in user's own number goes to `onOpenOwnLink`, which leaves
/// the viewer to open it. A conversation link is another person's
/// conversation, so it does nothing.
public struct SharedTrackerLinkView: View {
    let link: TrackerLinkPath
    let state: SharedTrackerLinkState
    let onCopyLink: () -> Void
    let onRetry: () -> Void
    let onDone: () -> Void
    let onOpenNumber: @MainActor (Int) -> Void
    let onOpenOthersLink: @MainActor @Sendable (TrackerLinkPath, URL) -> Void
    let onOpenOwnLink: @MainActor @Sendable (URL) -> Void

    @Environment(\.trackerNumberLinks) private var trackerNumberLinks

    public init(link: TrackerLinkPath, state: SharedTrackerLinkState, onCopyLink: @escaping () -> Void,
                onRetry: @escaping () -> Void, onDone: @escaping () -> Void,
                onOpenNumber: @escaping @MainActor (Int) -> Void = { _ in },
                onOpenOthersLink: @escaping @MainActor @Sendable (TrackerLinkPath, URL) -> Void = { _, _ in },
                onOpenOwnLink: @escaping @MainActor @Sendable (URL) -> Void = { _ in }) {
        self.link = link
        self.state = state
        self.onCopyLink = onCopyLink
        self.onRetry = onRetry
        self.onDone = onDone
        self.onOpenNumber = onOpenNumber
        self.onOpenOthersLink = onOpenOthersLink
        self.onOpenOwnLink = onOpenOwnLink
    }

    static func notSharedMessage(_ link: TrackerLinkPath) -> String {
        "#\(link.num) on \(link.user)'s tracker isn't shared with you. Ask \(link.user) to share its mission with you."
    }

    static func unsupportedMessage(_ kind: String, _ link: TrackerLinkPath) -> String {
        "\(kind) #\(link.num) on \(link.user)'s tracker can't be shown here."
    }

    static let failedMessage = "Couldn't load this link. Check the connection and try again."

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Text("Read-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Link", action: onCopyLink)
                if case .failed = state { Button("Try Again", action: onRetry) }
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading")
        case .loaded(let preview):
            loaded(preview)
        case .notShared:
            message(Self.notSharedMessage(link), symbol: "lock")
        case .unsupported(let kind):
            message(Self.unsupportedMessage(kind, link), symbol: "eye.slash")
        case .failed:
            message(Self.failedMessage, symbol: "exclamationmark.triangle")
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("#\(link.num) · \(link.user)'s tracker")
                .font(.headline)
            Label(text, systemImage: symbol)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func loaded(_ p: SharedTrackerPreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.heading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(p.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(p.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !p.body.isEmpty {
                    MarkdownText(p.body)
                }
                if let heading = p.entriesHeading {
                    Divider()
                    Text(heading).font(.headline)
                    ForEach(p.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.heading).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.body.isEmpty { MarkdownText(entry.body) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openTrackerItem, { onOpenNumber($0) })
        .environment(\.openPageLink, { onOpenNumber($0.num) })
        .environment(\.openConversation, nil)
        .environment(\.trackerNumberLinks, trackerNumberLinks?.redirecting(own: onOpenOwnLink, others: onOpenOthersLink))
    }
}
