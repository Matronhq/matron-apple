import SwiftUI
import MatronModels

/// The Projects home (spec 2026-09-30 §2): project cards, then missions not
/// in a project as slim rows, then the Quiet and Closed folds. Every mission
/// has a project on a current journal (it files any mission started
/// without one), so the slim-row sections only show for an older journal,
/// and only when they have rows. A pure leaf: hosts map
/// `MissionsDashboardViewModel` into `Model`.
public struct ProjectsHomeView: View {
    public struct Model: Equatable {
        public var home: ProjectsHomeSnapshot
        public var isRefreshing: Bool
        public var askedAt: Date?
        public var isAskEnabled: Bool
        public var canCreateProject: Bool
        /// The "Latest briefing" card at the top; `nil` hides it (an older
        /// journal, no Coordinator, nothing read yet).
        public var briefing: BriefingCardModel?
        public init(home: ProjectsHomeSnapshot, isRefreshing: Bool, askedAt: Date? = nil, isAskEnabled: Bool = true,
                    canCreateProject: Bool = true, briefing: BriefingCardModel? = nil) {
            self.home = home; self.isRefreshing = isRefreshing; self.askedAt = askedAt
            self.isAskEnabled = isAskEnabled; self.canCreateProject = canCreateProject
            self.briefing = briefing
        }
    }

    /// Rows shown before "+ n more".
    public static let unfiledPreview = 6

    /// A card's narrowest width beside another.
    static let minCardWidth: CGFloat = 300
    static let cardSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 16

    /// As many cards side by side as the Mac page fits at `minCardWidth`:
    /// three at the default window, four on a wide one, and the cards
    /// share whatever width is left over. One column on iOS, where even an
    /// iPad's cards read better full width.
    static func cardColumnCount(pageWidth: CGFloat) -> Int {
        #if os(macOS)
        let room = pageWidth - 2 * pagePadding + cardSpacing
        return max(1, Int(room / (minCardWidth + cardSpacing)))
        #else
        return 1
        #endif
    }

    let model: Model
    let now: Date?
    let onAction: (ProjectsHomeAction) -> Void
    let onRefresh: () async -> Void
    let onAsk: (() -> Void)?
    let onOpenBriefing: (() -> Void)?
    let onRefreshBriefing: (() -> Void)?
    @State private var showAllUnfiled = false
    @State private var showQuiet = false
    @State private var showClosed = false
    @State private var query: String
    @FocusState private var filterFocused: Bool

    /// `query` is the filter field's opening text (previews and tests).
    public init(model: Model, now: Date? = nil, query: String = "", onAction: @escaping (ProjectsHomeAction) -> Void,
                onRefresh: @escaping () async -> Void, onAsk: (() -> Void)? = nil,
                onOpenBriefing: (() -> Void)? = nil, onRefreshBriefing: (() -> Void)? = nil) {
        self.model = model; self.now = now; self.onRefresh = onRefresh; self.onAsk = onAsk
        // Leaving the page gives the keyboard up first: a page or sheet
        // opened while the field holds it hands it back on the way back.
        self.onAction = { KeyboardDismiss.resign(); onAction($0) }
        self.onOpenBriefing = onOpenBriefing.map { open in { KeyboardDismiss.resign(); open() } }
        self.onRefreshBriefing = onRefreshBriefing
        _query = State(initialValue: query)
    }

    private var filter: ProjectsHomeFilter { ProjectsHomeFilter(query) }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader
            Divider()
            #endif
            if !model.home.isEmpty { filterField }
            content
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text("Projects").font(.headline)
            Spacer()
            if let at = model.home.statusRefreshedAt {
                ticking { now in
                    Text("Status refreshed \(MissionsDashboardFormat.relative(at, now: now))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
            if let onAsk { MissionsDashboardAskButton(isEnabled: model.isAskEnabled, action: onAsk).labelStyle(.titleAndIcon) }
            if model.canCreateProject { newProjectButton.labelStyle(.titleAndIcon) }
            Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
    #endif

    /// Also placed in the iOS toolbar by the host.
    public var newProjectButton: some View {
        Button { onAction(.newProject) } label: { Label("New project", systemImage: "plus") }
            .accessibilityIdentifier("projects.new")
    }

    /// Above the scrolling page, so it stays put while the results move.
    /// On iOS the keyboard always has a way out: Done beside the field, the
    /// Search key, a tap or a scroll on the page, and opening anything.
    private var filterField: some View {
        HStack(spacing: 12) {
            filterBox
            #if os(iOS)
            if filterFocused {
                Button("Done") { filterFocused = false }
                    .accessibilityIdentifier("projects.filter.done")
            }
            #endif
        }
        #if os(macOS)
        .frame(maxWidth: 360)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.pagePadding).padding(.top, 10).padding(.bottom, 2)
        .onDisappear { filterFocused = false }
    }

    private var filterBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter projects", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($filterFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { filterFocused = false }
                #else
                .onExitCommand { query = "" }
                #endif
                .accessibilityIdentifier("projects.filter")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear filter")
                    .accessibilityIdentifier("projects.filter.clear")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        // With a briefing card the page draws (the card, then the empty
        // note); without one the placeholder fills the space as before.
        if model.home.isEmpty && model.briefing == nil {
            placeholder
        } else {
            // GeometryReader, not onGeometryChange: the width is there on the
            // first layout, so a wide window never draws one column first.
            GeometryReader { geo in
                ScrollView { ticking { now in page(now: now, width: geo.size.width) } }
            }
            #if os(iOS)
                .refreshable { await onRefresh() }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(TapGesture().onEnded { filterFocused = false })
            #endif
        }
    }

    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now { content(now) } else { TimelineView(.periodic(from: .now, by: 60)) { content($0.date) } }
    }

    private func page(now: Date, width: CGFloat) -> some View {
        let filter = filter
        let home = filter.apply(to: model.home)
        return VStack(alignment: .leading, spacing: 24) {
            // The briefing and the asked note are not results.
            if !filter.isActive {
                if let briefing = model.briefing {
                    LatestBriefingCard(model: briefing, now: now,
                                       onOpen: { onOpenBriefing?() }, onRefresh: { onRefreshBriefing?() })
                }
                if let askedAt = model.askedAt {
                    Label(MissionsDashboardFormat.askedLabel(askedAt: askedAt, now: now), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !home.cards.isEmpty { projectsSection(home.cards, filter: filter, now: now, width: width) }
            if !home.unfiled.isEmpty { unfiledSection(home.unfiled, showAll: filter.isActive, now: now) }
            if !home.quiet.isEmpty { quietFold(home.quiet, open: filter.isActive, now: now) }
            if !home.closed.isEmpty { closedFold(home.closed, open: filter.isActive, now: now) }
            if home.isEmpty {
                if filter.isActive {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    emptyNote.frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
        }
        .padding(Self.pagePadding)
    }

    private func sectionHeader(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(detail.uppercased()).font(.caption).tracking(0.6).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func projectsSection(_ cards: [ProjectCard], filter: ProjectsHomeFilter, now: Date, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Projects", filter.isActive ? "\(cards.count) of \(model.home.cards.count)" : "\(cards.count) open")
            let columns = Array(repeating: GridItem(.flexible(), spacing: Self.cardSpacing, alignment: .top),
                                count: Self.cardColumnCount(pageWidth: width))
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        ProjectCardView(card: card, now: now) { onAction(.openProject(card.id)) }
                        // A project found through a mission says which one.
                        if let mission = filter.matchedMission(in: card) {
                            Text("Mission: \(mission)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
    }

    private func unfiledSection(_ rows: [MissionRowModel], showAll: Bool, now: Date) -> some View {
        let shown = showAll || showAllUnfiled ? rows : Array(rows.prefix(Self.unfiledPreview))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Missions not in a project", "\(rows.count) active")
            rowsCard(shown, now: now, more: rows.count - shown.count)
        }
    }

    private func rowsCard(_ rows: [MissionRowModel], now: Date, more: Int = 0) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                missionButton(row, now: now)
                if index < rows.count - 1 || more > 0 { Divider().padding(.leading, 12) }
            }
            if more > 0 {
                Button("+ \(more) more") { showAllUnfiled = true }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .accessibilityIdentifier("projects.unfiled.more")
            }
        }
        .modifier(DashboardCardChrome())
    }

    private func missionButton(_ row: MissionRowModel, now: Date) -> some View {
        Button { onAction(.openMission(row.id)) } label: {
            MissionRowView(row: row, now: now).padding(.horizontal, 12).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .contextMenu {
            MoveToProjectMenu(currentProjectID: row.mission.projectID, targets: model.home.openProjects) {
                onAction(.moveMission(missionID: row.id, projectID: $0))
            }
        }
    }

    /// A fold stays open while the filter is on: its rows are the results.
    /// A tap then changes nothing, so the fold is as the user left it once
    /// the field is cleared.
    private func fold(_ shown: Binding<Bool>, open: Bool) -> Binding<Bool> {
        Binding(get: { open || shown.wrappedValue }, set: { if !open { shown.wrappedValue = $0 } })
    }

    private func quietFold(_ rows: [MissionRowModel], open: Bool, now: Date) -> some View {
        DisclosureGroup(isExpanded: fold($showQuiet, open: open)) {
            rowsCard(rows, now: now).padding(.top, 8)
        } label: {
            Text("Quiet for over a week (\(rows.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.quietToggle")
    }

    private func closedFold(_ missions: [Mission], open: Bool, now: Date) -> some View {
        DisclosureGroup(isExpanded: fold($showClosed, open: open)) {
            rowsCard(missions.map(MissionRowModel.init(closed:)), now: now).padding(.top, 8)
        } label: {
            Text("Closed (\(missions.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.closedToggle")
    }

    private var emptyNote: some View {
        ContentUnavailableView("No projects or missions yet", systemImage: ProjectGlyph.symbol,
                               description: Text("An agent files each mission into a project as it starts one."))
    }

    @ViewBuilder private var placeholder: some View {
        let content = emptyNote
        #if os(iOS)
        GeometryReader { geo in
            ScrollView { content.frame(width: geo.size.width, height: geo.size.height) }
                .refreshable { await onRefresh() }
        }
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
