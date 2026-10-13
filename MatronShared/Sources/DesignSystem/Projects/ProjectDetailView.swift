import SwiftUI
import MatronModels

/// The project page as one `List` (spec §6: "a single List on iOS"),
/// latest first: the status as the headline, Needs you, the merged
/// "Latest" feed, the missions, then the reference sections folded
/// (decisions, files, sessions, other open items, the description). The
/// Mac draws its own two-column page from the same `ProjectPageModel`.
///
/// Decisions and files are the journal's roll-up (Projects view v2);
/// without it (`hasFeed` false) the feed is today's latest milestones and
/// the open items, and those two folds do not show.
public struct ProjectDetailView: View {
    let page: ProjectPageModel
    let now: Date?
    /// Feed kinds with a "Show more" in flight (`ProjectDetailViewModel.loadingMore`).
    let loadingMore: Set<ProjectFeedKind>
    /// File thumbnails the host has loaded, by blob id.
    let images: [String: Image]
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenSession: (String) -> Void
    let onOpenMilestone: (Milestone) -> Void
    let onOpenFile: (ProjectFile) -> Void
    let onLoadMore: (ProjectFeedKind) -> Void
    /// "Show more" on the Latest feed once every loaded row shows: the
    /// host fetches the next page of every kind that has one.
    let onLoadMoreActivity: () -> Void
    let onMoveMission: (String, String) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false
    @State private var showsAllItems = false
    /// Rows the Latest feed shows before its next "Show more"; nil once
    /// every loaded row shows.
    @State private var activityLimit: Int? = ProjectActivity.firstPageLimit
    @State private var expanded: Set<ProjectReferenceSection>

    public init(page: ProjectPageModel, now: Date? = nil, loadingMore: Set<ProjectFeedKind> = [],
                images: [String: Image] = [:], expanded: Set<ProjectReferenceSection> = [],
                onOpenMission: @escaping (String) -> Void,
                onOpenItem: @escaping (String) -> Void, onOpenSession: @escaping (String) -> Void,
                onOpenMilestone: @escaping (Milestone) -> Void, onOpenFile: @escaping (ProjectFile) -> Void = { _ in },
                onLoadMore: @escaping (ProjectFeedKind) -> Void = { _ in },
                onLoadMoreActivity: @escaping () -> Void = {},
                onMoveMission: @escaping (String, String) -> Void, onRefresh: @escaping () async -> Void) {
        self.page = page; self.now = now; self.loadingMore = loadingMore; self.images = images
        self.onOpenMission = onOpenMission; self.onOpenItem = onOpenItem; self.onOpenSession = onOpenSession
        self.onOpenMilestone = onOpenMilestone; self.onOpenFile = onOpenFile; self.onLoadMore = onLoadMore
        self.onLoadMoreActivity = onLoadMoreActivity
        self.onMoveMission = onMoveMission; self.onRefresh = onRefresh
        _expanded = State(initialValue: expanded)
    }

    public var body: some View {
        List {
            Section { headline }
            if !page.needsYou.isEmpty { needsYouSection }
            latestSection
            missionsSection
            ForEach(ProjectReferenceSection.allCases.filter { $0.isShown(page) }) { section in
                fold(section)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MatronTimelineBackground())
        .refreshable { await onRefresh() }
        #else
        .listStyle(.inset)
        #endif
        // The description and status are plain `Text`s: their `matron://`
        // links open in-app through the hosts' environment actions.
        .inAppLinks()
    }

    private var clock: Date { now ?? Date() }

    // MARK: Headline

    /// The title is the navigation bar's, so the card opens on the status
    /// (the description when there is none), with Needs you beside its
    /// caption and the pulse line under it.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ProjectActivityFormat.headlineCaption(page.project, now: clock))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                NeedsYouPill(count: page.needsYouCount)
            }
            Text(MissionsDashboardFormat.statusText(ProjectActivityFormat.headlineText(page.project))).font(.body)
            ProjectPulseLine(page: page, now: clock)
        }
        .accessibilityIdentifier("projects.page.headline")
    }

    private var needsYouSection: some View {
        Section {
            ForEach(page.needsYou) { item in
                Button { onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).lineLimit(2)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let num = item.missionNum { missionChip(num) }
                            Text(MissionBoard.ago(item.createdAt, now: clock))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        } header: {
            Text("Needs you · \(page.needsYouCount)").foregroundStyle(.red)
        }
    }

    // MARK: Latest

    private var latestSection: some View {
        let rows = ProjectActivity.rows(page, limit: activityLimit)
        let loading = !loadingMore.isEmpty
        return Section {
            if rows.isEmpty, !loading {
                Text(ProjectActivityFormat.empty).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(ProjectActivityFormat.sections(rows, now: clock)) { day in
                Text(day.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(day.events) { event in
                    Button { open(event) } label: {
                        ProjectActivityRow(event: event, image: thumbnail(event), time: ProjectActivityFormat.time(event))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
            }
            if ProjectActivity.hasMore(page, limit: activityLimit) {
                HStack(spacing: 8) {
                    Button(ProjectActivityFormat.showMore) { showMoreActivity() }
                        .disabled(loading)
                        .accessibilityIdentifier("projects.page.activity.more")
                    if loading { ProgressView().controlSize(.small) }
                }
            }
        } header: {
            Text(ProjectActivityFormat.heading)
        }
    }

    /// "Show more": first the rows already loaded past the fold, then the
    /// next page of every kind that has one.
    private func showMoreActivity() {
        let shown = ProjectActivity.rows(page, limit: activityLimit).count
        let loaded = ProjectActivity.rows(page, limit: nil).count
        if shown < loaded {
            activityLimit = shown + ProjectActivity.showMoreStep
        } else {
            activityLimit = nil
            onLoadMoreActivity()
        }
    }

    private func open(_ event: ProjectActivityEvent) {
        switch event {
        case .milestone(let m): onOpenMilestone(m.milestone)
        case .decision(let d): onOpenItem(d.id)
        case .file(let f): onOpenFile(f)
        case .item(let i): onOpenItem(i.id)
        }
    }

    private func thumbnail(_ event: ProjectActivityEvent) -> Image? {
        if case .file(let f) = event { return images[f.blobID] }
        return nil
    }

    // MARK: Missions

    private var missionsSection: some View {
        Section("Missions · \(page.missions.count)") {
            ForEach(page.missions) { row in
                Button { onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MissionRowView(row: row, now: now)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [],
                                        roomCount: page.roomCountsByMission[row.id] ?? 0)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID,
                                      targets: page.moveTargets) { onMoveMission(row.id, $0) }
                }
            }
            if !page.closedMissions.isEmpty {
                DisclosureGroup("Closed (\(page.closedMissions.count))", isExpanded: $showClosed) {
                    ForEach(page.closedMissions) { mission in
                        Button { onOpenMission(mission.id) } label: {
                            MissionRowView(row: MissionRowModel(closed: mission), now: now)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }

    // MARK: Reference folds

    private func fold(_ section: ProjectReferenceSection) -> some View {
        Section {
            DisclosureGroup(isExpanded: isExpanded(section)) {
                foldContent(section)
            } label: {
                ProjectFoldLabel(section: section, detail: section.detail(page))
            }
            .accessibilityIdentifier("projects.page.fold.\(section.rawValue)")
        }
    }

    private func isExpanded(_ section: ProjectReferenceSection) -> Binding<Bool> {
        Binding(get: { expanded.contains(section) },
                set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })
    }

    @ViewBuilder private func foldContent(_ section: ProjectReferenceSection) -> some View {
        switch section {
        case .decisions: decisionRows
        case .files: filesGrid
        case .sessions: sessionRows
        case .otherItems: otherItemRows
        case .about:
            Text(MissionsDashboardFormat.statusText(page.project.body)).font(.subheadline)
                .foregroundStyle(ProjectActivityFormat.bodyTextColor)
        }
    }

    @ViewBuilder private var decisionRows: some View {
        ForEach(page.decisions.rows) { decision in
            Button { onOpenItem(decision.id) } label: { decisionRow(decision) }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
        }
        if page.decisions.hasMore { showAll(.decisions, title: "Show all") }
    }

    private func decisionRow(_ decision: ProjectDecision) -> some View {
        let mark = ProjectDecisionMark(decision)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.symbol).foregroundStyle(mark.tint).accessibilityLabel(mark.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.title).lineLimit(3).strikethrough(mark.isStruck)
                    .foregroundStyle(mark.isStruck ? Color.secondary : Color.primary)
                if let answer = decision.answer, !answer.isEmpty {
                    Text(answer).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let num = decision.missionNum { missionChip(num) }
                Text(ProjectFeedFormat.dayLabel(decision.at, now: clock)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var filesGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                  alignment: .leading, spacing: 12) {
            ForEach(page.files.rows) { file in
                Button { onOpenFile(file) } label: {
                    ProjectFileTile(file: file, image: images[file.blobID], now: clock)
                }
                // Each tile its own tap target inside the one List row.
                .buttonStyle(.borderless).foregroundStyle(Color.primary)
            }
        }
        .padding(.vertical, 4)
        if page.files.hasMore { showAll(.files, title: "Show all") }
    }

    /// "Show all" / "Show more", a spinner while that page loads.
    private func showAll(_ kind: ProjectFeedKind, title: String) -> some View {
        HStack(spacing: 8) {
            Button(title) { onLoadMore(kind) }
                .disabled(loadingMore.contains(kind))
                .accessibilityIdentifier("projects.page.\(kind.rawValue).more")
            if loadingMore.contains(kind) { ProgressView().controlSize(.small) }
        }
    }

    private func missionChip(_ num: Int) -> some View {
        Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
    }

    /// The box counts on one line when 2+ boxes are named, then a row per
    /// session (tap opens its conversation) — the Mac page's rows without
    /// its box filter.
    @ViewBuilder private var sessionRows: some View {
        let rows = ProjectPageSections.sessionRows(page)
        let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
        if ProjectPageSections.showsBoxFilter(counts) {
            Text(ProjectsFormat.boxCounts(counts)).font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            Button { onOpenSession(row.id) } label: { ProjectSessionRowView(row: row) }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
        }
    }

    /// The missions' open items Needs you does not list, grouped by
    /// mission, folded past `ProjectPageSections.foldedItemLimit`.
    @ViewBuilder private var otherItemRows: some View {
        let list = ProjectPageSections.itemList(page, expanded: showsAllItems)
        ForEach(list.groups) { group in
            Button { onOpenMission(group.missionID) } label: {
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .buttonStyle(.plain)
            ForEach(group.items) { item in
                Button { onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(ItemGlyph.tint(item.kind))
                        Text(item.title).lineLimit(2)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        }
        if list.total > ProjectPageSections.foldedItemLimit {
            Button(showsAllItems ? "Show fewer" : "Show all (\(list.total))") { showsAllItems.toggle() }
        }
    }
}
