import Foundation
import Observation
import MatronModels
import MatronViewModels

/// The bottom tabs (app shell, spec §3), left to right in the bar — and
/// `allCases` order is the swipe order too. The Coordinator is the first
/// tab (decision #2913: a swipe or two away, never a sheet over the top).
/// The app opens on Conversations.
enum AppTab: Hashable, CaseIterable {
    case coordinator
    case missions
    case decisions
    case conversations
}

/// Navigation state of the signed-in shell: the selected tab and each
/// tab's stack path. An observable object rather than `@State` on the view
/// so the cross-tab rules (deep links land in Conversations; Decisions
/// hands off to Conversations) are plain, testable functions and so
/// tests can inject a pre-set state into `AppShellView`.
@MainActor @Observable
final class AppShellNavigation {
    var tab: AppTab = .conversations
    /// `false` once `GET /missions` 404s (set by `AppShellView` from
    /// `MissionsDashboardViewModel.isSupported`) — the Missions tab is then
    /// absent from the `TabView`, so nothing may select its tag: the root
    /// swipe consults this (`swipeRoot` walks `Self.tabs(missionsSupported:)`,
    /// not the unconditional `AppTab.allCases`) and `openMission` no-ops.
    /// The clamp lives here, in the setter, rather than in a view
    /// `onChange`, so it is testable without one: a swipe that already
    /// landed on `.missions` in the window before a 404 answers is walked
    /// back to Conversations the instant the flag flips false.
    var missionsSupported = true {
        didSet {
            guard missionsSupported != oldValue, !missionsSupported, tab == .missions else { return }
            tab = .conversations
        }
    }

    /// The tabs actually in the bar for a given support state — the same
    /// set `AppShellView`'s `TabView` renders. `swipeRoot` walks this
    /// instead of the unconditional `AppTab.allCases`, so it can never
    /// select a tag with no matching tab.
    static func tabs(missionsSupported: Bool) -> [AppTab] {
        missionsSupported ? AppTab.allCases : AppTab.allCases.filter { $0 != .missions }
    }
    /// Conversations tab stack. `[String]` because `ChatSummary.ID == String`
    /// and the sub-chat switcher replaces entries in place.
    var chatPath: [String] = []
    /// Decisions tab stack: `ItemRoute.pathValue` entries, plus whatever a
    /// conversation opened from an item pushes on top (the conversation
    /// itself, its sub-chats, a mission page). `[String]` like every other
    /// stack so a chat can ride it.
    var decisionsPath: [String] = []
    /// The Coordinator tab's stack: sub-chats, items and missions opened
    /// from the Coordinator push here, so back returns to it.
    var coordinatorPath: [String] = []
    /// Missions tab stack: `MissionRoute.pathValue` entries, plus
    /// `ItemRoute.pathValue` for an item opened from a mission page, plus
    /// a conversation opened from one of those pages.
    var missionsPath: [String] = []
    /// Voice mode, when it is on: a full-screen cover over the whole shell
    /// (spec 2026-10-03 §6). `nil` when it is off.
    var voiceMode: VoiceModeEntry?

    init() {}

    /// Opens voice mode. Ignored while it is already on: one sitting at a
    /// time, and a second entry point must not restart it.
    func openVoiceMode(_ entry: VoiceModeEntry) {
        guard voiceMode == nil else { return }
        voiceMode = entry
    }

    func closeVoiceMode() {
        voiceMode = nil
    }

    /// Open a top-level conversation by REPLACING the Conversations path
    /// (Dan, 2026-08-06): notification taps, search results and new chats
    /// never stack chat-on-chat. The Coordinator's conversation selects its
    /// own tab instead. A copy of the chat on the Coordinator tab's stack is
    /// cut (see `cut(_:sharingChatsWith:)`).
    func openChat(_ roomID: String) {
        if roomID == coordinatorConvoID {
            selectCoordinator()
            return
        }
        show(inConversations: [roomID])
    }

    /// A tapped conversation link or pill in a message (decision #2954):
    /// pushes the conversation onto the stack of the tab it was tapped in,
    /// so Back returns to the chat or item the link sat in — as on the
    /// Mac. The Coordinator's own conversation selects its tab's root.
    /// Pushing through `setPath` keeps the no-dual-mount rule: the same
    /// conversation open on another tab is cut from there. The shell calls
    /// this only for a conversation the local store knows
    /// (`ConversationLinkHost.resolve`); notification taps and search keep
    /// `openChat`.
    func openConversationLink(_ convoID: String) {
        pushConversation(convoID, on: tab)
    }

    /// A tapped `matron://mission/<n>` or `matron://project/<n>` link,
    /// resolved to its page. A mission pushes onto the stack of the tab the
    /// link was tapped in — every stack carries mission pages — so Back
    /// returns to where the link sat; a double tap never stacks two. A
    /// project page lives on the Projects stack only: there it pushes,
    /// from any other tab the Projects tab comes forward on it.
    func openPageLink(_ target: MatronPageTarget) {
        guard missionsSupported else { return }
        switch target {
        case .mission(let id):
            let route = MissionRoute(id: id).pathValue
            guard path(of: tab).last != route else { return }
            push(route, on: tab)
        case .project(let id):
            if tab == .missions { pushProject(id) } else { openProject(id) }
        }
    }

    /// A conversation the user chose to open from where they are (a link,
    /// a mission or project page, an item's "Open conversation"): pushed
    /// onto `target`'s stack, so Back returns to the page it was opened
    /// from (mission 7047). Dan's 2026-08-06 rule — Back from a
    /// conversation goes to the list — was made against chats stacking
    /// that the user never chose to walk through (notification taps,
    /// search results, auto-opened sessions); those still replace the
    /// Conversations stack (`openChat`). The Coordinator's conversation
    /// selects its own tab.
    private func pushConversation(_ convoID: String, on target: AppTab) {
        if convoID == coordinatorConvoID {
            selectCoordinator()
            return
        }
        setPath(Self.pushing(convoID, onto: path(of: target)), on: target)
    }

    /// The stack of `tab`.
    func path(of tab: AppTab) -> [String] {
        switch tab {
        case .coordinator: return coordinatorPath
        case .conversations: return chatPath
        case .decisions: return decisionsPath
        case .missions: return missionsPath
        }
    }

    /// Only writes a changed stack: `@Observable` notifies on every write.
    private func write(_ path: [String], to tab: AppTab) {
        guard path != self.path(of: tab) else { return }
        switch tab {
        case .coordinator: coordinatorPath = path
        case .conversations: chatPath = path
        case .decisions: decisionsPath = path
        case .missions: missionsPath = path
        }
    }

    /// Whether `convoID` is on any tab's stack.
    func isOpen(_ convoID: String) -> Bool {
        AppTab.allCases.contains { path(of: $0).contains(convoID) }
    }

    /// The one writer of every stack — each stack binding's setter and
    /// every push go through it, so two rules hold wherever a chat is
    /// opened from:
    /// - the Coordinator's conversation never mounts on a stack as a
    ///   pushed chat. Pushed onto its own tab it pops that stack to the
    ///   root; pushed anywhere else (origin link, spawned-room Open) the
    ///   stack keeps only what is beneath it and the Coordinator tab is
    ///   selected, so it never mounts there for a frame (Bugbot, PR #197).
    /// - a chat is mounted on one stack at a time. The `TabView` keeps
    ///   every stack mounted, two ChatViews would share one cached
    ///   ChatViewModel, and the copy that disappears on a tab switch
    ///   stops the stream the other one shows. A chat in `new` is cut,
    ///   with everything above it, from every other stack.
    func setPath(_ new: [String], on target: AppTab) {
        if let coordinator = coordinatorConvoID, let index = new.firstIndex(of: coordinator) {
            if target == .coordinator {
                write([], to: .coordinator)
            } else {
                write(Array(new[..<index]), to: target)
                selectCoordinator()
            }
            return
        }
        write(new, to: target)
        for other in AppTab.allCases where other != target {
            write(Self.cut(path(of: other), sharingChatsWith: new), to: other)
        }
    }

    /// `stack` with `convoID` on top. Already on it: popped back to that
    /// copy rather than stacked twice — two `ChatView`s on one stack would
    /// share one cached `ChatViewModel`.
    private static func pushing(_ convoID: String, onto stack: [String]) -> [String] {
        if let index = stack.firstIndex(of: convoID) { return Array(stack[...index]) }
        return stack + [convoID]
    }

    /// A conversation born while the app is live
    /// (`SyncService.newConversations()`). One this device asked for opens
    /// (`autoOpenChat`). Any other — a session an agent, the Coordinator or
    /// a routine started, or the user started on another device — changes
    /// nothing here: no tab switch, no push. Returns whether the list
    /// should mark it new, which is every quiet arrival not already on
    /// screen.
    func conversationBorn(_ born: NewConversation) -> Bool {
        guard !born.startedHere else {
            autoOpenChat(born.id)
            return false
        }
        return !isOpen(born.id)
    }

    /// The auto-open of a session the user just started from this device
    /// (a `/start` sent in a chat; New Chat navigates on its own answer and
    /// lands here with the same id). On the Coordinator tab it lands in
    /// Conversations without pulling the user off the Coordinator — and is
    /// left alone when it is already open on the Coordinator's stack, where
    /// the user is looking at it. Anywhere else it opens like any deep link.
    func autoOpenChat(_ roomID: String) {
        guard tab == .coordinator, roomID != coordinatorConvoID else {
            openChat(roomID)
            return
        }
        guard !coordinatorPath.contains(roomID) else { return }
        setPath([roomID], on: .conversations)
    }

    /// Selects Conversations showing `newPath`, cutting any chat it holds
    /// from every other tab's stack in the same write.
    private func show(inConversations newPath: [String]) {
        tab = .conversations
        setPath(newPath, on: .conversations)
    }

    /// The designated Coordinator conversation, mirrored from the cached
    /// setting by the shell. A new one starts the Coordinator tab at its
    /// root, and is cut (with everything above it) from every other stack:
    /// "New coordinator chat…" auto-opens it in Conversations before the
    /// PUT assigns it, and Choose can pick a chat open on any tab — two
    /// ChatViews would share one cached ChatViewModel (final review C2).
    /// The cut always happens — the `TabView` keeps every stack mounted
    /// behind the others — but the tab only switches when the chat was on
    /// the stack on screen (CodeRabbit): a remote assignment must not yank
    /// the user off an unrelated tab.
    var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            coordinatorPath = []
            guard let id = coordinatorConvoID else { return }
            let wasOnScreen = tab != .coordinator && path(of: tab).contains(id)
            cutFromPagedStacks(id)
            if wasOnScreen { tab = .coordinator }
        }
    }

    /// Selects the Coordinator tab at its root. The same conversation open
    /// on another stack (written there directly) is cut from it first: two
    /// ChatViews would share one cached ChatViewModel, and the first to
    /// leave stops the other's stream (Bugbot, PR #197).
    func selectCoordinator() {
        if let coordinator = coordinatorConvoID { cutFromPagedStacks(coordinator) }
        coordinatorPath = []
        tab = .coordinator
    }

    /// Cuts `convoID`, with everything above it, from every stack but the
    /// Coordinator's own.
    private func cutFromPagedStacks(_ convoID: String) {
        for other in AppTab.allCases where other != .coordinator {
            let stack = path(of: other)
            if let index = stack.firstIndex(of: convoID) { write(Array(stack[..<index]), to: other) }
        }
    }

    /// "Open conversation" from a Decisions row or an item on the
    /// Decisions stack: pushed onto that stack, so Back returns to the
    /// item (or the list) it was opened from.
    func openConversation(fromDecisions convoID: String) {
        pushConversation(convoID, on: .decisions)
    }

    /// Open a mission from anywhere: select the tab and REPLACE the stack,
    /// so the page is never stacked on a stale copy of itself. No-op on an
    /// old journal that has no Missions tab to select.
    func openMission(_ missionID: String) {
        guard missionsSupported else { return }
        tab = .missions
        let route = MissionRoute(id: missionID).pathValue
        if missionsPath != [route] { missionsPath = [route] }
    }

    /// Push a mission onto the Missions stack without changing the tab —
    /// e.g. a `#N` that resolves to another mission from a mission page.
    /// No-op when that mission is already the top entry, mirroring
    /// `ChatView.pushMission(_:onto:)` — a double tap must not stack two
    /// identical pages.
    func pushMission(_ missionID: String) {
        let route = MissionRoute(id: missionID).pathValue
        guard missionsPath.last != route else { return }
        missionsPath.append(route)
    }

    /// Same double-tap guard as `pushMission`: a second tap on the row
    /// that just pushed never stacks a second copy of the page.
    func pushMissionItem(_ itemID: String) {
        let route = ItemRoute(id: itemID).pathValue
        guard missionsPath.last != route else { return }
        missionsPath.append(route)
    }

    /// Every Missions dashboard tap (spec 2026-09-28 §3.1): a card pushes
    /// its page, a session opens its chat the way a mission page's
    /// conversation row does, a needs-you row pushes the item — all on the
    /// Missions stack.
    func handleDashboard(_ action: MissionsDashboardAction) {
        switch action {
        case .openMission(let id): pushMission(id)
        case .openSession(let id): openConversation(fromMissions: id)
        case .openItem(let id): pushMissionItem(id)
        }
    }

    /// A project from outside the Projects tab (a mission page on a chat
    /// stack): the Projects tab comes forward on that page.
    func openProject(_ projectID: String) {
        guard missionsSupported else { return }
        tab = .missions
        let route = ProjectRoute(id: projectID).pathValue
        if missionsPath != [route] { missionsPath = [route] }
    }

    /// Push a project onto the Projects stack without changing the tab.
    /// When that project is already on the stack — the top entry (a
    /// double tap) or below it (a mission page's project chip, the
    /// breadcrumb back up to the project it was opened from) — pop back
    /// to the existing page instead of stacking a second copy.
    func pushProject(_ projectID: String) {
        let route = ProjectRoute(id: projectID).pathValue
        if let index = missionsPath.lastIndex(of: route) {
            let popped = Array(missionsPath[...index])
            if missionsPath != popped { missionsPath = popped }
        } else {
            missionsPath.append(route)
        }
    }

    /// Every navigation tap on the Projects home. `.newProject` and
    /// `.moveMission` are the tab root's own (a sheet, a write).
    func handleProjectsHome(_ action: ProjectsHomeAction) {
        switch action {
        case .openProject(let id): pushProject(id)
        case .openMission(let id): pushMission(id)
        case .newProject, .moveMission: break
        }
    }

    // MARK: Memories (spec 2026-09-27 memories; decision #3948)
    //
    // The Memories list rides the Missions tab's stack: its entry is a
    // toolbar button on the Missions root, and the editor pushes on top.

    /// Whether the Memories screen is on the Missions stack — the shell
    /// stops the screen's live refetch once it is not.
    var memoriesShown: Bool { missionsPath.contains(MemoriesRoute.list) }

    /// Show the Memories list on the Missions tab, REPLACING the stack so it
    /// is never stacked on a stale copy of itself.
    func openMemories() {
        guard missionsSupported else { return }
        tab = .missions
        if missionsPath != [MemoriesRoute.list] { missionsPath = [MemoriesRoute.list] }
    }

    /// Push one memory's editor; a double tap never stacks two.
    func openMemory(_ name: String) {
        let route = MemoryRoute(id: name).pathValue
        guard missionsPath.last != route else { return }
        missionsPath.append(route)
    }

    func openNewMemory() {
        guard missionsPath.last != MemoriesRoute.newMemory else { return }
        missionsPath.append(MemoriesRoute.newMemory)
    }

    /// After a save, as the web tracker does: a new memory's form becomes
    /// that memory's editor; an edit returns to the list.
    func memorySaved(name: String, wasNew: Bool) {
        guard let last = missionsPath.last, MemoriesRoute.isMemoriesRoute(last), last != MemoriesRoute.list else { return }
        missionsPath.removeLast()
        if wasNew { missionsPath.append(MemoryRoute(id: name).pathValue) }
    }

    /// After a delete: back to the list.
    func memoryDeleted() {
        guard let last = missionsPath.last, MemoryRoute(pathValue: last) != nil else { return }
        missionsPath.removeLast()
    }

    /// "Open the conversation" from a mission or project page, a dashboard
    /// row or a milestone: pushed onto the Missions stack, so Back returns
    /// to the page it was opened from. A copy already on the stack (the
    /// chat a mission page was opened from) is popped back to rather than
    /// stacked twice.
    func openConversation(fromMissions convoID: String) {
        pushConversation(convoID, on: .missions)
    }

    /// The Conversations stack binding's setter: a chat-list link or
    /// origin link writes the whole new path here BEFORE anything mounts
    /// (see `setPath`).
    func setChatPath(_ new: [String]) { setPath(new, on: .conversations) }

    /// The Coordinator tab's stack binding setter: a second copy of the
    /// Coordinator pops the stack to its root (see `setPath`).
    func setCoordinatorPath(_ new: [String]) { setPath(new, on: .coordinator) }

    /// `stack` cut at its first chat id that `other` also holds, with
    /// everything above it. Item and mission routes are pages, not chats,
    /// and never count.
    private static func cut(_ stack: [String], sharingChatsWith other: [String]) -> [String] {
        let chats = Set(other.filter { !isAnyPathPrefixedRoute($0) })
        guard let index = stack.firstIndex(where: { chats.contains($0) }) else { return stack }
        return Array(stack[..<index])
    }

    func pushDecision(_ itemID: String) {
        decisionsPath.append(ItemRoute(id: itemID).pathValue)
    }

    /// A tap on the app-wide voice-note pill (mission 5840): back to the
    /// place the note is for. A conversation opens like any deep link; an
    /// item comes up on Decisions, not stacked twice when it is already
    /// the top page there.
    func openVoiceNoteTarget(_ kind: VoiceNoteSession.Target.Kind) {
        switch kind {
        case .conversation(let id):
            openChat(id)
        case .item(let id):
            tab = .decisions
            let route = ItemRoute(id: id).pathValue
            if decisionsPath.last != route { decisionsPath.append(route) }
        }
    }

    /// Push onto a specific tab's stack without changing the selection.
    func push(_ value: String, on tab: AppTab) {
        setPath(path(of: tab) + [value], on: tab)
    }

    /// Whether the selected tab is showing its root (nothing pushed).
    var isAtRoot: Bool {
        switch tab {
        case .coordinator: return coordinatorPath.isEmpty
        case .conversations: return chatPath.isEmpty
        case .decisions: return decisionsPath.isEmpty
        case .missions: return missionsPath.isEmpty
        }
    }

    /// Dan, 2026-09-09: swipe between the conversation list and the
    /// decisions list. A mostly horizontal drag past 80pt at a tab's ROOT
    /// moves one tab in bar order (left = next, right = previous). Deeper
    /// in a stack the chat's own pager and swipe-back own horizontal
    /// drags, so a non-empty path ignores it. Returns whether the tab
    /// changed, so the caller can animate only real switches.
    @discardableResult
    func swipeRoot(translation: CGSize) -> Bool {
        let tabs = Self.tabs(missionsSupported: missionsSupported)
        guard isAtRoot, abs(translation.width) > 80,
              abs(translation.width) > abs(translation.height),
              let index = tabs.firstIndex(of: tab) else { return false }
        let next = translation.width < 0 ? index + 1 : index - 1
        guard tabs.indices.contains(next) else { return false }
        tab = tabs[next]
        return true
    }
}
