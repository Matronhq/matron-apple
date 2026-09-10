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
        public var milestones: [MilestoneRow]
        public var openItems: [TrackerItem]
        public var conversations: [MissionConversation]
        public var showOnlyUserInput: Bool
        public var closeSummary: String
        public var isBusy: Bool
        public init(mission: Mission?, milestones: [MilestoneRow], openItems: [TrackerItem],
                    conversations: [MissionConversation], showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.mission = mission; self.milestones = milestones; self.openItems = openItems
            self.conversations = conversations; self.showOnlyUserInput = showOnlyUserInput
            self.closeSummary = closeSummary; self.isBusy = isBusy
        }

        /// The ONE mapping from a `MissionDetailViewModel`'s published
        /// values into this model. Both hosts call it — `MissionDetailHost`
        /// (Task 9) and `MacMissionPage` (Task 10) — so the two platforms'
        /// mission pages cannot drift. It takes plain values rather than
        /// the view model itself because `MatronDesignSystem` is a leaf: it
        /// may depend on Models/Events, never on `MatronViewModels`.
        public init(mission: Mission?, milestones: [Milestone],
                    sessionTags: [String: SessionTagInputs], openItems: [TrackerItem],
                    conversations: [MissionConversation], showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.init(mission: mission,
                      milestones: milestones.map {
                          MilestoneRow(milestone: $0, sessionTag: sessionTags[$0.convoID])
                      },
                      openItems: openItems,
                      conversations: conversations,
                      showOnlyUserInput: showOnlyUserInput,
                      closeSummary: closeSummary,
                      isBusy: isBusy)
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
    @State private var showingClose = false
    /// `SessionTagText` tints a box letter with `BoxChip.textTint(for:in:)`,
    /// which needs the scheme — the same environment read `ChatView`'s
    /// header does for its own tag.
    @Environment(\.colorScheme) private var colorScheme

    public init(model: Model, onToggleUserInputOnly: @escaping (Bool) -> Void,
                onOpenMilestone: @escaping (Milestone) -> Void, onOpenItem: @escaping (String) -> Void,
                onOpenConversation: @escaping (String) -> Void, onEditCloseSummary: @escaping (String) -> Void,
                onClose: @escaping () -> Void) {
        self.model = model; self.onToggleUserInputOnly = onToggleUserInputOnly
        self.onOpenMilestone = onOpenMilestone; self.onOpenItem = onOpenItem
        self.onOpenConversation = onOpenConversation; self.onEditCloseSummary = onEditCloseSummary
        self.onClose = onClose
    }

    public var body: some View {
        if let mission = model.mission {
            List {
                Section { header(mission) }
                Section {
                    if model.milestones.isEmpty {
                        Text(model.showOnlyUserInput ? "No milestones from you yet." : "No milestones yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.milestones) { row in
                            Button { onOpenMilestone(row.milestone) } label: { milestoneRow(row) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Milestones")
                        Spacer()
                        Toggle("My inputs only", isOn: Binding(
                            get: { model.showOnlyUserInput },
                            set: { onToggleUserInputOnly($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("My inputs only")
                    }
                }
                if !model.openItems.isEmpty {
                    Section("Open items") {
                        ForEach(model.openItems) { item in
                            Button { onOpenItem(item.id) } label: { ItemRow(item: item) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
                }
                if !model.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(model.conversations) { convo in
                            Button { onOpenConversation(convo.id) } label: { conversationRow(convo) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
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
            .confirmationDialog(confirmationTitle, isPresented: $showingClose, titleVisibility: .visible) {
                Button("Close mission", role: .destructive) { onClose() }
                Button("Keep it open", role: .cancel) {}
            } message: {
                Text("The items stay open and keep their mission. The close is recorded on it.")
            }
        } else {
            ContentUnavailableView("Mission not on this device yet", systemImage: "flag.checkered",
                                   description: Text("It will appear once this device syncs it."))
        }
    }

    private var confirmationTitle: String {
        model.openItems.isEmpty
            ? "Close this mission?"
            : "Close with \(model.openItems.count) item\(model.openItems.count == 1 ? "" : "s") still open?"
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
                    // view: `run` composes the letter (in the box's hue) and
                    // the `:bc` short into one `Text`, and answers `nil`
                    // when there is nothing to show. No cached conversation
                    // ⇒ no `sessionTag` ⇒ nothing rendered, no empty gap.
                    // Do NOT restyle the result with `.foregroundStyle` —
                    // that would flatten the per-run box color.
                    if let tag = row.sessionTag,
                       let tagRun = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                                       sessionShort: tag.sessionShort,
                                                       colorScheme: colorScheme) {
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
                            + (row.sessionTag?.boxName.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the conversation at this point")
    }

    private func conversationRow(_ convo: MissionConversation) -> some View {
        HStack(spacing: 8) {
            if let box = convo.box { BoxChip(box) }
            Text(convo.title.isEmpty ? convo.id : convo.title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
            Text(convo.state).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
