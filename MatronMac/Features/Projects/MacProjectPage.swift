import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

struct MacProjectPageActions {
    var onShowHome: () -> Void = {}
    var onOpenMission: (String) -> Void = { _ in }
    var onOpenItem: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }
    var onOpenMilestone: (Milestone) -> Void = { _ in }
    /// A conversation at one event (a chat file's `seq`).
    var onOpenConversationAt: (String, Int64) -> Void = { _, _ in }
    /// A file of the roll-up: its item, or its conversation at the event.
    /// The page wires it (an item file names only the item's number).
    var onOpenFile: (ProjectFile) -> Void = { _ in }
    /// "Show all" / "Show more" on a roll-up card; the page wires it.
    var onLoadMore: (ProjectFeedKind) -> Void = { _ in }
    var onMoveMission: (String, String) -> Void = { _, _ in }
    var onAddMission: (String) -> Void = { _ in }
    var onMerge: (String) -> Void = { _ in }
}

/// What a project page needs of its view model — `ProjectDetailViewModel`,
/// or a test's fake (`MacProjectPageSlotTests`).
@MainActor protocol MacProjectPageModel: AnyObject {
    var projectID: String { get }
    func start()
    func stop()
}

extension ProjectDetailViewModel: MacProjectPageModel {}

/// The project page's view model, held by the shell rather than the page
/// (PR4 review M1): the page unmounts whenever a mission page replaces it,
/// and a view model rebuilt on Back starts with no detail-pass clock, so
/// `ProjectDetailViewModel`'s 60 s throttle never applied. Kept while it
/// shows the page's project for the same session's dashboard view model
/// (`owner`); any other project or owner builds a fresh one.
@MainActor struct MacProjectPageSlot<Model: MacProjectPageModel> {
    private(set) var model: Model?
    /// The project the page asked for when `model` was built, or when it
    /// last accepted `model` as its own (PR4 review M2). A redirect is the
    /// page's only when this is the page's project — recorded, not inferred
    /// from which ids `onChange` happened to observe.
    private(set) var builtFor: String?
    private(set) var owner: ObjectIdentifier?
    private(set) var isRunning = false

    init() {}

    /// `model` when it is `projectID`'s, for `owner`'s session: Back/Forward
    /// between two project pages changes `projectID` before `.task` swaps
    /// in the new view model, and without this the old project's content
    /// and actions would render — and act — under the new id for a frame.
    func current(projectID: String, owner: ObjectIdentifier) -> Model? {
        guard let model, model.projectID == projectID, self.owner == owner else { return nil }
        return model
    }

    /// The page's `.task(id: projectID)`: reuse the view model showing
    /// `projectID` (a redirected one too), else build one; then start it
    /// unless it is already running — a reused one was stopped when the
    /// page last left the screen.
    mutating func show(projectID: String, owner: ObjectIdentifier, build: () -> Model) {
        let model: Model
        if let reused = current(projectID: projectID, owner: owner) {
            model = reused
        } else {
            self.model?.stop()
            model = build()
            self.model = model
            self.owner = owner
            isRunning = false
        }
        builtFor = projectID
        if !isRunning {
            model.start()
            isRunning = true
        }
    }

    /// The page left the screen. Only `owner`'s page may stop the model: on
    /// an account switch the new session's page can appear before the old
    /// one's `onDisappear` runs.
    mutating func pageDidDisappear(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        model?.stop()
        isRunning = false
    }

    /// The project to redirect the page to when the view model's id moved
    /// to `newID`, or nil: a view model built for another project (stale,
    /// its redirect landing after the user moved on) never moves the page.
    func redirect(to newID: String?, pageProjectID: String) -> String? {
        guard let newID, newID != pageProjectID, builtFor == pageProjectID else { return nil }
        return newID
    }

    /// A new session: the old session's view model must not survive it.
    mutating func reset() {
        model?.stop()
        self = Self()
    }
}

/// One project page in the Mac detail (spec 2026-09-30 §2, mockup 02).
/// Its `ProjectDetailViewModel` lives in the shell's `slot` (review M1); the
/// page builds or reuses it, and reports a merge redirect so the shell's
/// selection (and so its Back/Forward place) follows.
struct MacProjectPage: View {
    let projectID: String
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    @Binding var slot: MacProjectPageSlot<ProjectDetailViewModel>
    let actions: MacProjectPageActions
    let onRedirect: (String) -> Void

    @Environment(\.appDependencies) private var deps
    /// The roll-up's image thumbnails, by blob id: loaded once each through
    /// the session's authenticated media service, as item attachments are.
    @State private var images: [String: Image] = [:]
    /// Host for `matron://item/<n>` links in the status and description:
    /// the item opens where this page's item rows open it.
    @State private var itemLinkRelay = TrackerItemLinkRelay()

    var body: some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: currentViewModel?.page, actions: wiredActions)
            Divider()
            content
        }
        .task(id: projectID) {
            guard let deps else { return }
            slot.show(projectID: projectID, owner: owner) {
                deps.makeProjectDetailViewModel(for: session, projectID: projectID)
            }
        }
        .onChange(of: slot.model?.projectID) { _, id in
            if let target = slot.redirect(to: id, pageProjectID: projectID) { onRedirect(target) }
        }
        .task(id: imageBlobIDs) { await loadImages(imageBlobIDs) }
        .onAppear { missionsViewModel.projectPageDidAppear() }
        .onDisappear {
            slot.pageDidDisappear(owner: owner)
            missionsViewModel.projectPageDidDisappear()
        }
        .alert("Projects", isPresented: errorShown) {
            Button("OK") { currentViewModel?.error = nil }
        } message: {
            Text(currentViewModel?.error ?? "")
        }
        .trackerItemLinks(itemLinkRelay, resolve: { num in
            guard let deps else { return .ignore }
            return await deps.trackerItemLinkOutcome(num: num, session: session)
        }, open: actions.onOpenItem)
    }

    private var owner: ObjectIdentifier { ObjectIdentifier(missionsViewModel) }

    private var currentViewModel: ProjectDetailViewModel? { slot.current(projectID: projectID, owner: owner) }

    /// Which body the page shows (shared-fix-2 order): the page, then not
    /// found, then a failed cold load with a retry, else still loading.
    enum ContentState: Equatable { case page, missing, loadFailed, loading }

    static func contentState(hasPage: Bool, isMissing: Bool, loadFailed: Bool) -> ContentState {
        if hasPage { return .page }
        if isMissing { return .missing }
        if loadFailed { return .loadFailed }
        return .loading
    }

    @ViewBuilder private var content: some View {
        let vm = currentViewModel
        let page = pageModel
        switch Self.contentState(hasPage: page != nil, isMissing: vm?.isMissing == true,
                                 loadFailed: vm?.loadFailed == true) {
        case .page:
            // A new project is a new page: the box filter and the items
            // fold start over rather than carrying across.
            if let page {
                MacProjectPageContent(page: page, actions: wiredActions, loadingMore: vm?.loadingMore ?? [],
                                      images: images)
                    .id(page.project.id)
            }
        case .missing:
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed:
            ContentUnavailableView {
                Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("The journal didn't answer. Check the connection and try again.")
            } actions: {
                Button("Try again") { Task { await vm?.refresh() } }
                    .accessibilityIdentifier("projects.page.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageModel: ProjectPageModel? {
        guard var page = currentViewModel?.page else { return nil }
        page.sessionsByMission = missionsViewModel.sessionsByMission
        page.roomCountsByMission = missionsViewModel.roomCountsByMission
        return page
    }

    /// The page's own writes go to its view model; navigation goes up.
    private var wiredActions: MacProjectPageActions {
        var wired = actions
        let vm = currentViewModel
        wired.onMoveMission = { id, target in Task { await vm?.moveMission(id, to: target) } }
        wired.onAddMission = { id in Task { await vm?.addMission(id) } }
        wired.onMerge = { target in Task { _ = await vm?.merge(into: target) } }
        wired.onLoadMore = { kind in Task { await vm?.loadMore(kind: kind) } }
        wired.onOpenFile = { file in
            switch file.source {
            case .chat(let convoID, let seq): actions.onOpenConversationAt(convoID, seq)
            case .item(let num): Task { await openItem(num: num, vm: vm) }
            }
        }
        return wired
    }

    /// An item file names its item by number: resolve it the way a tapped
    /// `matron://item/<n>` link is (one refresh on a miss), then open it, or
    /// say why not in the page's alert.
    private func openItem(num: Int, vm: ProjectDetailViewModel?) async {
        guard let deps else { return }
        switch await deps.trackerItemLinkOutcome(num: num, session: session) {
        case .open(let itemID): actions.onOpenItem(itemID)
        case .explain(let message): vm?.error = message
        case .ignore: break
        }
    }

    private var imageBlobIDs: [String] {
        currentViewModel?.page?.files.rows.filter(\.isImage).map(\.blobID) ?? []
    }

    private func loadImages(_ blobIDs: [String]) async {
        guard let deps else { return }
        let media = deps.mediaService(for: session)
        // Only the page's current images stay decoded: the page is reused
        // across projects, and a full-size bitmap per visited file adds up.
        let wanted = Set(blobIDs)
        images = images.filter { wanted.contains($0.key) }
        for blobID in blobIDs where images[blobID] == nil {
            let url = session.homeserverURL.appendingPathComponent("media").appendingPathComponent(blobID)
            guard let image = await media.swiftUIImage(for: url) else { continue }
            // A switch to another page restarts this task; a load already in
            // flight must not put the old page's bitmap back.
            guard !Task.isCancelled, imageBlobIDs.contains(blobID) else { return }
            images[blobID] = image
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { currentViewModel?.error != nil }, set: { if !$0 { currentViewModel?.error = nil } })
    }
}

/// "‹ Projects" on the left; "Add a mission" and "…" (Merge into…) on the right.
struct MacProjectPageTopBar: View {
    let page: ProjectPageModel?
    let actions: MacProjectPageActions
    @State private var confirmMerge: Project?

    var body: some View {
        HStack(spacing: 16) {
            Button { actions.onShowHome() } label: { Label("Projects", systemImage: "chevron.backward") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("projects.backToHome")
            Spacer()
            if let page {
                Menu {
                    ForEach(page.unfiledMissions) { mission in
                        Button(mission.label) { actions.onAddMission(mission.id) }
                    }
                } label: { Label("Add a mission", systemImage: "plus") }
                    .fixedSize()
                    .disabled(page.unfiledMissions.isEmpty)
                Menu {
                    Menu("Merge into…") {
                        ForEach(page.mergeTargets) { target in Button(target.title) { confirmMerge = target } }
                    }
                    .disabled(page.mergeTargets.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Project actions")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .confirmationDialog(mergeTitle, isPresented: mergeShown) {
            Button("Merge", role: .destructive) {
                if let target = confirmMerge { actions.onMerge(target.id) }
                confirmMerge = nil
            }
            Button("Cancel", role: .cancel) { confirmMerge = nil }
        } message: {
            Text("Its missions move there and this project closes.")
        }
    }

    private var mergeTitle: String {
        guard let target = confirmMerge, let page else { return "" }
        return "Merge “\(page.project.title)” into “\(target.title)”?"
    }

    private var mergeShown: Binding<Bool> {
        Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })
    }
}

/// The page body: header, status, then two columns — needs you, decisions
/// and milestones | files, missions, sessions and other items — one column
/// below 900 pt. Decisions, files and the day-grouped milestones are the
/// journal's roll-up (Projects view v2); without it (`hasFeed` false) the
/// left column keeps today's "Latest steps" from `recentMilestones`.
struct MacProjectPageContent: View {
    let page: ProjectPageModel
    let actions: MacProjectPageActions
    /// Feed kinds with a "Show all" in flight (`ProjectDetailViewModel.loadingMore`).
    let loadingMore: Set<ProjectFeedKind>
    /// File thumbnails the host has loaded, by blob id.
    let images: [String: Image]
    /// The box the sessions list is filtered to (a click on its count).
    @State private var selectedBox: String?
    /// "Show all" on Other open items.
    @State private var showsAllItems: Bool
    /// The Missions card's Closed fold.
    @State private var showsClosed: Bool

    /// The states are parameters so snapshots can show them.
    init(page: ProjectPageModel, actions: MacProjectPageActions, loadingMore: Set<ProjectFeedKind> = [],
         images: [String: Image] = [:], selectedBox: String? = nil, showsAllItems: Bool = false,
         showsClosed: Bool = false) {
        self.page = page; self.actions = actions; self.loadingMore = loadingMore; self.images = images
        _selectedBox = State(initialValue: selectedBox)
        _showsAllItems = State(initialValue: showsAllItems)
        _showsClosed = State(initialValue: showsClosed)
    }

    /// The heading's count (`ProjectPageSections.otherOpenItemCount`).
    static func otherOpenItems(_ page: ProjectPageModel) -> Int {
        ProjectPageSections.otherOpenItemCount(page)
    }

    var body: some View {
        GeometryReader { geo in
            let width = MacMissionPageLayout.contentWidth(detailWidth: geo.size.width)
            let twoColumns = MacMissionPageLayout.usesTwoColumns(detailWidth: geo.size.width)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusCard
                    columns(width: width, twoColumns: twoColumns)
                }
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(MacMissionPalette.pageBackground)
        // The description and status are plain `Text`s: their `matron://`
        // links open in-app through the hosts' environment actions.
        .inAppLinks()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(page.project.title).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                NeedsYouPill(count: page.needsYouCount)
                Spacer(minLength: 0)
            }
            if !page.project.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(page.project.body))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(3)
            }
            MacMinuteText { ProjectFeedFormat.pageMetaLine(page, now: $0) }
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusCard: some View {
        if let status = page.project.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    MacMissionSectionLabel("Status")
                    Spacer(minLength: 12)
                    MacMinuteText { now in
                        MissionsDashboardFormat.statusByline(updatedAt: page.project.statusUpdatedAt,
                                                             by: page.project.statusBy, now: now) ?? ""
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text(MissionsDashboardFormat.statusText(status)).font(.system(size: 17)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .macMissionCard()
        }
    }

    @ViewBuilder private func columns(width: CGFloat, twoColumns: Bool) -> some View {
        if twoColumns {
            let spacing = MacMissionPageLayout.columnSpacing
            let side = ((width - spacing) * MacMissionPageLayout.sideColumnFraction).rounded()
            HStack(alignment: .top, spacing: spacing) {
                mainColumn.frame(width: width - spacing - side)
                sideColumn.frame(width: side)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) { mainColumn; sideColumn }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !page.needsYou.isEmpty { needsYouCard }
            if !page.decisions.rows.isEmpty { decisionsCard }
            if page.hasFeed {
                if !page.milestonesPage.rows.isEmpty { milestonesCard }
            } else if !page.recentMilestones.isEmpty {
                latestStepsCard
            }
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !page.files.rows.isEmpty { filesCard }
            missionsCard
            sessionsCard
            otherItemsCard
        }
    }

    /// "Show all" / "Show more" for a roll-up card while it has more pages,
    /// a spinner beside it while one loads.
    private func more(_ kind: ProjectFeedKind, hasMore: Bool, title: String = "Show all") -> MacProjectMoreButton? {
        guard hasMore else { return nil }
        return MacProjectMoreButton(title: title, isLoading: loadingMore.contains(kind)) { actions.onLoadMore(kind) }
    }

    // MARK: Left column

    private var needsYouCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacProjectCardHeading("Needs you", detail: "\(page.needsYou.count)", tint: .red)
            ForEach(page.needsYou) { item in
                Button { actions.onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(2)
                        Spacer(minLength: 8)
                        if let num = item.missionNum { MacProjectMissionChip(num: num) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(MacMissionPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .macMissionCard(fill: Color.red.opacity(0.06), border: Color.red.opacity(0.25))
    }

    /// Decisions and answered questions across the missions, newest first.
    private var decisionsCard: some View {
        let rows = page.decisions.rows
        return VStack(alignment: .leading, spacing: 4) {
            MacProjectCardHeading("Decisions", detail: ProjectFeedFormat.feedCount(page.decisions),
                                  more: more(.decisions, hasMore: page.decisions.hasMore))
                .padding(.bottom, 6)
            MacPageClock { now in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, decision in
                        MacProjectDecisionRow(decision: decision, now: now, onOpen: actions.onOpenItem)
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
        }
        .macMissionCard()
    }

    /// Every milestone across the missions, grouped by day.
    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            MacProjectCardHeading("Milestones", detail: ProjectFeedFormat.feedCount(page.milestonesPage),
                                  more: more(.milestones, hasMore: page.milestonesPage.hasMore, title: "Show more"))
            MacPageClock { now in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ProjectFeedFormat.milestoneDays(page.milestonesPage.rows, now: now)) { day in
                        Text(day.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 14).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        Divider()
                        ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                            MacProjectMilestoneRow(milestone: row.milestone, missionNum: row.missionNum,
                                                   time: ProjectFeedFormat.timeOfDay(row.milestone.createdAt),
                                                   onOpen: actions.onOpenMilestone)
                            if index < day.rows.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
        .macMissionCard()
    }

    /// A journal without the roll-up: today's latest steps.
    private var latestStepsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            MacProjectCardHeading("Latest steps", detail: "across missions")
            MacPageClock { now in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(page.recentMilestones) { milestone in
                        MacProjectMilestoneRow(milestone: milestone, missionNum: page.missionNums[milestone.missionID],
                                               time: MissionBoard.ago(milestone.createdAt, now: now),
                                               onOpen: actions.onOpenMilestone)
                    }
                }
            }
        }
        .macMissionCard()
    }

    // MARK: Right column

    /// Item attachments and chat images/files, three to a row.
    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacProjectCardHeading("Files and images", detail: "\(page.files.total)",
                                  more: more(.files, hasMore: page.files.hasMore))
            MacPageClock { now in
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3),
                          alignment: .leading, spacing: 14) {
                    ForEach(page.files.rows) { file in
                        Button { actions.onOpenFile(file) } label: {
                            ProjectFileTile(file: file, image: images[file.blobID], now: now,
                                            nameFont: .system(size: 13), metaFont: .system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(ProjectFeedFormat.fileName(file))
                    }
                }
            }
        }
        .macMissionCard()
    }

    private var missionsCard: some View {
        let closed = max(page.closedMissions.count, page.project.missions.closed)
        return VStack(alignment: .leading, spacing: 0) {
            MacProjectCardHeading("Missions", detail: "\(page.missions.count) open · \(closed) closed")
                .padding(.bottom, 6)
            ForEach(Array(page.missions.enumerated()), id: \.element.id) { index, row in
                Button { actions.onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MacMinuteRow(row: row)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [],
                                        roomCount: page.roomCountsByMission[row.id] ?? 0)
                            .padding(.leading, 21)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID, targets: page.moveTargets) {
                        actions.onMoveMission(row.id, $0)
                    }
                }
                if index < page.missions.count - 1 { Divider() }
            }
            if !page.closedMissions.isEmpty { closedFold }
        }
        .macMissionCard()
    }

    /// "Closed (n)": folded until clicked.
    private var closedFold: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button { showsClosed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showsClosed ? 90 : 0))
                    Text("Closed (\(page.closedMissions.count))").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projects.page.closedToggle")
            if showsClosed {
                ForEach(page.closedMissions) { mission in
                    Button { actions.onOpenMission(mission.id) } label: {
                        MacMinuteRow(row: MissionRowModel(closed: mission)).padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The box counts on one line when 2+ boxes are named (a click filters
    /// the rows to that box; a second click, or All, clears), then one row
    /// per session — shown even when no session names a box at all.
    @ViewBuilder private var sessionsCard: some View {
        let rows = ProjectPageSections.sessionRows(page)
        let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
        if ProjectPageSections.showsSessionsCard(rows: rows, counts: counts) {
            let box = ProjectPageSections.activeBox(selectedBox, in: counts)
            let shown = ProjectPageSections.rows(rows, onBox: box)
            VStack(alignment: .leading, spacing: 10) {
                MacProjectCardHeading("Sessions on it now",
                                      detail: "\(rows.isEmpty ? counts.reduce(0) { $0 + $1.count } : rows.count)")
                if ProjectPageSections.showsBoxFilter(counts) {
                    MacProjectBoxFilter(counts: counts, selected: box, enabled: !rows.isEmpty) { selectedBox = $0 }
                }
                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                            MacProjectSessionRow(row: row, onOpen: actions.onOpenSession)
                            if index < shown.count - 1 { Divider() }
                        }
                    }
                }
            }
            .macMissionCard()
        }
    }

    /// The missions' open items Needs you does not list, grouped by
    /// mission, folded past `ProjectPageSections.foldedItemLimit`.
    @ViewBuilder private var otherItemsCard: some View {
        let other = Self.otherOpenItems(page)
        if other > 0 {
            let list = ProjectPageSections.itemList(page, expanded: showsAllItems)
            VStack(alignment: .leading, spacing: 10) {
                MacProjectCardHeading("Other open items", detail: "\(other) on the missions' boards")
                ForEach(list.groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Button { actions.onOpenMission(group.missionID) } label: {
                            Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        ForEach(group.items) { item in
                            MacProjectItemRow(item: item, onOpen: actions.onOpenItem)
                        }
                    }
                }
                if list.total > ProjectPageSections.foldedItemLimit {
                    Button(showsAllItems ? "Show fewer" : "Show all (\(list.total))") { showsAllItems.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 14))
                        .accessibilityIdentifier("projects.page.otherItems.showAll")
                }
            }
            .macMissionCard()
        }
    }
}

/// A project page card's heading: "Decisions  23 across 4 missions", and
/// "Show all" on the right when the card has more to load.
struct MacProjectCardHeading: View {
    let title: String
    let detail: String?
    var tint: Color = .primary
    var more: MacProjectMoreButton?

    init(_ title: String, detail: String? = nil, tint: Color = .primary, more: MacProjectMoreButton? = nil) {
        self.title = title; self.detail = detail; self.tint = tint; self.more = more
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if let more { more }
        }
    }
}

/// "Show all" / "Show more": the view model's `loadMore(kind:)`, with a
/// small spinner (and no second click) while that page is in flight.
struct MacProjectMoreButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Loading") }
            Button(title, action: action)
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 14))
                .disabled(isLoading)
        }
    }
}

/// "#4907" in the page's blue, monospaced.
struct MacProjectMissionChip: View {
    let num: Int
    var body: some View {
        Text(verbatim: "#\(num)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.blue)
            .accessibilityLabel("Mission \(num)")
    }
}

/// One decision: its mark (a reversed one struck through), the title, a
/// question's answer quoted beneath, then the mission and day. A click
/// opens the item.
struct MacProjectDecisionRow: View {
    let decision: ProjectDecision
    let now: Date
    let onOpen: (String) -> Void

    var body: some View {
        let mark = ProjectDecisionMark(decision)
        Button { onOpen(decision.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: mark.symbol).font(.system(size: 15)).foregroundStyle(mark.tint)
                    .accessibilityLabel(mark.label)
                VStack(alignment: .leading, spacing: 6) {
                    // Both pinned to their full height: beside the answer the
                    // title was otherwise squeezed to one truncated line.
                    Text(decision.title).font(.system(size: 15)).lineLimit(2)
                        .strikethrough(mark.isStruck)
                        .foregroundStyle(mark.isStruck ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let answer = decision.answer, !answer.isEmpty {
                        Text(answer).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                            }
                    }
                }
                Spacer(minLength: 12)
                if let num = decision.missionNum { MacProjectMissionChip(num: num) }
                Text(ProjectFeedFormat.dayLabel(decision.at, now: now))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One milestone: its kind's dot (your input purple), the title, the
/// mission and the time. A click opens the conversation at it.
struct MacProjectMilestoneRow: View {
    let milestone: Milestone
    let missionNum: Int?
    let time: String
    let onOpen: (Milestone) -> Void

    var body: some View {
        Button { onOpen(milestone) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(MacMissionPalette.milestoneTint(milestone.kind)).frame(width: 8, height: 8)
                    .accessibilityLabel(MissionGlyph.label(milestone.kind))
                Text(milestone.title).font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(2)
                Spacer(minLength: 12)
                if let missionNum { MacProjectMissionChip(num: missionNum) }
                Text(time).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A block that reads the clock (day groups, ages): the page's fixed
/// snapshot clock, else one tick a minute scoped to this block.
private struct MacPageClock<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.macMissionPageClock) private var fixedNow

    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else {
            TimelineView(.everyMinute) { context in content(context.date) }
        }
    }
}

/// `MissionRowView` against the page's fixed snapshot clock.
private struct MacMinuteRow: View {
    let row: MissionRowModel
    @Environment(\.macMissionPageClock) private var fixedNow
    var body: some View { MissionRowView(row: row, now: fixedNow) }
}

/// "All · box-a 2 · box-b 1 · box-c 1": the sessions' boxes. A click on a box
/// shows only its sessions; clicking it again, or All, shows them all.
/// Until the sessions themselves have loaded the counts are the journal's
/// and there is nothing to filter, so they are plain text.
struct MacProjectBoxFilter: View {
    let counts: [ProjectBoxCount]
    let selected: String?
    let enabled: Bool
    let onSelect: (String?) -> Void

    var body: some View {
        if enabled {
            PillFlowLayout(spacing: 12) {
                chip("All", isOn: selected == nil) { onSelect(nil) }
                ForEach(counts, id: \.box) { count in
                    chip("\(count.box) \(count.count)", isOn: selected == count.box) {
                        onSelect(ProjectPageSections.toggled(selected, box: count.box))
                    }
                }
            }
        } else {
            Text(ProjectsFormat.boxCounts(counts)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: isOn ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One live session on the project: state dot (stalled red), tag, title,
/// the model and the mission it is on, and its context gauge. A click
/// opens its conversation.
struct MacProjectSessionRow: View {
    let row: ProjectSessionRow
    let onOpen: (String) -> Void

    var body: some View {
        Button { onOpen(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DashboardStateDot(state: row.session.state, isStalled: row.session.isStalled)
                DashboardSessionTag(session: row.session, font: .system(size: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.session.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary).lineLimit(1)
                    if let meta = ProjectSessionRowView.metaLine(row) {
                        Text(meta).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let context = row.session.context {
                    ContextGaugeLabel(context: context, font: .system(size: 13).monospacedDigit())
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One of "Other open items": kind glyph, title, and who it waits on.
struct MacProjectItemRow: View {
    let item: TrackerItem
    let onOpen: (String) -> Void

    var body: some View {
        Button { onOpen(item.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(MacMissionPalette.kindTint(item.kind))
                    .frame(width: 16)
                Text(item.title).font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(2)
                Spacer(minLength: 8)
                if let awaiting = Self.awaitingLabel(item.awaiting) {
                    Text(awaiting).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "you" / "agent", or nil for an item waiting on nobody.
    static func awaitingLabel(_ awaiting: ItemAwaiting?) -> String? {
        switch awaiting {
        case .user: return "you"
        case .agent: return "agent"
        case nil: return nil
        }
    }
}
