import SwiftUI
import MatronDesignSystem
import MatronModels

/// The Overview: Latest step and Milestones on the left (~60%); Needs you,
/// Sessions, Open tasks & decisions and the close control on the right.
/// One column, in that order, when `twoColumns` is false.
struct MacMissionOverview: View {
    let model: MacMissionPageModel
    let now: Date
    let actions: MacMissionPageActions
    /// The page's content width (`MacMissionPageLayout.contentWidth`).
    let contentWidth: CGFloat

    var body: some View {
        if MacMissionPageLayout.usesTwoColumns(contentWidth: contentWidth) {
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
            latestStepCard
            MacMilestonesCard(model: model, now: now, actions: actions)
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            needsYouCard
            sessionsCard
            openItemsCard
        }
    }

    // MARK: Latest step

    private var latestStepCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacMissionSectionLabel("Latest step")
            if let step = model.latestStep {
                Button { actions.onOpenMilestone(step) } label: { latestStepRow(step) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the conversation at this point")
            } else {
                Text("No milestones yet.").font(.system(size: 16)).foregroundStyle(.secondary)
            }
        }
        .macMissionCard()
    }

    private func latestStepRow(_ step: Milestone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(MacMissionPalette.milestoneTint(step.kind)).frame(width: 11, height: 11)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(latestStepMeta(step)).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// "Progress · 14m ago · in Missions Navigation Refinement".
    private func latestStepMeta(_ step: Milestone) -> String {
        var parts = [MissionGlyph.label(step.kind), MissionsDashboardFormat.relative(step.createdAt, now: now)]
        if let title = model.conversationTitle(step.convoID) { parts.append("in \(title)") }
        return parts.joined(separator: " · ")
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

    // MARK: Sessions

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacMissionSectionLabel("Sessions")
            if model.sessions.isEmpty {
                Text("No sessions yet.").font(.system(size: 15)).foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { session in
                    Button { actions.onOpenConversation(session.id) } label: { MacMissionSessionRow(session: session) }
                        .buttonStyle(.plain)
                }
            }
        }
        .macMissionCard()
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

/// One session: state dot, box/session tag, title, then two lines of
/// summary — the dashboard's `DashboardSessionRow` rules at the page's
/// larger size (its fonts are fixed for the cards).
struct MacMissionSessionRow: View {
    let session: DashboardSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DashboardStateDot(state: session.state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    tag
                    Text(session.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                if let summary = session.summary {
                    Text(summary).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DashboardSessionRow.accessibilityLabel(for: session, showsNeedsYou: false))
    }

    /// Room tag, then the single-box tag, then a bare box chip — the same
    /// fallback order as `DashboardSessionRow`. Never restyled (that would
    /// flatten the per-box colour).
    @ViewBuilder private var tag: some View {
        if let tagText { tagText.font(.system(size: 13)) } else if let box = session.boxName { BoxChip(box) }
    }

    private var tagText: Text? {
        guard let tag = session.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
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
            .sheet(isPresented: $showingSheet) { sheet }
        } else {
            closedSummary
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MissionDetailView.confirmationTitle(openItems: model.openItems.count))
                .font(.system(size: 17, weight: .semibold))
            Text("The items stay open and keep their mission. The close is recorded on it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("How it went", text: Binding(get: { model.closeSummary }, set: { actions.onEditCloseSummary($0) }),
                      axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Closing summary")
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Keep it open", role: .cancel) { showingSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Close mission", role: .destructive) {
                    actions.onClose()
                    showingSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.closeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
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

/// The milestone timeline: dot (purple for your input, blue for progress),
/// a line joining them, full title and body, age at the right. A click
/// opens the transcript at that milestone.
struct MacMilestonesCard: View {
    let model: MacMissionPageModel
    let now: Date
    let actions: MacMissionPageActions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                    ForEach(Array(model.milestones.enumerated()), id: \.element.id) { index, milestone in
                        Button { actions.onOpenMilestone(milestone) } label: {
                            row(milestone, isLast: index == model.milestones.count - 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the conversation at this point")
                    }
                }
            }
        }
        .macMissionCard()
    }

    private func row(_ milestone: Milestone, isLast: Bool) -> some View {
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
                    Text(MissionBoard.ago(milestone.createdAt, now: now))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !milestone.body.isEmpty {
                    Text(MissionsDashboardFormat.statusText(milestone.body))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tag = model.sessionTags[milestone.convoID],
                   let run = SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                                 sessionShort: tag.sessionShort, colorScheme: colorScheme)
                    ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                          sessionShort: tag.sessionShort, colorScheme: colorScheme) {
                    run.font(.system(size: 12))
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(MissionGlyph.label(milestone.kind)) \(milestone.num), \(milestone.title)")
    }
}
