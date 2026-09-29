import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels

/// Everything the Mac mission page draws, as values — the host maps its
/// view models into this, and the tests build it by hand. Deliberately
/// holds no clock and no close-summary draft: a minute tick and a keystroke
/// in the close sheet must not rebuild the whole page.
struct MacMissionPageModel: Equatable {
    var mission: Mission
    /// The newest milestone whatever the "Only your inputs" filter says.
    var latestStep: Milestone?
    /// Already filtered by `showOnlyUserInput`, newest first.
    var milestones: [Milestone]
    /// Milestone bodies parsed once (by id) — see `MacMilestoneBodyCache`.
    var milestoneBodies: [String: AttributedString]
    var showOnlyUserInput: Bool
    /// The store's order: awaiting you first.
    var openItems: [TrackerItem]
    /// Whether `openItems` has been read yet (else it means "unknown").
    var openItemsLoaded: Bool
    /// Most recently closed first — a loaded prefix of `closedItemsTotal`.
    var closedItems: [TrackerItem]
    var closedItemsTotal: Int
    /// Sorted, sub-agents excluded (`MissionsDashboardViewModel
    /// .pageMissionSessions`).
    var sessions: [DashboardSession]
    /// The mission's conversations as the detail fetch returned them — the
    /// fallback for a session title or box when `sessions` has no row.
    var conversations: [MissionConversation]
    /// Milestone conversation tags, by conversation id.
    var sessionTags: [String: SessionTagInputs]
    var isBusy: Bool

    var needsYouItems: [TrackerItem] { openItems.filter { $0.awaiting == .user } }
    /// Open items that are not waiting on you — the Overview's "Open tasks
    /// & decisions" card.
    var otherOpenItems: [TrackerItem] { openItems.filter { $0.awaiting != .user } }
    /// The local rows once they are read (they follow item markers live);
    /// the server's count until then.
    var needsYouCount: Int { openItemsLoaded ? needsYouItems.count : mission.needsYou }

    /// The title a conversation goes by on this page.
    func conversationTitle(_ convoID: String) -> String? {
        if let session = sessions.first(where: { $0.id == convoID }), !session.title.isEmpty { return session.title }
        guard let convo = conversations.first(where: { $0.id == convoID }) else { return nil }
        let title = SessionTag.splitTitle(convo.title).title
        return title.isEmpty ? nil : title
    }

    /// The box working in a conversation, when this device knows it — the
    /// Board's "In progress" meta line.
    func boxName(_ convoID: String) -> String? {
        if let session = sessions.first(where: { $0.id == convoID }),
           let name = session.tag?.boxName ?? session.boxName, !name.isEmpty {
            return name
        }
        if let box = conversations.first(where: { $0.id == convoID })?.box, !box.isEmpty { return box }
        return nil
    }
}

/// What the page's taps ask the host to do.
struct MacMissionPageActions {
    var onToggleUserInputOnly: (Bool) -> Void = { _ in }
    var onOpenMilestone: (Milestone) -> Void = { _ in }
    var onOpenItem: (String) -> Void = { _ in }
    var onOpenConversation: (String) -> Void = { _ in }
    /// Closes the mission with this summary; returns the error to show, or
    /// `nil` once it closed.
    var onClose: (String) async -> String? = { _ in nil }
    /// The board wants at least this many closed items loaded.
    var onLoadClosedItems: (Int) -> Void = { _ in }
}

/// Parses each milestone body once: a body only changes with its
/// milestone, so re-parsing markdown on every page render (the old path)
/// was pure churn. A reference type the host keeps in `@State` — never
/// observed, so filling it triggers nothing.
final class MacMilestoneBodyCache {
    private var parsed: [String: (body: String, text: AttributedString)] = [:]

    func bodies(for milestones: [Milestone]) -> [String: AttributedString] {
        var out: [String: AttributedString] = [:]
        for milestone in milestones where !milestone.body.isEmpty {
            if let hit = parsed[milestone.id], hit.body == milestone.body {
                out[milestone.id] = hit.text
            } else {
                let text = MissionsDashboardFormat.statusText(milestone.body)
                parsed[milestone.id] = (milestone.body, text)
                out[milestone.id] = text
            }
        }
        return out
    }
}

/// The Mac mission page below its top bar: header, status, then the
/// Overview or the Board. Leaf view — no view models.
struct MacMissionPageContent: View {
    let model: MacMissionPageModel
    let mode: MacMissionPageMode
    let actions: MacMissionPageActions

    var body: some View {
        GeometryReader { geo in
            let detailWidth = geo.size.width
            let width = MacMissionPageLayout.contentWidth(detailWidth: detailWidth)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusCard
                    switch mode {
                    case .overview:
                        MacMissionOverview(model: model, actions: actions, contentWidth: width,
                                           twoColumns: MacMissionPageLayout.usesTwoColumns(detailWidth: detailWidth))
                    case .board:
                        MacMissionBoardView(model: model, onOpenItem: actions.onOpenItem,
                                            onLoadClosedItems: actions.onLoadClosedItems)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(MacMissionPalette.pageBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Verbatim: an interpolated Int in a localized key gets digit
                // grouping ("#3,778").
                Text(verbatim: "#\(model.mission.num)")
                    .font(.system(size: 20).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(model.mission.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                if model.mission.state == .closed {
                    Text("Closed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                } else {
                    NeedsYouPill(count: model.needsYouCount)
                }
            }
            if !model.mission.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(model.mission.body))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(model.mission.body)
            }
        }
    }

    /// Hidden when the mission has no status (spec: nothing, no placeholder).
    @ViewBuilder private var statusCard: some View {
        if let status = model.mission.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    MacMissionSectionLabel("Status")
                    Spacer(minLength: 12)
                    if model.mission.statusUpdatedAt != nil {
                        MacMinuteText { now in
                            MissionsDashboardFormat.statusByline(updatedAt: model.mission.statusUpdatedAt,
                                                                 by: model.mission.statusBy, now: now) ?? ""
                        }
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Text(MissionsDashboardFormat.statusText(status))
                    .font(.system(size: 17))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .macMissionCard()
            .accessibilityElement(children: .combine)
        }
    }
}
