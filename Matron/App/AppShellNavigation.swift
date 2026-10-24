import Foundation
import Observation
import MatronModels
import MatronViewModels

/// The bottom tabs (app shell, spec §3) and the pages under More. The bar
/// reads Coordinator, For you, Conversations, More, then Search as the
/// system's round button beside it: iOS draws that button only beside at
/// most four other tabs. More is our own tab, listing Projects and
/// Settings; either one, when selected, is drawn in More's place
/// (`barTab`), with its own stack as before. The Coordinator is the first
/// tab (a swipe or two away, never a sheet over the top). The app opens on
/// Conversations.
enum AppTab: Hashable, CaseIterable {
    case coordinator
    case decisions
    case conversations
    /// The More list itself: no stack of its own.
    case more
    case search
    /// Projects, under More.
    case missions
    /// Settings, under More.
    case settings
}

/// Navigation state of the signed-in shell: the selected tab and each
/// tab's stack path. An observable object rather than `@State` on the view
/// so the cross-tab rules (deep links land in Conversations; Decisions
/// hands off to Conversations) are plain, testable functions and so
/// tests can inject a pre-set state into `AppShellView`.
@MainActor @Observable
final class AppShellNavigation {
    /// Leaving the Coordinator tab, by any route, ends its way back
    /// (`coordinatorReturnTab`).
    var tab: AppTab = .conversations {
        didSet {
            if tab != .coordinator { coordinatorReturnTab = nil }
            if Self.moreTabs.contains(tab) { morePage = tab }
        }
    }
    /// What the More tab shows: its list, Projects or Settings. Kept while
    /// another tab is up, so the page (and its stack) stays mounted and
    /// coming back to More lands on it, as the system's More does. Only
    /// "More" at a page's root goes back to the list.
    private(set) var morePage: AppTab = .more
    private static let moreTabs: Set<AppTab> = [.more, .missions, .settings]
    /// The tab the app was on when it jumped to the Coordinator's
    /// conversation (a link, a mission or project page, a notification,
    /// search): the Coordinator's root then shows a Back button, and a
    /// swipe right goes back, to that tab, whose stack still holds the
    /// page the jump came from. Every other conversation is pushed where
    /// it was opened, so Back returns there; the Coordinator's lives on
    /// its own tab and has no stack beneath it. `nil` when the user
    /// chose the Coordinator tab themselves: a tab root has nothing to go
    /// back to, and the tab bar shows.
    private(set) var coordinatorReturnTab: AppTab?
    /// `false` once `GET /missions` 404s (set by `AppShellView` from
    /// `MissionsDashboardViewModel.isSupported`) — Projects is then absent
    /// from the More list (`moreEntries(missionsSupported:)`), so nothing
    /// may select it: `openMission` no-ops.
    /// The clamp lives here, in the setter, rather than in a view
    /// `onChange`, so it is testable without one: a swipe that already
    /// landed on `.missions` in the window before a 404 answers is walked
    /// back to Conversations the instant the flag flips false.
    var missionsSupported = true {
        didSet {
            guard missionsSupported != oldValue, !missionsSupported else { return }
            if morePage == .missions { morePage = .more }
            guard tab == .missions else { return }
            tab = .conversations
        }
    }

    /// The tabs in the bar, left to right — the set `AppShellView`'s
    /// `TabView` renders.
    static let barTabs: [AppTab] = [.coordinator, .decisions, .conversations, .more, .search]

    /// What the More list offers, top to bottom, for a given support
    /// state: an old journal with no `/missions` routes has no Projects.
    static func moreEntries(missionsSupported: Bool) -> [AppTab] {
        missionsSupported ? [.missions, .settings] : [.settings]
    }

    /// The tabs a root swipe walks, in bar order. Not More, whose pages
    /// are a tap away in its list, and not Search, whose results list has
    /// no root swipe and so is never swiped onto or off.
    static let swipeTabs: [AppTab] = [.coordinator, .decisions, .conversations]

    /// The bar's selection: a page under More selects More.
    var barTab: AppTab {
        tab == .missions || tab == .settings ? .more : tab
    }

    /// A tap in the bar. Tapping More while one of its pages shows is
    /// already the selection, so the page stays; coming to More from
    /// another tab returns to the page it was on.
    func selectBarTab(_ selected: AppTab) {
        guard selected != barTab else { return }
        tab = selected == .more ? morePage : selected
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
    /// Settings tab stack. Its own pages push with `NavigationLink`s that
    /// carry their destination, so this stays empty in practice; it is a
    /// stack like the others so every cross-tab rule treats it the same.
    var settingsPath: [String] = []
    /// Search tab stack: what a result opens (an item, a mission or
    /// project page, a conversation) is pushed here, so Back returns to the
    /// results.
    var searchPath: [String] = []
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

    /// Open a conversation the app jumps to on the user's behalf — a
    /// notification tap, a search result, a new chat, the voice-note pill:
    /// pushed onto the stack of the tab the user is on, like a tapped
    /// link, so Back always returns to what they were looking at. From
    /// Settings, which carries no chats, it lands on Conversations. A chat
    /// already on that stack is popped back to rather than stacked twice.
    /// The Coordinator's conversation selects its own tab instead. A copy
    /// of the chat on another tab's stack is cut (see
    /// `cut(_:sharingChatsWith:)`).
    func openChat(_ roomID: String) {
        if roomID == coordinatorConvoID {
            selectCoordinator()
            return
        }
        let target = Self.jumpTab(from: tab, fallback: .conversations)
        tab = target
        pushConversation(roomID, on: target)
    }

    /// The tab a jump lands on: the one the user is on, so Back returns to
    /// where they were, except Settings, whose stack carries no chats,
    /// items or pages, and the More list, which has no stack; jumps from
    /// there land on `fallback`.
    static func jumpTab(from tab: AppTab, fallback: AppTab) -> AppTab {
        tab == .settings || tab == .more ? fallback : tab
    }

    /// A tapped conversation link or pill in a message:
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
    /// resolved to its page: pushed onto the stack of the tab the link was
    /// tapped in — every stack carries mission and project pages — so Back
    /// returns to where the link sat; a double tap never stacks two.
    func openPageLink(_ target: MatronPageTarget) {
        guard missionsSupported else { return }
        let onto = Self.jumpTab(from: tab, fallback: .missions)
        tab = onto
        switch target {
        case .mission(let id):
            let route = MissionRoute(id: id).pathValue
            guard path(of: onto).last != route else { return }
            push(route, on: onto)
        case .project(let id):
            pushProject(id, on: onto)
        }
    }

    /// A conversation the user chose to open from where they are (a link,
    /// a mission or project page, an item's "Open conversation"): pushed
    /// onto `target`'s stack, so Back returns to the page it was opened
    /// from. Jumps the app makes for the user (`openChat`) push the same
    /// way. The Coordinator's conversation selects its own tab.
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
        case .settings: return settingsPath
        case .search: return searchPath
        case .more: return []
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
        case .settings: settingsPath = path
        case .search: searchPath = path
        case .more: break
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
            let from = tab
            let wasOnScreen = tab != .coordinator && path(of: tab).contains(id)
            cutFromPagedStacks(id)
            if wasOnScreen {
                tab = .coordinator
                coordinatorReturnTab = from
            }
        }
    }

    /// Selects the Coordinator tab at its root. The same conversation open
    /// on another stack (written there directly) is cut from it first: two
    /// ChatViews would share one cached ChatViewModel, and the first to
    /// leave stops the other's stream (Bugbot, PR #197). Called from
    /// another tab, that tab becomes the way back
    /// (`coordinatorReturnTab`); called on the Coordinator tab, the way
    /// back it already had stays.
    func selectCoordinator() {
        let from = tab
        if let coordinator = coordinatorConvoID { cutFromPagedStacks(coordinator) }
        coordinatorPath = []
        tab = .coordinator
        if from != .coordinator { coordinatorReturnTab = from }
    }

    /// Back from the Coordinator's root: the tab the jump came from, at
    /// the page it was showing. Projects falls back to Conversations once
    /// the journal turns out to have no Missions tab.
    func returnFromCoordinator() {
        guard tab == .coordinator, let back = coordinatorReturnTab else { return }
        tab = back == .missions && !missionsSupported ? .conversations : back
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

    /// Push a project onto a tab's stack (the Projects stack by default)
    /// without changing the tab. When that project is already on the
    /// stack — the top entry (a double tap) or below it (a mission page's
    /// project chip, the breadcrumb back up to the project it was opened
    /// from) — pop back to the existing page instead of stacking a second
    /// copy.
    func pushProject(_ projectID: String, on target: AppTab = .missions) {
        let route = ProjectRoute(id: projectID).pathValue
        let stack = path(of: target)
        if let index = stack.lastIndex(of: route) {
            setPath(Array(stack[...index]), on: target)
        } else {
            setPath(stack + [route], on: target)
        }
    }

    /// Every navigation tap on the Projects home. `.newProject` and
    /// `.moveMission` are the tab root's own (a sheet, a write).
    func handleProjectsHome(_ action: ProjectsHomeAction) {
        switch action {
        case .openProject(let id): pushProject(id)
        case .openMission(let id): pushMission(id)
        case .openItem(let id): pushMissionItem(id)
        // The shell parks the jump to `seq` itself (`openMilestone`); this
        // is the plain open for any other caller.
        case .openConversation(let convoID, _): openConversation(fromMissions: convoID)
        case .newProject, .moveMission: break
        }
    }

    // MARK: Memories (spec 2026-09-27 memories)
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

    /// Push one box file's read-only page; a double tap never stacks two.
    func openLocalMemory(_ ref: LocalMemoryRef) {
        let route = LocalMemoryRoute(ref: ref).pathValue
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

    /// A tap on the app-wide voice-note pill: back to the
    /// place the note is for, opened like any jump (`openChat`, `openItem`).
    func openVoiceNoteTarget(_ kind: VoiceNoteSession.Target.Kind) {
        switch kind {
        case .conversation(let id): openChat(id)
        case .item(let id): openItem(id)
        }
    }

    /// An item the app jumps to (Go to number, an incoming link, the
    /// voice-note pill): pushed onto the tab the user is on — every stack
    /// but Settings' carries item pages — so Back returns to where they
    /// were. From Settings it lands under For you. Not stacked twice when
    /// it is already the top page there.
    func openItem(_ itemID: String) {
        let target = Self.jumpTab(from: tab, fallback: .decisions)
        tab = target
        let route = ItemRoute(id: itemID).pathValue
        guard path(of: target).last != route else { return }
        push(route, on: target)
    }

    /// A number resolved by "Go to number": an item opens where the user
    /// is, as the voice-note pill's does; a mission or project page as its
    /// link would (a milestone resolves to its mission's page).
    func openNumberTarget(_ target: GoToNumberTarget) {
        switch target {
        case .item(let id): openVoiceNoteTarget(.item(id))
        case .page(let page): openPageLink(page)
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
        case .settings: return settingsPath.isEmpty
        case .search: return searchPath.isEmpty
        case .more: return true
        }
    }

    /// Swipe between the conversation list and the
    /// decisions list. A mostly horizontal drag past 80pt at a tab's ROOT
    /// moves one tab in bar order (left = next, right = previous). Deeper
    /// in a stack the chat's own pager and swipe-back own horizontal
    /// drags, so a non-empty path ignores it. Returns whether the tab
    /// changed, so the caller can animate only real switches.
    @discardableResult
    func swipeRoot(translation: CGSize) -> Bool {
        let tabs = Self.swipeTabs
        guard isAtRoot, abs(translation.width) > 80,
              abs(translation.width) > abs(translation.height),
              let index = tabs.firstIndex(of: tab) else { return false }
        let next = translation.width < 0 ? index + 1 : index - 1
        guard tabs.indices.contains(next) else { return false }
        tab = tabs[next]
        return true
    }
}
