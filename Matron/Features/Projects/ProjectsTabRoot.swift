import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects tab's root: the timeline's week page. The view model is the
/// shell's session-long `MissionsDashboardViewModel` (its badge shows while
/// another tab does). A journal too old for the timeline (no `/projects`,
/// or a 404 on the timeline's weeks) keeps the missions dashboard here.
struct ProjectsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onLegacyAction: (MissionsDashboardAction) -> Void
    var onOpenMemories: (() -> Void)? = nil
    var timeline: TimelineHostState? = nil
    var timelineActions: TimelineActions? = nil
    @Environment(\.currentSession) private var session

    /// What a timeline page opens, on the Projects stack.
    struct TimelineActions {
        let onOpenStory: (String) -> Void
        let onOpenList: (TimelinePlace) -> Void
    }

    /// Which page the root draws.
    enum Content: Equatable {
        /// The missions dashboard, on a journal too old for the timeline.
        case legacy
        /// The timeline's week page.
        case timeline
        /// The timeline's view model is not built yet.
        case loading
    }

    static func content(projectsSupported: Bool?, timelineSupported: Bool?, timelineBuilt: Bool) -> Content {
        if projectsSupported == false || timelineSupported == false { return .legacy }
        return timelineBuilt ? .timeline : .loading
    }

    /// A toolbar button of the root.
    enum ToolbarButton: Equatable {
        case ask, memories
    }

    /// The root's toolbar: the dashboard keeps its Ask; every page has
    /// Memories (the week page's week picker is the title's menu).
    static func toolbarButtons(content: Content, canAskCoordinator: Bool, hasMemories: Bool) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []
        if content == .legacy, canAskCoordinator { buttons.append(.ask) }
        if hasMemories { buttons.append(.memories) }
        return buttons
    }

    var body: some View {
        page
            .toolbar { toolbarContent }
            // The one alert: the dashboard's, else the timeline's week page's.
            .alert("Projects", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
    }

    private var content: Content {
        Self.content(projectsSupported: viewModel.projectsSupported,
                     timelineSupported: timeline?.viewModel?.isSupported,
                     timelineBuilt: phoneTimeline != nil)
    }

    @ViewBuilder private var page: some View {
        switch content {
        case .timeline:
            if let timeline, let timelineViewModel = phoneTimeline, let timelineActions, let session {
                TimelinePhoneRoot(state: timeline, viewModel: timelineViewModel, session: session,
                                  onOpenStory: timelineActions.onOpenStory, onOpenList: timelineActions.onOpenList)
            }
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Projects")
        case .legacy:
            dashboard
        }
    }

    /// The missions dashboard, on a journal too old for the timeline. Its
    /// cards and their feeds run only while it shows.
    private var dashboard: some View {
        MissionsDashboardView(model: legacyModel, onAction: onLegacyAction,
                              onRefresh: { await viewModel.refresh() })
            .navigationTitle("Projects")
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
    }

    /// The timeline's view model, when it is built and the root can draw
    /// its week page.
    private var phoneTimeline: TimelineViewModel? {
        guard timelineActions != nil, session != nil else { return nil }
        return timeline?.viewModel
    }

    private var legacyModel: MissionsDashboardView.Model {
        MissionsDashboardView.Model(cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
                                    isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
                                    askedAt: viewModel.askedAt, isAskEnabled: viewModel.canSendAsk)
    }

    /// The dashboard's error, while it shows.
    private var dashboardError: String? { content == .legacy ? viewModel.error : nil }

    /// The week page's error, when it says one (`TimelineViewModel.showsError`).
    private var timelineError: String? {
        guard content == .timeline, let timeline, let timelineViewModel = phoneTimeline,
              timelineViewModel.showsError(on: TimelinePhoneRoot.place(timeline)) else { return nil }
        return timelineViewModel.error
    }

    private var alertMessage: String? { dashboardError ?? timelineError }

    private var errorShown: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { shown in
            guard !shown else { return }
            if dashboardError != nil { viewModel.error = nil } else { timeline?.viewModel?.error = nil }
        })
    }

    private var toolbarButtons: [ToolbarButton] {
        Self.toolbarButtons(content: content, canAskCoordinator: viewModel.canAskCoordinator,
                            hasMemories: onOpenMemories != nil)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if toolbarButtons.contains(.ask) {
            ToolbarItem(placement: .primaryAction) {
                MissionsDashboardAskButton(isEnabled: viewModel.canSendAsk) { Task { await viewModel.askCoordinator() } }
            }
        }
        if let onOpenMemories {
            ToolbarItem(placement: .primaryAction) {
                Button { KeyboardDismiss.resign(); onOpenMemories() } label: { Label("Memories", systemImage: "brain") }
                    .accessibilityIdentifier("missions.memories")
            }
        }
    }
}
