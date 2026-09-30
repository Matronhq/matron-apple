import SwiftUI
import MatronModels

/// One mission page (spec: Apps → Missions tab → Page). Leaf view: header,
/// milestones newest first with a "My inputs only" toggle, open items, and
/// the conversations the mission owns, plus the user's close control.
public struct MissionDetailView: View {
    public struct Model: Equatable {
        /// One milestone as the page draws it: the record, plus the `A:bc`
        /// tag of the conversation it was posted in — a mission spans
        /// several sessions, so each row says which one it came from.
        /// `nil` when this device has no cached row for that conversation:
        /// the row then renders with no tag, never a placeholder.
        public struct MilestoneRow: Identifiable, Equatable {
            public var milestone: Milestone
            public var sessionTag: SessionTagInputs?
            public var id: String { milestone.id }
            public init(milestone: Milestone, sessionTag: SessionTagInputs? = nil) {
                self.milestone = milestone
                self.sessionTag = sessionTag
            }
        }

        public var mission: Mission?
        public var project: Project?
        public var milestones: [MilestoneRow]
        public var openItems: [TrackerItem]
        public var conversations: [MissionConversation]
        /// `A:bc` tags for the conversation rows.
        public var conversationTags: [String: SessionTagInputs]
        public var moveTargets: [Project]
        /// The view model's On it now / Earlier groups (live session state
        /// applied). `nil` only in previews and snapshots, where `groups`
        /// builds them from `conversations` alone.
        public var conversationGroups: MissionConversationGroups?
        public var showOnlyUserInput: Bool
        public var closeSummary: String
        public var isBusy: Bool
        public init(mission: Mission?, project: Project? = nil, milestones: [MilestoneRow], openItems: [TrackerItem],
                    conversations: [MissionConversation], conversationTags: [String: SessionTagInputs] = [:],
                    moveTargets: [Project] = [], conversationGroups: MissionConversationGroups? = nil,
                    showOnlyUserInput: Bool, closeSummary: String, isBusy: Bool) {
            self.mission = mission; self.project = project; self.milestones = milestones; self.openItems = openItems
            self.conversations = conversations; self.conversationTags = conversationTags; self.moveTargets = moveTargets
            self.conversationGroups = conversationGroups
            self.showOnlyUserInput = showOnlyUserInput; self.closeSummary = closeSummary; self.isBusy = isBusy
        }

        /// The On it now / Earlier split (spec §2): the view model's
        /// `conversationGroups` when the host passed them, else built from
        /// `conversations` and the mission's state (no live states).
        public var groups: MissionConversationGroups {
            conversationGroups ?? MissionConversationGroups(conversations: conversations,
                                                            missionState: mission?.state ?? .open)
        }
        public var needsYouItems: [TrackerItem] { openItems.filter { $0.awaiting == .user } }
        public var otherItems: [TrackerItem] { openItems.filter { $0.awaiting != .user } }

        /// The ONE mapping from a `MissionDetailViewModel`'s published
        /// values into this model. Both hosts call it — `MissionDetailHost`
        /// (Task 9) and `MacMissionPage` (Task 10) — so the two platforms'
        /// mission pages cannot drift. It takes plain values rather than
        /// the view model itself because `MatronDesignSystem` is a leaf: it
        /// may depend on Models/Events, never on `MatronViewModels`.
        public init(mission: Mission?, project: Project? = nil, milestones: [Milestone],
                    sessionTags: [String: SessionTagInputs], openItems: [TrackerItem],
                    conversations: [MissionConversation], moveTargets: [Project] = [],
                    conversationGroups: MissionConversationGroups? = nil, showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.init(mission: mission, project: project,
                      milestones: milestones.map { MilestoneRow(milestone: $0, sessionTag: sessionTags[$0.convoID]) },
                      openItems: openItems, conversations: conversations, conversationTags: sessionTags,
                      moveTargets: moveTargets, conversationGroups: conversationGroups,
                      showOnlyUserInput: showOnlyUserInput,
                      closeSummary: closeSummary, isBusy: isBusy)
        }
    }

    let model: Model
    let onToggleUserInputOnly: (Bool) -> Void
    /// The milestone's conversation and its anchor seq — the host opens the
    /// transcript there.
    let onOpenMilestone: (Milestone) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void
    let onEditCloseSummary: (String) -> Void
    let onClose: () -> Void
    /// Retries the detail fetch — same closure the Missions list's own
    /// header/pull-to-refresh takes. Wired to the "Try again" action in the
    /// `mission == nil` placeholder and, on iOS, to `.refreshable` there.
    let onRefresh: () async -> Void
    /// Opens the project this mission is filed in — the header chip.
    let onOpenProject: ((String) -> Void)?
    /// Moves this mission to another project, or `nil` to unfile it.
    let onMove: ((String?) -> Void)?
    /// Opens another mission a conversation row is "also on" / "moved to".
    let onOpenMission: ((String) -> Void)?
    public static let initialMilestones = 5
    public static let milestonePage = 20
    @State private var showingClose = false
    @State private var milestoneLimit = MissionDetailView.initialMilestones
    /// `SessionTagText` tints a box letter with `BoxChip.textTint(for:in:)`,
    /// which needs the scheme — the same environment read `ChatView`'s
    /// header does for its own tag.
    @Environment(\.colorScheme) private var colorScheme

    public init(model: Model, onToggleUserInputOnly: @escaping (Bool) -> Void,
                onOpenMilestone: @escaping (Milestone) -> Void, onOpenItem: @escaping (String) -> Void,
                onOpenConversation: @escaping (String) -> Void, onEditCloseSummary: @escaping (String) -> Void,
                onClose: @escaping () -> Void, onRefresh: @escaping () async -> Void,
                onOpenProject: ((String) -> Void)? = nil, onMove: ((String?) -> Void)? = nil,
                onOpenMission: ((String) -> Void)? = nil) {
        self.model = model; self.onToggleUserInputOnly = onToggleUserInputOnly
        self.onOpenMilestone = onOpenMilestone; self.onOpenItem = onOpenItem
        self.onOpenConversation = onOpenConversation; self.onEditCloseSummary = onEditCloseSummary
        self.onClose = onClose; self.onRefresh = onRefresh
        self.onOpenProject = onOpenProject; self.onMove = onMove; self.onOpenMission = onOpenMission
    }

    public var body: some View {
        if let mission = model.mission {
            List {
                Section { header(mission) }
                if let status = mission.status { Section { statusCard(status, mission: mission) } }
                if !model.needsYouItems.isEmpty { needsYouSection }
                if !model.conversations.isEmpty { conversationsSection }
                milestonesSection
                if !model.otherItems.isEmpty {
                    Section("Open items") { ForEach(model.otherItems) { itemButton($0) } }
                }
                if mission.state == .open {
                    Section("Close this mission") { closeControls }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MatronTimelineBackground())
            #else
            .listStyle(.inset)
            #endif
            .confirmationDialog(Self.confirmationTitle(openItems: model.openItems.count),
                               isPresented: $showingClose, titleVisibility: .visible) {
                Button("Close mission", role: .destructive) { onClose() }
                Button("Keep it open", role: .cancel) {}
            } message: {
                Text("The items stay open and keep their mission. The close is recorded on it.")
            }
        } else {
            missionUnavailable
        }
    }

    /// The `mission == nil` leaf: not cached yet, or a refresh just failed.
    /// A retry action either way — the view model has no way to tell "still
    /// syncing" from "the last attempt failed" apart from `error` (surfaced
    /// separately, via the alert both hosts wire), so this placeholder
    /// always offers a way to try again rather than dead-ending (MAJOR-4).
    @ViewBuilder
    private var missionUnavailable: some View {
        let content = ContentUnavailableView {
            Label("Mission not on this device yet", systemImage: "flag.checkered")
        } description: {
            Text("It will appear once this device syncs it.")
        } actions: {
            Button("Try again") { Task { await onRefresh() } }
        }
        #if os(iOS)
        GeometryReader { geo in
            ScrollView { content.frame(width: geo.size.width, height: geo.size.height) }
                .refreshable { await onRefresh() }
        }
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// The close confirmation's title — what the user actually sees, and
    /// what the "close confirmation counts" requirement is pinned on now
    /// (moved from the view model's dead `closeConfirmation` property,
    /// MINOR-2). `static` so it is testable without a view.
    public static func confirmationTitle(openItems: Int) -> String {
        openItems == 0
            ? "Close this mission?"
            : "Close with \(openItems) item\(openItems == 1 ? "" : "s") still open?"
    }

    private func header(_ mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(mission.title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Text(MissionGlyph.label(mission.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MissionGlyph.tint(mission.state))
            }
            if model.project != nil || (onMove != nil && mission.state == .open) {
                HStack(spacing: 8) {
                    if let project = model.project {
                        ProjectChip(title: project.title, action: onOpenProject.map { open in { open(project.id) } })
                    }
                    if let onMove, mission.state == .open {
                        MoveToProjectMenu(currentProjectID: mission.projectID, targets: model.moveTargets, onMove: onMove)
                            .font(.caption)
                            #if os(iOS)
                            .menuStyle(.button)
                            #endif
                    }
                }
            }
            if !mission.body.isEmpty { MarkdownText(mission.body).font(.subheadline) }
            if let summary = mission.closeSummary, !summary.isEmpty {
                Divider()
                Text("Closed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownText(summary).font(.subheadline)
                if mission.closedOverOpenItems > 0 {
                    Text("Closed over \(mission.closedOverOpenItems) open item\(mission.closedOverOpenItems == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func milestoneRow(_ row: Model.MilestoneRow) -> some View {
        let milestone = row.milestone
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: MissionGlyph.symbol(milestone.kind))
                .font(.caption)
                .foregroundStyle(MissionGlyph.tint(milestone.kind))
                .frame(width: 16).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(milestone.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(milestone.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if !milestone.body.isEmpty {
                    Text(milestone.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    RelativeMinuteTimeView(milestone.createdAt).font(.caption2).foregroundStyle(.tertiary)
                    // `SessionTagText` is an enum of `Text` factories, not a
                    // view: `room` composes one letter per participating
                    // box (each in its own hue) and the `:bc` short, and
                    // `run` is the single-box form — the same fallback
                    // order chat headers and list rows use (Bugbot: this
                    // row called `run` only, so a room conversation showed
                    // as an owner-box `A:bc` instead of `A↔B:bc`). Either
                    // answers `nil` when there is nothing to show. No
                    // cached conversation ⇒ no `sessionTag` ⇒ nothing
                    // rendered, no empty gap. Do NOT restyle the result
                    // with `.foregroundStyle` — that would flatten the
                    // per-run box color.
                    if let tag = row.sessionTag,
                       let tagRun = SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                                        sessionShort: tag.sessionShort, colorScheme: colorScheme)
                        ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                              sessionShort: tag.sessionShort, colorScheme: colorScheme) {
                        tagRun.font(.caption2)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(MissionGlyph.label(milestone.kind)) \(milestone.num), \(milestone.title)"
                            // Same room-first fallback as the visual tag
                            // above — a `boxName`-only label omitted the
                            // other room boxes and the session short
                            // (CodeRabbit #209); speaks box NAMES, not
                            // the visual run's single-letter glyphs (fix
                            // round 2, H3).
                            + (row.sessionTag.flatMap {
                                SessionTagText.plainLabel(boxName: $0.boxName, sessionShort: $0.sessionShort,
                                                          roomBoxNames: $0.roomBoxNames)
                            }.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the conversation at this point")
    }

    private func statusCard(_ status: String, mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let byline = MissionsDashboardFormat.statusByline(updatedAt: mission.statusUpdatedAt, by: mission.statusBy, now: Date()) {
                Text("STATUS · \(byline)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("STATUS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(MissionsDashboardFormat.statusText(status)).font(.body)
        }
    }

    private var needsYouSection: some View {
        Section {
            ForEach(model.needsYouItems) { itemButton($0) }
        } header: {
            Text("Needs you · \(model.needsYouItems.count)").foregroundStyle(.red)
        }
    }

    private func itemButton(_ item: TrackerItem) -> some View {
        Button { onOpenItem(item.id) } label: { ItemRow(item: item) }
            .buttonStyle(.plain).foregroundStyle(Color.primary)
    }

    private var conversationsSection: some View {
        let groups = model.groups
        return Section {
            if !groups.onItNow.isEmpty {
                Text("ON IT NOW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups.onItNow) { conversationRow($0) }
            }
            if !groups.earlier.isEmpty {
                Text("EARLIER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups.earlier) { conversationRow($0) }
            }
        } header: {
            HStack {
                Text("Conversations")
                Spacer()
                Text(ProjectsFormat.conversationsSummary(groups)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Not a `Button`: the row holds a second button (the `#N` chip), and
    /// a button inside a button's label never fires on its own. The row's
    /// own tap and accessibility action open the conversation; the
    /// borderless chip opens the other mission.
    @ViewBuilder private func conversationRow(_ row: MissionConversationRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DashboardStateDot(state: row.state)
            conversationTag(row.conversation)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.conversation.title.isEmpty ? row.id : row.conversation.title)
                    .font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(conversationMeta(row.conversation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let linked = row.linkedMission, let onOpenMission {
                        LinkedMissionChip(linked: linked) { onOpenMission(linked.link.id) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenConversation(row.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenConversation(row.id) }
        if !row.subchats.isEmpty {
            DisclosureGroup("\(row.subchats.count) sub-chat\(row.subchats.count == 1 ? "" : "s")") {
                ForEach(row.subchats) { child in
                    Button { onOpenConversation(child.id) } label: {
                        Text(child.title.isEmpty ? child.id : child.title).font(.subheadline).lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
            }
            .font(.caption).padding(.leading, 24)
        } else if row.subchatCount > 0 {
            Text("\(row.subchatCount) sub-chat\(row.subchatCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
        }
    }

    @ViewBuilder private func conversationTag(_ convo: MissionConversation) -> some View {
        if let tag = model.conversationTags[convo.id],
           let run = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                        sessionShort: tag.sessionShort, colorScheme: colorScheme) {
            run.font(.caption)
        } else if let box = convo.box {
            BoxChip(box)
        }
    }

    private func conversationMeta(_ convo: MissionConversation) -> String {
        [convo.box, ProjectsFormat.linkSpan(joinedAt: convo.joinedAt, endedAt: convo.endedAt, how: convo.how)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var milestonesSection: some View {
        Section {
            if model.milestones.isEmpty {
                Text(model.showOnlyUserInput ? "No milestones from you yet." : "No milestones yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(model.milestones.prefix(milestoneLimit)) { row in
                    Button { onOpenMilestone(row.milestone) } label: { milestoneRow(row) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                let more = model.milestones.count - min(milestoneLimit, model.milestones.count)
                if more > 0 {
                    Button("Show more (\(more))") { milestoneLimit += Self.milestonePage }
                        .accessibilityIdentifier("missionDetail.milestones.showMore")
                }
            }
        } header: {
            HStack {
                Text("Milestones")
                Spacer()
                Toggle("My inputs only", isOn: Binding(get: { model.showOnlyUserInput },
                                                       set: { onToggleUserInputOnly($0) }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("My inputs only")
            }
        }
    }

    private var closeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("How it went", text: Binding(get: { model.closeSummary }, set: { onEditCloseSummary($0) }),
                      axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Closing summary")
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Close mission") { showingClose = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.closeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
