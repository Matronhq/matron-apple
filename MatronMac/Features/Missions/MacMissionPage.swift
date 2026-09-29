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
    /// The dashboard model this page's session feeds are attached to — kept
    /// so a later or replaced `missionsViewModel` (it is created in the
    /// shell's `.task` and replaced on a session switch) detaches the old
    /// one and attaches the new one.
    @State private var feedViewModel: MissionsDashboardViewModel?

    /// What the feeds are attached for: which model, which mission.
    private struct FeedKey: Equatable {
        var model: ObjectIdentifier?
        var missionID: String
    }

    var body: some View {
        VStack(spacing: 0) {
            MacMissionPageTopBar(backConvoID: backConvoID, onBack: onBack, onShowDashboard: onShowDashboard)
            Divider()
            if let viewModel = Self.pageViewModel(viewModel, missionID: missionID) {
                MacMissionPageBody(viewModel: viewModel, missionsViewModel: missionsViewModel,
                                   onOpenMilestone: onOpenMilestone, onOpenItem: onOpenItem,
                                   onOpenConversation: onOpenConversation)
                    // A different mission starts fresh: one page of Done
                    // cards, one page of milestones.
                    .id(missionID)
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
        .onChange(of: FeedKey(model: missionsViewModel.map(ObjectIdentifier.init), missionID: missionID),
                  initial: true) {
            feedViewModel = Self.moveSessionFeeds(from: feedViewModel, to: missionsViewModel, missionID: missionID)
        }
        .onDisappear {
            viewModel?.stop()
            feedViewModel?.missionPageDidDisappear()
            feedViewModel = nil
        }
    }

    /// The detail model the page renders: `viewModel` only when it is
    /// `missionID`'s. On a mission switch the session feeds move at once
    /// (`onChange`) but the new detail model lands later (`.task`), so the
    /// old one would otherwise show its mission beside the new mission's
    /// sessions; the page shows the spinner until the new one is in.
    static func pageViewModel(_ viewModel: MissionDetailViewModel?, missionID: String) -> MissionDetailViewModel? {
        viewModel?.missionID == missionID ? viewModel : nil
    }

    /// Detaches the page's session feeds from `old` (when it is a different
    /// model — a session switch) and attaches them to `new` for
    /// `missionID`. Returns the model now attached.
    @discardableResult
    static func moveSessionFeeds(from old: MissionsDashboardViewModel?, to new: MissionsDashboardViewModel?,
                                 missionID: String) -> MissionsDashboardViewModel? {
        if let old, old !== new { old.missionPageDidDisappear() }
        new?.missionPageDidAppear(missionID: missionID)
        return new
    }
}

/// The page below the top bar, mapped from its view models. Every observed
/// read happens here, so only what this page shows re-renders it: the
/// dashboard model's `pageMissionSessions` slice (not every mission's
/// sessions), and none of the close sheet's typing or the minute tick.
struct MacMissionPageBody: View {
    let viewModel: MissionDetailViewModel
    let missionsViewModel: MissionsDashboardViewModel?
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void
    var store: UserDefaults? = nil
    @State private var bodyCache = MacMilestoneBodyCache()

    #if DEBUG
    /// Body evaluations, for the re-render tests.
    nonisolated(unsafe) static var evaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = { Self.evaluations += 1 }()
        #endif
        Group {
            if let mission = viewModel.mission {
                MacMissionPageContentHost(model: model(mission), actions: actions, store: store)
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
        .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private func model(_ mission: Mission) -> MacMissionPageModel {
        MacMissionPageModel(
            mission: mission, latestStep: viewModel.latestMilestone, milestones: viewModel.milestones,
            milestoneBodies: bodyCache.bodies(for: viewModel.milestones),
            showOnlyUserInput: viewModel.showOnlyUserInput, openItems: viewModel.openItems,
            openItemsLoaded: viewModel.hasLoadedOpenItems, closedItems: viewModel.closedItems,
            closedItemsTotal: viewModel.closedItemsTotal,
            sessions: missionsViewModel?.pageMissionSessions ?? [], conversations: viewModel.conversations,
            sessionTags: viewModel.sessionTags, isBusy: viewModel.isBusy)
    }

    private var actions: MacMissionPageActions {
        let viewModel = self.viewModel
        return MacMissionPageActions(
            onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
            onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
            onOpenItem: onOpenItem,
            onOpenConversation: onOpenConversation,
            onClose: { summary in
                viewModel.closeSummaryDraft = summary
                await viewModel.close()
                // Shown in the sheet, which stays open, not in the page's
                // alert behind it.
                guard let failure = viewModel.error else { return nil }
                viewModel.error = nil
                return failure
            },
            onLoadClosedItems: { viewModel.loadClosedItems(atLeast: $0) })
    }
}

/// The content with the remembered Overview | Board choice. Split from the
/// page so the choice is read in one place — the switcher in the top bar
/// and this view share the AppStorage key, and `store` lets tests use a
/// throwaway defaults suite instead of the app's own.
struct MacMissionPageContentHost: View {
    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    @AppStorage(MacMissionPage.modeKey) private var mode: MacMissionPageMode = .overview

    init(model: MacMissionPageModel, actions: MacMissionPageActions, store: UserDefaults? = nil) {
        self.model = model; self.actions = actions
        if let store { _mode = AppStorage(wrappedValue: .overview, MacMissionPage.modeKey, store: store) }
    }

    var body: some View {
        MacMissionPageContent(model: model, mode: mode, actions: actions)
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
