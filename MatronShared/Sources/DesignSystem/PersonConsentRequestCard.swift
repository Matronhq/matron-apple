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
/// The hand-over card is the one that answers itself: it shows the brief and
/// what would cross, lets the owner untick files to leave behind and choose
/// whether to keep contributing afterwards, and posts
/// the answer on `POST /grants/:id/answer` (the mirror's one-tap Approve
/// would send everything).
///
/// Pure: plain values and closures only, like `AgentChatRequestCard`, so it
/// stays in MatronDesignSystem and snapshots directly.
public struct PersonConsentRequestCard: View {
    public let card: PersonConsentCard
    /// Opens a tracker item by id. `nil` (previews, a screen with nowhere to
    /// open it) leaves the hint as text rather than a dead link.
    public let onOpenItem: ((String) -> Void)?
    /// A hand-over card's answer state. Ignored by every other kind.
    public let handoverState: PersonHandoverCardState
    /// Answers a hand-over: approve (Accept on the recipient's card) or
    /// decline, with the media ids to leave behind and, on the owner's
    /// card, the keep-contributing switch (`nil` on the recipient's). `nil`
    /// draws no buttons.
    public let onAnswerHandover: ((_ approve: Bool, _ excludeMedia: [String], _ keepContributing: Bool?) -> Void)?
    /// Told the files left unticked after each toggle, so whoever owns the
    /// card can hand them back as `excludedMedia` when it is rebuilt.
    public let onExcludedMediaChange: ((Set<String>) -> Void)?
    /// Told the keep-contributing switch after each flip, for the same
    /// reason: a rebuilt card gets it back as `keepContributing`.
    public let onKeepContributingChange: ((Bool) -> Void)?

    /// The files the owner is sending — all of them until unticked.
    @State private var included: Set<String>
    /// The owner's "Keep contributing" switch.
    @State private var keepContributing: Bool
    @State private var briefExpanded = false

    public init(card: PersonConsentCard, onOpenItem: ((String) -> Void)? = nil,
                handoverState: PersonHandoverCardState = .settled,
                onAnswerHandover: ((_ approve: Bool, _ excludeMedia: [String], _ keepContributing: Bool?) -> Void)? = nil,
                excludedMedia: Set<String> = [], onExcludedMediaChange: ((Set<String>) -> Void)? = nil,
                keepContributing: Bool? = nil, onKeepContributingChange: ((Bool) -> Void)? = nil) {
        self.card = card
        self.onOpenItem = onOpenItem
        self.handoverState = handoverState
        self.onAnswerHandover = onAnswerHandover
        self.onExcludedMediaChange = onExcludedMediaChange
        self.onKeepContributingChange = onKeepContributingChange
        _included = State(initialValue: Set(card.handover?.attachments.map(\.mediaID) ?? [])
            .subtracting(excludedMedia))
        _keepContributing = State(initialValue: Self.initialKeepContributing(for: card, chosen: keepContributing))
    }

    public var body: some View {
        if let handover = card.handover {
            handoverBody(handover)
        } else {
            askBody
        }
    }

    private var askBody: some View {
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
            if let access = card.accessLine {
                Label(access, systemImage: card.canContribute ? "square.and.pencil" : "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

    // MARK: Hand-over

    private func handoverBody(_ handover: MissionHandoverDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(card.title).font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: Self.symbol(for: card)).foregroundStyle(.tint)
            }

            Text(card.headline).font(.body)

            if let title = handover.subjectTitle {
                detail(label: handover.subjectKind == .project ? "Project" : "Mission", value: title)
            }

            if !handover.brief.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Brief").font(.caption).foregroundStyle(.secondary)
                    // Clamped in the card: the timeline measures a row
                    // once, so a long brief opens in a sheet rather than
                    // growing in place.
                    Text(Self.briefText(handover.brief))
                        .font(.callout)
                        .lineLimit(Self.briefLineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    if Self.briefMayBeClipped(handover.brief) {
                        Button("Read the whole brief") { briefExpanded = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(card.direction == .outgoing ? "What goes across" : "What comes with it")
                    .font(.caption).foregroundStyle(.secondary)
                Text(handover.countsLine(includedAttachments: card.direction == .outgoing
                                         ? included.count : nil))
                    .font(.callout)
            }

            if card.direction == .outgoing, !handover.attachments.isEmpty {
                attachmentToggles(handover)
            }

            if card.direction == .outgoing {
                keepSwitch
            } else if let keepLine = card.keepLine {
                Label(keepLine, systemImage: handover.keepContributing ? "square.and.pencil" : "eye")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            handoverControls(handover)

            handoverFooter
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.matronBubbleBot)
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
        )
        .sheet(isPresented: $briefExpanded) {
            NavigationStack {
                ScrollView {
                    Text(Self.briefText(handover.brief))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Hand-over brief")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { briefExpanded = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    }

    private func attachmentToggles(_ handover: MissionHandoverDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files (untick to leave one behind)").font(.caption).foregroundStyle(.secondary)
            ForEach(handover.attachments) { file in
                Toggle(isOn: Binding(
                    get: { included.contains(file.mediaID) },
                    set: { on in
                        if on { included.insert(file.mediaID) } else { included.remove(file.mediaID) }
                        onExcludedMediaChange?(Set(handover.excludedMediaIDs(included: included)))
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let meta = Self.attachmentMeta(file) {
                            Text(meta).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!handoverState.isAnswerable || handoverState == .sending)
                .accessibilityHint(included.contains(file.mediaID) ? "Will be sent" : "Will be left behind")
            }
        }
    }

    private var keepSwitch: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { keepContributing },
                set: { on in
                    keepContributing = on
                    onKeepContributingChange?(on)
                }
            )) {
                Text(MissionHandoverDetails.keepSwitchLabel).font(.callout)
            }
            .disabled(!handoverState.isAnswerable || handoverState == .sending)
            Text(MissionHandoverDetails.keepHint(keepContributing: keepContributing))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func handoverControls(_ handover: MissionHandoverDetails) -> some View {
        switch handoverState {
        case .idle, .sending, .failed:
            if let onAnswerHandover {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("Decline") { onAnswerHandover(false, [], nil) }
                            .buttonStyle(.bordered)
                        Button(Self.approveLabel(for: card)) {
                            onAnswerHandover(true, handover.excludedMediaIDs(included: included),
                                             card.direction == .outgoing ? keepContributing : nil)
                        }
                        .buttonStyle(.borderedProminent)
                        if handoverState == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .disabled(handoverState == .sending)
                    if case .failed(let message) = handoverState {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        case .answered(let approved):
            Label(Self.answeredText(for: card, approved: approved),
                  systemImage: approved ? "checkmark.circle" : "xmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .settled:
            settledLine
        }
    }

    @ViewBuilder
    private var handoverFooter: some View {
        if card.direction == .outgoing {
            // The way to say why: a reply on the mirror reaches the agent
            // that asked, as an ordinary item reply.
            if let itemID = card.mirror.itemID, onOpenItem != nil {
                Button {
                    onOpenItem?(itemID)
                } label: {
                    Label(Self.replyHintText, systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Label(Self.replyHintText, systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    public static let replyHintText = "Reply on the tracker item to send a note back to your agent."
    /// Lines of the brief shown before "Show all".
    public static let briefLineLimit = 8

    /// Where the owner's switch starts: what they last chose, else the ask.
    public static func initialKeepContributing(for card: PersonConsentCard, chosen: Bool?) -> Bool {
        chosen ?? card.handover?.keepContributing ?? false
    }

    public static func approveLabel(for card: PersonConsentCard) -> String {
        card.direction == .outgoing ? "Approve" : "Accept"
    }

    public static func answeredText(for card: PersonConsentCard, approved: Bool) -> String {
        let noun = card.handover?.subjectKind == .project ? "project" : "mission"
        switch (card.direction, approved) {
        case (.outgoing, true): return "Approved. Waiting for \(card.personLabel)."
        case (.outgoing, false): return "Declined. Nothing was sent."
        case (.incoming, true): return "Accepted. The \(noun) is yours."
        case (.incoming, false): return "Declined."
        }
    }

    /// The brief as inline markdown (bold, links, code), keeping its line
    /// breaks; plain text if it does not parse.
    public static func briefText(_ brief: String) -> AttributedString {
        (try? AttributedString(markdown: brief, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(brief)
    }

    /// Whether the brief can run past `briefLineLimit` — by its lines, or
    /// by its length (about 60 characters a line in a 360-point card).
    public static func briefMayBeClipped(_ brief: String) -> Bool {
        brief.split(separator: "\n", omittingEmptySubsequences: false).count > briefLineLimit
            || brief.count > briefLineLimit * 60
    }

    /// "240 KB · on #12" — whichever parts are known.
    public static func attachmentMeta(_ file: MissionHandoverDetails.Attachment) -> String? {
        var parts: [String] = []
        if file.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        }
        if let num = file.itemNum { parts.append("on #\(num)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
        case .missionHandover: return "arrow.right.circle"
        }
    }

    /// What VoiceOver reads for the whole card.
    public static func accessibilitySummary(for card: PersonConsentCard) -> String {
        var parts = ["\(card.title). \(card.headline)"]
        if let topic = card.topic { parts.append("About: \(topic).") }
        if let title = card.missionTitle {
            parts.append("\(card.handover?.subjectKind == .project ? "Project" : "Mission"): \(title).")
        }
        if let access = card.accessLine { parts.append("\(access).") }
        if let session = card.sessionTitle { parts.append("Session: \(session).") }
        if let handover = card.handover {
            parts.append("\(handover.countsLine()).")
            if let keepLine = card.keepLine { parts.append(keepLine) }
            if !handover.brief.isEmpty { parts.append("Brief: \(handover.brief)") }
        }
        return parts.joined(separator: " ")
    }
}
