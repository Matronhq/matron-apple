import SwiftUI
import MatronEvents

/// A person-to-person consent card, inline in the timeline: a contact
/// request, a mission share, a session share, or a room or talk request with
/// another person's agent.
///
/// Inert on purpose. These asks are answered only through their tracker
/// mirror, whose own buttons reach the journal; a button here would have
/// nothing behind it. So the card states who is asking, which way and what
/// about, and offers one way on — "Answer in the tracker" opening the mirror
/// item when the timeline found it, a plain hint when it did not.
///
/// Pure: plain values and closures only, like `AgentChatRequestCard`, so it
/// stays in MatronDesignSystem and snapshots directly.
public struct PersonConsentRequestCard: View {
    public let card: PersonConsentCard
    /// Opens a tracker item by id. `nil` (previews, a screen with nowhere to
    /// open it) leaves the hint as text rather than a dead link.
    public let onOpenItem: ((String) -> Void)?

    public init(card: PersonConsentCard, onOpenItem: ((String) -> Void)? = nil) {
        self.card = card
        self.onOpenItem = onOpenItem
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(card.title).font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: Self.symbol(for: card)).foregroundStyle(.tint)
            }

            Text(card.headline).font(.body)

            if let topic = card.topic {
                detail(label: "About", value: topic)
            }
            if let mission = card.missionTitle {
                detail(label: "Mission", value: mission)
            }
            if let session = card.sessionTitle {
                detail(label: "Session", value: session)
            }

            footer
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.matronBubbleBot)
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
        )
    }

    @ViewBuilder
    private var footer: some View {
        switch Self.footer(for: card, canOpen: onOpenItem != nil) {
        case .link(let text, let itemID):
            Button {
                onOpenItem?(itemID)
            } label: {
                Label(text, systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        case .settledLink(let text, let itemID):
            VStack(alignment: .leading, spacing: 4) {
                settledLine
                Button {
                    onOpenItem?(itemID)
                } label: {
                    Label(text, systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        case .settled:
            settledLine
        case .hint(let text):
            Label(text, systemImage: "tray")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var settledLine: some View {
        Text(Self.settledText)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    // MARK: Pure decisions (tested without rendering)

    public enum Footer: Equatable {
        /// The mirror is open: a link to answer it.
        case link(String, itemID: String)
        /// The mirror is closed: the ask is settled, and the item can still
        /// be opened to see how.
        case settledLink(String, itemID: String)
        /// Settled, with nowhere to open it.
        case settled
        /// No mirror found, or nowhere to open it: plain words.
        case hint(String)
    }

    public static let answerText = "Answer in the tracker"
    public static let openText = "Open in the tracker"
    public static let hintText = "Answer it in your tracker, under For you."
    public static let settledText = "No longer waiting for an answer."

    public static func footer(for card: PersonConsentCard, canOpen: Bool) -> Footer {
        switch card.mirror {
        case .open(let id):
            return canOpen ? .link(answerText, itemID: id) : .hint(hintText)
        case .closed(let id):
            return canOpen ? .settledLink(openText, itemID: id) : .settled
        case .unknown:
            return .hint(hintText)
        }
    }

    public static func symbol(for card: PersonConsentCard) -> String {
        switch card.kind {
        case .contactRequest: return "person.crop.circle.badge.plus"
        case .missionShare: return "eye"
        case .sessionShare: return "person.2"
        case .personRoom: return "bubble.left.and.bubble.right"
        }
    }

    /// What VoiceOver reads for the whole card.
    public static func accessibilitySummary(for card: PersonConsentCard) -> String {
        var parts = ["\(card.title). \(card.headline)"]
        if let topic = card.topic { parts.append("About: \(topic).") }
        if let mission = card.missionTitle { parts.append("Mission: \(mission).") }
        if let session = card.sessionTitle { parts.append("Session: \(session).") }
        return parts.joined(separator: " ")
    }
}
