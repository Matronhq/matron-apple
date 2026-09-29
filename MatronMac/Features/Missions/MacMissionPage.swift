import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One mission page in the Mac detail column: a top bar ("All missions",
/// the conversation it came from, the Overview | Board switcher), then
/// `MacMissionPageContent`. `backConvoID` is set when the page was reached
/// from a conversation's title, so the reader has a way back to where they
/// were (spec: "the detail column switches to it with a back affordance").
///
/// The iPhone keeps the shared single-column `MissionDetailView`; the Mac
/// page is wide enough for two columns and a board.
struct MacMissionPage: View {
    /// The AppStorage key the Overview | Board choice is remembered under.
    static let modeKey = "missions.page.mode"

    let missionID: String
    let session: UserSession
    let backConvoID: String?
    let onBack: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void
    /// "All missions": back to the dashboard. The Mac sidebar no longer
    /// lists missions, so a page reached from the dashboard needs a visible
    /// way back beside the window's Back (spec 2026-09-28 §3.1).
    var onShowDashboard: (() -> Void)? = nil
    /// The session's dashboard model: its `sessionsByMission` is the
    /// Sessions card (same rows and sub-agent rule as the dashboard card).
    var missionsViewModel: MissionsDashboardViewModel? = nil

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            MacMissionPageTopBar(backConvoID: backConvoID, onBack: onBack, onShowDashboard: onShowDashboard)
            Divider()
            if let viewModel {
                loaded(viewModel)
                    .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                            set: { if !$0 { viewModel.error = nil } })) {
                        Button("OK") { viewModel.error = nil }
                    } message: {
                        Text(viewModel.error ?? "")
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: missionID) {
            guard let deps else { return }
            viewModel?.stop()
            let vm = deps.makeMissionDetailViewModel(for: session, missionID: missionID)
            viewModel = vm
            vm.start()
        }
        .onAppear { missionsViewModel?.missionPageDidAppear() }
        .onDisappear {
            viewModel?.stop()
            missionsViewModel?.missionPageDidDisappear()
        }
    }

    @ViewBuilder
    private func loaded(_ viewModel: MissionDetailViewModel) -> some View {
        if let mission = viewModel.mission {
            // Re-renders each minute so the ages ("14m ago") stay true.
            TimelineView(.everyMinute) { context in
                MacMissionPageContentHost(
                    model: Self.model(mission: mission, viewModel: viewModel,
                                      sessions: missionsViewModel?.sessionsByMission[mission.id] ?? []),
                    now: context.date,
                    actions: actions(viewModel))
            }
        } else {
            ContentUnavailableView {
                Label("Mission not on this device yet", systemImage: "flag.checkered")
            } description: {
                Text("It will appear once this device syncs it.")
            } actions: {
                Button("Try again") { Task { await viewModel.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The ONE mapping from the page's view models into its value model.
    static func model(mission: Mission, viewModel: MissionDetailViewModel,
                      sessions: [DashboardSession]) -> MacMissionPageModel {
        MacMissionPageModel(
            mission: mission, latestStep: viewModel.latestMilestone, milestones: viewModel.milestones,
            showOnlyUserInput: viewModel.showOnlyUserInput, openItems: viewModel.openItems,
            closedItems: viewModel.closedItems, sessions: sessions, conversations: viewModel.conversations,
            sessionTags: viewModel.sessionTags, closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy)
    }

    private func actions(_ viewModel: MissionDetailViewModel) -> MacMissionPageActions {
        MacMissionPageActions(
            onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
            onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
            onOpenItem: onOpenItem,
            onOpenConversation: onOpenConversation,
            onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
            onClose: { Task { await viewModel.close() } })
    }
}

/// The content with the remembered Overview | Board choice. Split from the
/// page so the choice is read in one place — the switcher in the top bar
/// and this view share the AppStorage key, and `store` lets tests use a
/// throwaway defaults suite instead of the app's own.
struct MacMissionPageContentHost: View {
    let model: MacMissionPageModel
    let now: Date
    let actions: MacMissionPageActions
    @AppStorage(MacMissionPage.modeKey) private var mode: MacMissionPageMode = .overview

    init(model: MacMissionPageModel, now: Date, actions: MacMissionPageActions, store: UserDefaults? = nil) {
        self.model = model; self.now = now; self.actions = actions
        if let store { _mode = AppStorage(wrappedValue: .overview, MacMissionPage.modeKey, store: store) }
    }

    var body: some View {
        MacMissionPageContent(model: model, mode: mode, now: now, actions: actions)
    }
}

/// "All missions" and "Back to the conversation" on the left, the Overview
/// | Board switcher on the right. Never `.toolbar` items: the Mac header is
/// a titlebar accessory and anything under it adding toolbar items clips.
struct MacMissionPageTopBar: View {
    let backConvoID: String?
    let onBack: (String) -> Void
    let onShowDashboard: (() -> Void)?
    @AppStorage(MacMissionPage.modeKey) private var mode: MacMissionPageMode = .overview

    init(backConvoID: String?, onBack: @escaping (String) -> Void, onShowDashboard: (() -> Void)?,
         store: UserDefaults? = nil) {
        self.backConvoID = backConvoID; self.onBack = onBack; self.onShowDashboard = onShowDashboard
        if let store { _mode = AppStorage(wrappedValue: .overview, MacMissionPage.modeKey, store: store) }
    }

    var body: some View {
        HStack(spacing: 16) {
            if let onShowDashboard {
                Button { onShowDashboard() } label: { Label("All missions", systemImage: "chevron.backward") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("missions.allMissions")
            }
            if let backConvoID {
                Button { onBack(backConvoID) } label: { Label("Back to the conversation", systemImage: "chevron.backward") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("missions.backToConversation")
            }
            Spacer()
            Picker("View", selection: $mode) {
                ForEach(MacMissionPageMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("missionPage.mode")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
