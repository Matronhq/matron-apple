import SwiftUI
import MatronDesignSystem
import MatronModels

/// The Overview: Latest step and Milestones on the left (~60%); Needs you,
/// Sessions, Open tasks & decisions and the close control on the right.
/// One column, in that order, when `twoColumns` is false.
struct MacMissionOverview: View {
    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    /// The page's content width (`MacMissionPageLayout.contentWidth`).
    let contentWidth: CGFloat
    /// `MacMissionPageLayout.usesTwoColumns(detailWidth:)`.
    let twoColumns: Bool

    var body: some View {
        if twoColumns {
            let spacing = MacMissionPageLayout.columnSpacing
            let side = ((contentWidth - spacing) * MacMissionPageLayout.sideColumnFraction).rounded()
            HStack(alignment: .top, spacing: spacing) {
                mainColumn.frame(width: contentWidth - spacing - side)
                sideColumn.frame(width: side)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                mainColumn
                sideColumn
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacMissionConversationsCard(model: model, actions: actions)
            MacMilestonesCard(model: model, actions: actions)
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            needsYouCard
            openItemsCard
        }
    }

    // MARK: Needs you

    @ViewBuilder private var needsYouCard: some View {
        let items = model.needsYouItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MacMissionSectionLabel("Needs you", tint: .red)
                ForEach(items) { item in
                    Button { actions.onOpenItem(item.id) } label: { needsYouRow(item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("missionPage.needsYou.\(item.num)")
                }
            }
            .macMissionCard(fill: Color.red.opacity(0.06), border: Color.red.opacity(0.25))
        }
    }

    private func needsYouRow(_ item: TrackerItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ItemGlyph.symbol(item.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
            Text(item.title)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacMissionPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ItemGlyph.label(item.kind)): \(item.title)")
    }

    // MARK: Open tasks & decisions, close

    private var openItemsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacMissionSectionLabel("Open tasks & decisions")
            let items = model.otherOpenItems
            if items.isEmpty {
                Text("Nothing else open.").font(.system(size: 15)).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Button { actions.onOpenItem(item.id) } label: { openItemRow(item) }
                        .buttonStyle(.plain)
                }
            }
            MacMissionCloseControl(model: model, actions: actions)
                .padding(.top, 6)
        }
        .macMissionCard()
    }

    private func openItemRow(_ item: TrackerItem) -> some View {
        (Text(ItemGlyph.label(item.kind)).foregroundStyle(.secondary) + Text(" · ") .foregroundStyle(.secondary)
            + Text(item.title).foregroundStyle(Color.primary))
            .font(.system(size: 16))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// "Close mission…" — the existing close flow (a summary, then the close),
/// in a sheet. A closed mission shows its close summary instead.
struct MacMissionCloseControl: View {
    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    @State private var showingSheet = false

    var body: some View {
        if model.mission.state == .open {
            HStack {
                Spacer(minLength: 0)
                Button("Close mission…") { showingSheet = true }
                    .controlSize(.large)
                    .accessibilityIdentifier("missionPage.close")
            }
            .sheet(isPresented: $showingSheet) {
                MacMissionCloseSheet(openItems: model.openItems.count, onClose: actions.onClose,
                                     dismiss: { showingSheet = false })
            }
        } else {
            closedSummary
        }
    }

    @ViewBuilder private var closedSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacMissionSectionLabel("Closed")
            if let summary = model.mission.closeSummary, !summary.isEmpty {
                Text(MissionsDashboardFormat.statusText(summary)).font(.system(size: 15))
            }
            if model.mission.closedOverOpenItems > 0 {
                let n = model.mission.closedOverOpenItems
                Text("Closed over \(n) open item\(n == 1 ? "" : "s").")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
        }
    }
}

/// The close sheet. Its draft is its own `@State` — typing re-renders the
/// sheet, never the page. It stays open (with a spinner) until the close
/// returns, and shows the error in place if it failed.
struct MacMissionCloseSheet: View {
    let openItems: Int
    let onClose: (String) async -> String?
    let dismiss: () -> Void
    @State private var summary = ""
    @State private var isClosing = false
    @State private var error: String?

    private var trimmed: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MissionDetailView.confirmationTitle(openItems: openItems))
                .font(.system(size: 17, weight: .semibold))
            Text("The items stay open and keep their mission. The close is recorded on it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("How it went", text: $summary, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .disabled(isClosing)
                .accessibilityLabel("Closing summary")
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red)
            }
            HStack {
                if isClosing { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Keep it open", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isClosing)
                Button("Close mission", role: .destructive) { close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isClosing || trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func close() {
        isClosing = true
        error = nil
        Task {
            let failure = await onClose(trimmed)
            isClosing = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

/// The milestone timeline: dot (purple for your input, blue for progress),
/// a line joining them, full title and body, age at the right. A click
/// opens the transcript at that milestone. Shows `pageSize` rows, then
/// "Show more" — a long mission's page never lays out every milestone.
struct MacMilestonesCard: View {
    static let initialCount = 5
    static let pageSize = 20

    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    @State private var limit = MacMilestonesCard.initialCount
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = model.milestones.prefix(limit)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                MacMissionSectionLabel("Milestones")
                Spacer(minLength: 12)
                Toggle("Only your inputs", isOn: Binding(get: { model.showOnlyUserInput },
                                                         set: { actions.onToggleUserInputOnly($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .accessibilityIdentifier("missionPage.onlyYourInputs")
            }
            if model.milestones.isEmpty {
                Text(model.showOnlyUserInput ? "No milestones from you yet." : "No milestones yet.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, milestone in
                        Button { actions.onOpenMilestone(milestone) } label: {
                            MacMilestoneRow(milestone: milestone, parsedBody: model.milestoneBodies[milestone.id],
                                            tag: tagText(model.sessionTags[milestone.convoID]),
                                            isLast: index == shown.count - 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the conversation at this point")
                    }
                }
                let more = model.milestones.count - shown.count
                if more > 0 {
                    Button("Show more (\(more))") { limit += Self.pageSize }
                        .buttonStyle(.link)
                        .font(.system(size: 14))
                        .accessibilityIdentifier("missionPage.milestones.showMore")
                }
            }
        }
        .macMissionCard()
    }

    private func tagText(_ tag: SessionTagInputs?) -> Text? {
        guard let tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }
}

/// One timeline row. `parsedBody` is the pre-parsed milestone body.
struct MacMilestoneRow: View {
    let milestone: Milestone
    let parsedBody: AttributedString?
    let tag: Text?
    let isLast: Bool
    @Environment(\.macMissionPageClock) private var fixedNow

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle().fill(MacMissionPalette.milestoneTint(milestone.kind))
                    .frame(width: 12, height: 12)
                    .padding(.top, 5)
                Rectangle().fill(isLast ? Color.clear : Color.primary.opacity(0.12))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(milestone.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    MacMinuteText { MissionBoard.ago(milestone.createdAt, now: $0) }
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let parsedBody {
                    Text(parsedBody)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tag { tag.font(.system(size: 12)) }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: milestone, now: fixedNow ?? Date()))
    }

    /// Kind, number, title, body and age — VoiceOver hears what the row
    /// shows (the explicit label replaces `.combine`'s own merge).
    static func accessibilityLabel(for milestone: Milestone, now: Date) -> String {
        var parts = ["\(MissionGlyph.label(milestone.kind)) \(milestone.num)", milestone.title]
        let body = milestone.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !body.isEmpty { parts.append(body) }
        parts.append(MissionsDashboardFormat.relative(milestone.createdAt, now: now))
        return parts.joined(separator: ", ")
    }
}

/// A mission's conversations, On it now / Earlier (spec §2, mockup 03 left).
struct MacMissionConversationsCard: View {
    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.macMissionPageClock) private var fixedNow

    var body: some View {
        let groups = model.conversationGroups
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MacMissionSectionLabel("Conversations")
                Text(ProjectsFormat.conversationsSummary(groups).uppercased())
                    .font(.system(size: 12)).tracking(0.6).foregroundStyle(.tertiary)
            }
            if groups.onItNow.isEmpty && groups.earlier.isEmpty {
                Text("No conversations yet.").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            if !groups.onItNow.isEmpty { group("On it now", groups.onItNow) }
            if !groups.earlier.isEmpty { group("Earlier", groups.earlier) }
        }
        .macMissionCard()
    }

    private func group(_ title: String, _ rows: [MissionConversationRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                .padding(.vertical, 6)
            ForEach(rows) { row in
                Divider()
                MacMissionConversationRow(row: row, tag: tagText(row.id), age: age(row.id),
                                          onOpen: actions.onOpenConversation, onOpenMission: actions.onOpenMission)
            }
        }
    }

    private func tagText(_ convoID: String) -> Text? {
        guard let tag = model.sessionTags[convoID] ?? model.sessions.first(where: { $0.id == convoID })?.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }

    private func age(_ convoID: String) -> String? {
        guard let last = model.sessions.first(where: { $0.id == convoID })?.lastActivity else { return nil }
        return MissionBoard.ago(last, now: fixedNow ?? Date())
    }
}

struct MacMissionConversationRow: View {
    let row: MissionConversationRow
    let tag: Text?
    let age: String?
    let onOpen: (String) -> Void
    /// The `also on #N` / `moved to #N` chip's target (mockup 03).
    let onOpenMission: (String) -> Void
    @State private var showSubchats = false

    /// The row is a tap target, not a `Button`: the chip inside it is a
    /// button of its own, and a button nested in a button's label never
    /// fires on its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DashboardStateDot(state: row.state)
                if let tag { tag.font(.system(size: 13)) } else if let box = row.conversation.box { BoxChip(box) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.conversation.title.isEmpty ? row.id : row.conversation.title)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(meta).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        if let linked = row.linkedMission {
                            LinkedMissionChip(linked: linked) { onOpenMission(linked.link.id) }
                        }
                    }
                }
                Spacer(minLength: 8)
                if let age { Text(age).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(row.id) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(row.id) }
            subchats
        }
        .padding(.vertical, 8)
    }

    private var meta: String {
        [row.conversation.box,
         ProjectsFormat.linkSpan(joinedAt: row.conversation.joinedAt, endedAt: row.conversation.endedAt,
                                 how: row.conversation.how)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var subchats: some View {
        if !row.subchats.isEmpty {
            DisclosureGroup("\(row.subchats.count) sub-chat\(row.subchats.count == 1 ? "" : "s")", isExpanded: $showSubchats) {
                ForEach(row.subchats) { child in
                    Button(child.title.isEmpty ? child.id : child.title) { onOpen(child.id) }
                        .buttonStyle(.plain).font(.system(size: 14))
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 20)
        } else if row.subchatCount > 0 {
            Text("\(row.subchatCount) sub-chat\(row.subchatCount == 1 ? "" : "s")")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 20)
        }
    }
}
