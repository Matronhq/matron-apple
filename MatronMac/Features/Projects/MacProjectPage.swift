import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

struct MacProjectPageActions {
    var onShowHome: () -> Void = {}
    var onOpenMission: (String) -> Void = { _ in }
    var onOpenItem: (String) -> Void = { _ in }
    var onOpenMilestone: (Milestone) -> Void = { _ in }
    var onMoveMission: (String, String?) -> Void = { _, _ in }
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
            if let page { MacProjectPageContent(page: page, actions: wiredActions) }
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
        return page
    }

    /// The page's own writes go to its view model; navigation goes up.
    private var wiredActions: MacProjectPageActions {
        var wired = actions
        let vm = currentViewModel
        wired.onMoveMission = { id, target in Task { await vm?.moveMission(id, to: target) } }
        wired.onAddMission = { id in Task { await vm?.addMission(id) } }
        wired.onMerge = { target in Task { _ = await vm?.merge(into: target) } }
        return wired
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

/// The page body: header, status, then two columns (missions and latest
/// steps | needs you, sessions, other items), one column below 900 pt.
struct MacProjectPageContent: View {
    let page: ProjectPageModel
    let actions: MacProjectPageActions

    static func otherOpenItems(_ page: ProjectPageModel) -> Int {
        max(0, page.project.openItems - page.needsYou.count)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.project.title).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                Spacer(minLength: 12)
                NeedsYouPill(count: page.needsYouCount)
            }
            if !page.project.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(page.project.body))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(3)
            }
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
            missionsCard
            if !page.recentMilestones.isEmpty { milestonesCard }
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !page.needsYou.isEmpty { needsYouCard }
            if !page.sessionsByBox.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MacMissionSectionLabel("Sessions on it now")
                    Text(ProjectsFormat.sessionsByBox(page.sessionsByBox)).font(.system(size: 15))
                }
            }
            let other = Self.otherOpenItems(page)
            if other > 0 {
                MacMissionSectionLabel("Other open items · \(other) on the missions' boards")
            }
        }
    }

    private var missionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacMissionSectionLabel("Missions · \(page.missions.count) · sorted by needs-you, then activity")
                .padding(.bottom, 12)
            ForEach(Array(page.missions.enumerated()), id: \.element.id) { index, row in
                Button { actions.onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MacMinuteRow(row: row)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [])
                            .padding(.leading, 21)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID, targets: page.moveTargets) {
                        actions.onMoveMission(row.id, $0)
                    }
                }
                if index < page.missions.count - 1 { Divider() }
            }
        }
        .macMissionCard()
    }

    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacMissionSectionLabel("Latest steps across missions")
            ForEach(page.recentMilestones) { milestone in
                Button { actions.onOpenMilestone(milestone) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(MacMissionPalette.milestoneTint(milestone.kind)).frame(width: 9, height: 9)
                        Text(milestone.title).font(.system(size: 16)).foregroundStyle(Color.primary).lineLimit(1)
                        if let num = page.missionNums[milestone.missionID] {
                            Text(verbatim: "#\(num)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 8)
                        MacMinuteText { MissionBoard.ago(milestone.createdAt, now: $0) }
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .macMissionCard()
    }

    private var needsYouCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacMissionSectionLabel("Needs you · \(page.needsYou.count) · across all missions", tint: .red)
            ForEach(page.needsYou) { item in
                Button { actions.onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(2)
                        if let num = item.missionNum {
                            Text(verbatim: "#\(num)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 0)
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
}

/// `MissionRowView` against the page's fixed snapshot clock.
private struct MacMinuteRow: View {
    let row: MissionRowModel
    @Environment(\.macMissionPageClock) private var fixedNow
    var body: some View { MissionRowView(row: row, now: fixedNow) }
}
