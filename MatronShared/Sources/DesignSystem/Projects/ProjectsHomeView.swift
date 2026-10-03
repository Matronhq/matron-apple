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
        public init(home: ProjectsHomeSnapshot, isRefreshing: Bool, askedAt: Date? = nil, isAskEnabled: Bool = true,
                    canCreateProject: Bool = true) {
            self.home = home; self.isRefreshing = isRefreshing; self.askedAt = askedAt
            self.isAskEnabled = isAskEnabled; self.canCreateProject = canCreateProject
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
    @State private var showAllUnfiled = false
    @State private var showQuiet = false
    @State private var showClosed = false

    public init(model: Model, now: Date? = nil, onAction: @escaping (ProjectsHomeAction) -> Void,
                onRefresh: @escaping () async -> Void, onAsk: (() -> Void)? = nil) {
        self.model = model; self.now = now; self.onAction = onAction; self.onRefresh = onRefresh; self.onAsk = onAsk
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader
            Divider()
            #endif
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

    @ViewBuilder private var content: some View {
        if model.home.isEmpty {
            placeholder
        } else {
            // GeometryReader, not onGeometryChange: the width is there on the
            // first layout, so a wide window never draws one column first.
            GeometryReader { geo in
                ScrollView { ticking { now in page(now: now, width: geo.size.width) } }
            }
            #if os(iOS)
                .refreshable { await onRefresh() }
            #endif
        }
    }

    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now { content(now) } else { TimelineView(.periodic(from: .now, by: 60)) { content($0.date) } }
    }

    private func page(now: Date, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let askedAt = model.askedAt {
                Label(MissionsDashboardFormat.askedLabel(askedAt: askedAt, now: now), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.home.cards.isEmpty { projectsSection(now: now, width: width) }
            if !model.home.unfiled.isEmpty { unfiledSection(now: now) }
            if !model.home.quiet.isEmpty { quietFold(now: now) }
            if !model.home.closed.isEmpty { closedFold(now: now) }
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

    private func projectsSection(now: Date, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Projects", "\(model.home.cards.count) open")
            let columns = Array(repeating: GridItem(.flexible(), spacing: Self.cardSpacing, alignment: .top),
                                count: Self.cardColumnCount(pageWidth: width))
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(model.home.cards) { card in
                    ProjectCardView(card: card, now: now) { onAction(.openProject(card.id)) }
                }
            }
        }
    }

    private func unfiledSection(now: Date) -> some View {
        let rows = model.home.unfiled
        let shown = showAllUnfiled ? rows : Array(rows.prefix(Self.unfiledPreview))
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

    private func quietFold(now: Date) -> some View {
        DisclosureGroup(isExpanded: $showQuiet) {
            rowsCard(model.home.quiet, now: now).padding(.top, 8)
        } label: {
            Text("Quiet for over a week (\(model.home.quiet.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.quietToggle")
    }

    private func closedFold(now: Date) -> some View {
        DisclosureGroup(isExpanded: $showClosed) {
            rowsCard(model.home.closed.map(MissionRowModel.init(closed:)), now: now).padding(.top, 8)
        } label: {
            Text("Closed (\(model.home.closed.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.closedToggle")
    }

    @ViewBuilder private var placeholder: some View {
        let content = ContentUnavailableView("No projects or missions yet", systemImage: ProjectGlyph.symbol,
                                             description: Text("An agent files each mission into a project as it starts one."))
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
