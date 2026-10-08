import Foundation
import Observation
import MatronEvents
import MatronModels
import MatronJournal

/// Backs the item detail sheet: one item, its comments, and the local
/// outbox of comments/creates still in flight. Writes go through
/// `ItemsSyncing`, which owns the outbox and refetch coalescing — this view
/// model calls `refreshItem` after every mutating action without worrying
/// about de-duping concurrent calls.
@MainActor @Observable
public final class ItemDetailViewModel {
    public let itemID: String
    public private(set) var item: TrackerItem? { didSet { reportSeen() } }
    public private(set) var comments: [TrackerComment] = [] { didSet { reportSeen() } }
    public private(set) var pendingComments: [ItemOutboxRecord] = [] {
        // A reply withdrawn here stays hidden even if a snapshot taken before
        // its row was deleted is delivered after (`cancelPendingReply`).
        didSet {
            if !withdrawnOutboxIDs.isEmpty, pendingComments.contains(where: { withdrawnOutboxIDs.contains($0.localID) }) {
                pendingComments.removeAll { withdrawnOutboxIDs.contains($0.localID) }
            }
        }
    }
    /// Outbox replies Cancel has withdrawn (or is withdrawing) on this view
    /// model, by local id.
    private var withdrawnOutboxIDs: Set<String> = []
    public var draft = ""
    /// Files dropped, pasted or picked into the reply composer but not yet
    /// sent, in the order they were added — the same tray the chat composer
    /// keeps (`ComposerViewModel.stagedAttachments`). They leave with the
    /// typed text as ONE comment on Send (`submitComment()`), rather than
    /// each posting on arrival as its own bodiless comment.
    public private(set) var stagedAttachments: [StagedAttachment] = []
    public var error: String?
    /// Replies between Send and the thread showing them, oldest first. Send
    /// clears the field and tray at the tap (as chat does), and a reply
    /// uploads before it is queued and is queued before the outbox stream
    /// shows it — without these it would be visible nowhere in between.
    /// Hosts draw each as a "Sending…" row at the end of the thread. A list,
    /// not one slot: as in chat, the next reply can be sent while an
    /// earlier one is still settling, and each is settled by its own id.
    public private(set) var sendingReplies: [SendingReply] = []

    /// Hands each queued sending row over to whatever now shows its reply.
    /// Runs after queueing and on every outbox/comments stream delivery;
    /// each reply is judged by its OWN id:
    /// - the outbox stream has delivered its row → the pending row shows it;
    /// - the store still has its row but the stream hasn't caught up (or
    ///   delivered a stale, pre-insert snapshot) → keep showing it;
    /// - the store no longer has its row → the drain posted it (the row's
    ///   delete and the comment's insert are one transaction; a poison
    ///   drop writes nothing): show the store's thread and let the row go
    ///   in the same update, so the reply never vanishes or doubles.
    /// Replies still uploading are left alone.
    private func settleSendingReplies() {
        guard sendingReplies.contains(where: \.isQueued) else { return }
        let shown = Set(pendingComments.map(\.localID))
        let stored = (try? store.itemOutboxRows(itemID: itemID)).map { Set($0.map(\.localID)) }
        var posted = false
        sendingReplies.removeAll { reply in
            guard reply.isQueued else { return false }
            if shown.contains(reply.localID) { return true }
            if stored?.contains(reply.localID) == true { return false }
            posted = true
            return true
        }
        if posted, let fresh = try? store.comments(itemID: itemID) { comments = fresh }
    }

    private func removeSendingReply(_ localID: String) {
        sendingReplies.removeAll { $0.localID == localID }
    }

    public struct SendingReply: Equatable, Sendable {
        public let localID: String
        public let body: String
        public let attachmentCount: Int
        /// In the outbox (not just uploading) — only then can it settle.
        public internal(set) var isQueued = false
    }
    /// True while a write is in flight. A count, not a flag: a voice note
    /// stopped from the app-wide indicator can go out while a typed reply
    /// is still uploading, and the first to finish must not report the
    /// other as done.
    public var isBusy: Bool { busyCount > 0 }
    private var busyCount = 0
    /// The size of the thread once the opening `refreshItem` has completed
    /// — `nil` until then (Bugbot, PR #198). `ItemDetailView` uses it to
    /// tell the opening load apart from a new reply: growth whose starting
    /// count is below this number is the load (or a stale replay of it)
    /// and must not drag an unread thread to its end. Set on completion
    /// whether or not the refetch succeeded: a failed refetch leaves the
    /// cached thread as the thread. The refetch is awaited to its end even
    /// when coalesced with one already in flight, `comments` is read
    /// straight from the store before this is set, and the comments stream
    /// is re-subscribed so a pre-refetch snapshot still in flight on the
    /// old subscription can never overwrite the loaded thread.
    public private(set) var loadedCommentCount: Int?
    /// The spawn consent ask this item mirrors — `nil` unless
    /// the item carries a `matron://consent/spawn/<id>` link. Re-derived
    /// whenever the item, its thread, or the origin conversation's consent
    /// rows change: the journal closes the item right after appending the
    /// ask's `spawn_outcome`, and the card itself may sync after the item
    /// was opened.
    public private(set) var spawnConsent: ItemSpawnConsent?

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    /// The origin conversation's consent rows — the card's own payload and
    /// its outcome. Optional so existing call sites construct unchanged; a
    /// view model without it draws no card and so never answers.
    private let events: (any ConsentEventsReading)?
    /// The latest rows from `events` for `consentConvoID`, kept by the
    /// subscription below so every re-derivation reads the same snapshot.
    private var consentRows: [JournalEvent] = []
    private var consentConvoID: String?
    private var consentTask: Task<Void, Never>?
    /// Answers the ask. Optional for the same reason `ChatViewModel`'s is:
    /// with nothing wired, the card renders read-only rather than offering
    /// buttons that would do nothing.
    private let agentSpawn: (any AgentSpawnAnswering)?
    /// The in-flight answer's state (`.sending`, a `.failed` message, or the
    /// synthetic resolution a 409 settles the card with). In memory only,
    /// like `ChatViewModel.agentSpawnTransientStates`: an interrupted send
    /// must come back answerable, and a real resolution comes from the
    /// store, not from here.
    private var spawnTransient: AgentSpawnCardState?
    private var tasks: [Task<Void, Never>] = []
    private var commentsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(itemID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing,
                events: (any ConsentEventsReading)? = nil, agentSpawn: (any AgentSpawnAnswering)? = nil,
                seen: SeenTracker? = nil,
                queuedCards: (any QueuedRepliesReading)? = nil, queuedRelease: (any QueuedReplySending)? = nil,
                contextStore: (any ItemContextReading)? = nil,
                refreshMission: (@Sendable (String) async -> Void)? = nil) {
        self.itemID = itemID; self.store = store; self.api = api; self.sync = sync
        self.events = events; self.agentSpawn = agentSpawn; self.seen = seen
        self.queuedCards = queuedCards; self.queuedRelease = queuedRelease
        self.contextStore = contextStore; self.refreshMission = refreshMission
    }

    // MARK: Context

    /// The item's mission and its owner conversation (the one that filed
    /// it), for the detail's header — see `ItemContext.make`.
    /// `currentConvoID` is the conversation the detail is shown inside,
    /// whose row would only point back at it.
    public func context(currentConvoID: String?) -> ItemContext {
        guard let item else { return ItemContext() }
        let mission = contextMission?.id == item.missionID ? contextMission : nil
        let owner = ownerConvoID == item.originConvoID ? ownerState : .unknown
        return ItemContext.make(item: item, currentConvoID: currentConvoID, mission: mission,
                                ownerLabel: owner.label, ownerIsOpenable: owner.exists)
    }

    /// Reads for the context block. Optional so existing call sites
    /// construct unchanged; without it the block names the owner from the
    /// item alone and the mission by number.
    private let contextStore: (any ItemContextReading)?
    /// Fetches one mission's detail into the store (`MissionsSync
    /// .refreshMission`), kicked once when this device has no row for the
    /// item's mission, so the row can name it.
    private let refreshMission: (@Sendable (String) async -> Void)?
    private var contextMission: Mission?
    /// Whether this device has the owner conversation, and its local
    /// label, for `ownerConvoID` — checked against the item's origin like
    /// `contextMission` against its mission.
    private var ownerState: JournalStore.ConversationOrigin = .unknown
    private var ownerConvoID: String?
    /// The mission and owner the streams below follow, and whether the
    /// mission stream has started — so an item update that leaves both
    /// alone costs nothing.
    private var contextMissionID: String?
    private var contextSubscribed = false
    private var contextOriginID: String?
    private var contextTask: Task<Void, Never>?
    private var ownerTask: Task<Void, Never>?

    /// Follows the item's mission, and kicks one detail fetch for it when
    /// this device lacks the mission row. Keyed on the mission, like
    /// `subscribeConsentRows` on the conversation.
    private func subscribeContext() {
        guard let item else { return }
        let originChanged = item.originConvoID != contextOriginID
        let missionChanged = item.missionID != contextMissionID
        contextOriginID = item.originConvoID
        if missionChanged {
            contextMissionID = item.missionID
            contextMission = nil
        }
        if originChanged { subscribeOwner(item.originConvoID) }
        guard missionChanged || !contextSubscribed else { return }
        contextTask?.cancel(); contextTask = nil
        contextSubscribed = true
        guard let missionID = item.missionID, let contextStore else { return }
        let refreshMission = refreshMission
        contextTask = Task { [weak self] in
            var fetched = false
            for await mission in contextStore.missionStream(id: missionID) {
                guard let self, !Task.isCancelled else { return }
                self.contextMission = mission
                if mission == nil, !fetched, let refreshMission {
                    fetched = true
                    Task { await refreshMission(missionID) }
                }
            }
        }
    }

    /// Follows the owner conversation's row, so an owner that syncs after
    /// the item opened becomes a link with its own label. A granted item's
    /// owner is "": nothing to follow.
    private func subscribeOwner(_ convoID: String) {
        ownerTask?.cancel(); ownerTask = nil
        guard let contextStore, !convoID.isEmpty else { return }
        ownerTask = Task { [weak self] in
            for await state in contextStore.conversationOriginStream(id: convoID) {
                guard let self, !Task.isCancelled else { return }
                if self.ownerConvoID != convoID { self.ownerConvoID = convoID }
                if self.ownerState != state { self.ownerState = state }
            }
        }
    }

    // MARK: Queued replies

    /// The user's replies the agent hasn't got yet, by comment id: parked on
    /// the session's busy queue (with the card's Send now), or cancelled /
    /// never delivered. A reply that isn't here reached the agent. See
    /// `QueuedReplyState`.
    public private(set) var queuedReplies: [String: QueuedReplyState] = [:]
    private let queuedCards: (any QueuedRepliesReading)?
    private let queuedRelease: (any QueuedReplySending)?
    private var queuedRows: [JournalEvent] = []
    private var queuedConvoID: String?
    private var queuedTask: Task<Void, Never>?
    /// This device's Send now and Cancel taps in flight (`.sending`,
    /// `.cancelling`) or refused (`.sendFailed`), by comment id. In memory only: a tap that never
    /// reached the bridge must come back tappable, and the real outcome is
    /// the bridge's release row, which retires the entry.
    private var queuedTransient: [String: QueuedReplyState] = [:]
    /// How long a Send now or Cancel waits for the bridge's release before the reply
    /// goes back to tappable. A tap the bridge refuses (a card from before
    /// its restart, say) gets a notice in the conversation and no release,
    /// and "Sending now…" must not spin forever. Internal for tests.
    var sendNowConfirmTimeout: Duration = .seconds(20)
    /// The current Send now or Cancel attempt per comment: a timeout only
    /// fails the attempt that started it, never a later tap on the same reply.
    private var sendNowAttempts: [String: UUID] = [:]

    private func refreshQueuedReplies() {
        let derived = ItemQueuedReplies.derive(rows: queuedRows, itemID: itemID)
        // A release (or the card vanishing) settles any tap made here.
        queuedTransient = queuedTransient.filter { id, _ in
            if case .queued = derived[id] { return true }
            return false
        }
        let next = derived.merging(queuedTransient) { _, transient in transient }
        if next != queuedReplies { queuedReplies = next }
    }

    /// Follows the origin conversation's queue cards — the conversation the
    /// item's 📌 turns are delivered in. Keyed on the conversation, like the
    /// consent rows.
    private func subscribeQueuedRows() {
        let convoID = item?.originConvoID
        guard convoID != queuedConvoID else { return }
        queuedTask?.cancel(); queuedTask = nil
        queuedConvoID = convoID
        queuedRows = []
        refreshQueuedReplies()
        guard let convoID, let queuedCards else { return }
        queuedTask = Task { [weak self] in
            for await rows in queuedCards.queuedReleaseEventsStream(convoID: convoID) {
                guard let self, !Task.isCancelled else { return }
                self.queuedRows = rows
                self.refreshQueuedReplies()
            }
        }
    }

    /// Send now on a reply waiting on the busy queue: answers its card
    /// exactly as a tap on the card in the conversation would.
    public func sendQueuedReplyNow(commentID: String) async {
        await answerQueuedCard(commentID: commentID, pending: .sending, choice: { ItemQueuedReplies.sendNowChoice(offersSendOne: $0) },
                               unconfirmed: "The session hasn't confirmed it. Try again, or check the conversation.")
    }

    /// Cancel on a reply waiting on the busy queue: the
    /// card's own ✕ Cancel, which withdraws just this reply. The comment
    /// stays in the thread, marked cancelled once the bridge's release lands.
    public func cancelQueuedReply(commentID: String) async {
        await answerQueuedCard(commentID: commentID, pending: .cancelling, choice: { _ in ItemQueuedReplies.cancelChoice },
                               unconfirmed: "The session hasn't confirmed the cancel. Try again, or check the conversation.")
    }

    /// Answers a queued reply's card with `choice` (given whether the card
    /// can release one reply alone), showing `pending` until the bridge's
    /// release row settles it — or, after `sendNowConfirmTimeout`, handing
    /// the reply back as still queued with `unconfirmed`.
    private func answerQueuedCard(commentID: String, pending: QueuedReplyState, choice: (Bool) -> String,
                                  unconfirmed: String) async {
        let target: (convoID: String, seq: Int64, sendOne: Bool)
        switch queuedReplies[commentID] {
        case .queued(let c, let s, let o), .sendFailed(let c, let s, let o, _): target = (c, s, o)
        default: return
        }
        guard let queuedRelease else { return }
        let attempt = UUID()
        sendNowAttempts[commentID] = attempt
        queuedTransient[commentID] = pending
        refreshQueuedReplies()
        let failed = { (reason: String) in
            QueuedReplyState.sendFailed(convoID: target.convoID, targetSeq: target.seq, offersSendOne: target.sendOne, reason: reason)
        }
        do {
            try await queuedRelease.sendQueuedRelease(convoID: target.convoID, targetSeq: target.seq, choice: choice(target.sendOne))
        } catch {
            guard sendNowAttempts[commentID] == attempt else { return }
            queuedTransient[commentID] = failed("Couldn't reach the journal. Try again.")
            refreshQueuedReplies()
            return
        }
        try? await Task.sleep(for: sendNowConfirmTimeout)
        // Still this attempt, and nothing settled it: a release, a later tap
        // or the item closing all leave it alone.
        guard sendNowAttempts[commentID] == attempt, queuedTransient[commentID] == pending else { return }
        queuedTransient[commentID] = failed(unconfirmed)
        refreshQueuedReplies()
    }

    /// Send now on a reply still in this device's outbox: try it now rather
    /// than waiting out the retry backoff.
    public func sendPendingNow() async {
        await sync.drainOutbox()
    }

    /// Cancel on a reply still in this device's outbox: it leaves the outbox
    /// and is never posted, and a typed reply's text comes back to the reply
    /// box. A reply the drain is posting at this moment can't be withdrawn
    /// (the journal may already have it) and stays.
    public func cancelPendingReply(localID: String) async {
        guard let row = pendingComments.first(where: { $0.localID == localID }) else { return }
        // Hidden at the tap, so a second tap (a Mac double-click) finds
        // nothing to cancel rather than racing the first.
        withdrawnOutboxIDs.insert(localID)
        pendingComments.removeAll { $0.localID == localID }
        let result = await sync.cancelQueuedComment(localID: localID)
        guard result == .cancelled else {
            withdrawnOutboxIDs.remove(localID)
            // Back as the store has it: still queued, or gone because it
            // was posted (the thread shows it then).
            if let rows = try? store.itemOutboxRows(itemID: itemID) { pendingComments = rows }
            error = result == .alreadySent
                ? "That reply is already on its way and can't be cancelled."
                : "Couldn't cancel that reply. Try again."
            return
        }
        // A queued tap's body is just its button's label, nothing to edit.
        if row.commentAction == nil, let body = row.commentBody { restoreToDraft(body) }
        // An earlier attempt that failed on this side may still have reached
        // the journal: refetch, so a reply that landed shows in the thread
        // now rather than whenever the item next refreshes.
        await sync.refreshItem(id: itemID)
    }

    /// Edit and resend on a reply that never reached the agent (cancelled,
    /// or its session ended first): its text goes into the reply box to
    /// edit and send as a new reply. The original stays in the thread,
    /// marked as not sent.
    public func editAndResend(commentID: String) {
        switch queuedReplies[commentID] {
        case .cancelled, .notDelivered: break
        default: return
        }
        guard let comment = comments.first(where: { $0.id == commentID }) else { return }
        restoreToDraft(comment.body)
    }

    /// Puts a withdrawn reply's text into the reply box — after whatever is
    /// already typed there, never over it, and not again if the box already
    /// ends with it (a second tap).
    private func restoreToDraft(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !typed.hasSuffix(text) else { return }
        draft = typed.isEmpty ? text : typed + "\n\n" + text
    }

    // MARK: Read state (seen)

    /// Where the item reports being seen (`item_seen`); nil in tests and
    /// previews.
    private let seen: SeenTracker?
    /// The hosts showing this item right now. Distinct from started: a
    /// Mac pane keeps an item's view model running under the one pushed
    /// over it. A set, not a flag: a Mac width-crossing remount builds a
    /// new host for the same view model, and the old host's disappear can
    /// land after the new one's appear.
    private var onScreenHosts: Set<AnyHashable> = []
    private var isOnScreen: Bool { !onScreenHosts.isEmpty }

    /// `host` shows (or stops showing) this item. While any host shows it,
    /// the item and its newest comment count as seen, and each newer
    /// comment is reported as it renders.
    public func setOnScreen(_ onScreen: Bool, host: AnyHashable = "default") {
        let wasOnScreen = isOnScreen
        if onScreen { onScreenHosts.insert(host) } else { onScreenHosts.remove(host) }
        guard isOnScreen != wasOnScreen else { return }
        if isOnScreen { reportSeen() } else { seen?.removeItem(itemID) }
    }

    private func reportSeen() {
        guard isOnScreen, item != nil else { return }
        seen?.setItemOnScreen(itemID, newestComment: comments.map(\.createdAt).max())
    }

    public func start() {
        cancelSubscriptions()
        isStopped = false
        let id = itemID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemStream(id: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.item = v
                self.settleEnqueueingAction(with: v)
                self.subscribeConsentRows()
                self.subscribeQueuedRows()
                self.subscribeContext()
                self.refreshSpawnConsent()
            }
        })
        subscribeComments()
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemOutboxStream(itemID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.pendingComments = v
                self.settleEnqueueingAction(outbox: v)
                self.settleEnqueueingCommentActions(outbox: v)
                self.settleSendingReplies()
            }
        })
        // Comments only reach the local cache through a refetch — opening
        // the detail sheet must trigger one, not just rely on whatever the
        // panel last fetched.
        refreshTask?.cancel()
        loadedCommentCount = nil
        refreshTask = Task { [weak self] in
            await self?.sync.refreshItem(id: id)
            guard let self, !Task.isCancelled else { return }
            // Drop the old subscription first: its `for await` guard sees
            // the cancellation, so a pre-refetch snapshot it still holds
            // can no longer land after the loaded thread. The fresh
            // subscription's first value is the store as it is now.
            self.subscribeComments()
            if let fresh = try? self.store.comments(itemID: id) { self.comments = fresh }
            self.loadedCommentCount = self.comments.count
            self.refreshSpawnConsent()
        }
    }

    /// The item is closing (its view went away, or the Mac pane released
    /// its slot): stop observing, and delete the reply's staged copies —
    /// nothing will send them now, and they are our files to clean up.
    public func stop() {
        onScreenHosts.removeAll()
        seen?.removeItem(itemID)
        cancelSubscriptions()
        isStopped = true
        discardAttachments()
        // Safety: nothing will settle them once the streams are gone.
        sendingReplies = []
    }

    /// Set by `stop()`, cleared by `start()`. A send or an attach that was
    /// already in flight when the item closed finishes into a view model
    /// nobody will show again — it must delete what it would have put back
    /// in the tray rather than leave it on disk.
    private var isStopped = false

    private func cancelSubscriptions() {
        tasks.forEach { $0.cancel() }; tasks = []
        commentsTask?.cancel(); commentsTask = nil
        refreshTask?.cancel(); refreshTask = nil
        consentTask?.cancel(); consentTask = nil; consentConvoID = nil; consentRows = []
        queuedTask?.cancel(); queuedTask = nil; queuedConvoID = nil; queuedRows = []; queuedTransient = [:]
        sendNowAttempts = [:]
        // Keeps what it has, so a restart redraws no gap; the keys reset so
        // the next item delivery resubscribes to the mission and owner.
        contextTask?.cancel(); contextTask = nil
        ownerTask?.cancel(); ownerTask = nil
        contextSubscribed = false; contextOriginID = nil
    }

    private func subscribeComments() {
        commentsTask?.cancel()
        let id = itemID
        commentsTask = Task { [weak self] in
            guard let s = self?.store.commentsStream(itemID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.comments = v
                self.settleEnqueueingCommentActions(with: v)
                self.refreshSpawnConsent()
                self.settleSendingReplies()
            }
        }
    }

    // MARK: Spawn consent

    /// Rebuilds `spawnConsent` from the item and the origin conversation's
    /// consent rows. The card's facts come from the ask's own
    /// `permission_request` payload (never reconstructed from the item's
    /// markdown: what the user approves must be the card's words or
    /// nothing); the resolved state from its `spawn_outcome`, the last one
    /// for the request id winning should there ever be two.
    private func refreshSpawnConsent() {
        guard let item, let requestID = item.spawnConsentRequestID else {
            if spawnConsent != nil { spawnConsent = nil }
            return
        }
        var request: AgentSpawnRequest?
        var outcome: SpawnOutcome?
        for row in consentRows {
            switch row.type {
            case JournalEventType.permissionRequest:
                guard request == nil, let parsed = AgentSpawnRequest.parse(payload: row.payload),
                      parsed.requestID == requestID else { continue }
                request = parsed
            case JournalEventType.spawnOutcome:
                guard let parsed = SpawnOutcome.parse(payload: row.payload), parsed.requestID == requestID else { continue }
                outcome = parsed
            default:
                continue
            }
        }
        let next = ItemSpawnConsent(
            requestID: requestID, request: request,
            state: Self.spawnState(requestID: requestID, outcome: outcome, itemIsOpen: item.state == .open,
                                   transient: spawnTransient, canAnswer: agentSpawn != nil))
        if next != spawnConsent { spawnConsent = next }
    }

    /// Follows the origin conversation's consent rows for as long as the
    /// item is a consent ask. Keyed on the conversation, not the item: an
    /// item update that leaves the origin alone keeps the subscription.
    private func subscribeConsentRows() {
        let convoID = item?.spawnConsentRequestID == nil ? nil : item?.originConvoID
        guard convoID != consentConvoID else { return }
        consentTask?.cancel(); consentTask = nil
        consentConvoID = convoID
        consentRows = []
        guard let convoID, let events else { return }
        consentTask = Task { [weak self] in
            for await rows in events.consentEventsStream(convoID: convoID) {
                guard let self, !Task.isCancelled else { return }
                self.consentRows = rows
                self.refreshSpawnConsent()
            }
        }
    }

    /// Where the ask is, in order of authority:
    ///
    /// 1. A `spawn_outcome` row for the request — the server's durable word,
    ///    outranking everything (answered on another device, expired by the
    ///    sweep: history here too).
    /// 2. A closed item with no local outcome — the row stopped awaiting an
    ///    answer. The journal closes the item the moment the ask is answered,
    ///    which for an approval is before the session has started (a sleeping
    ///    box is woken first), so the outcome row can be minutes behind. If
    ///    this device's own answer settled the card (its Approve was accepted,
    ///    or a 409 told it the ask was gone), that stands; otherwise the ask
    ///    was answered elsewhere and reads as "no longer waiting", the same
    ///    sentence a 409 earns. A `.sending` never survives a closed item, so
    ///    it cannot spin on after the item settled.
    /// 3. The in-flight transient.
    /// 4. Answerable when an answerer is wired; otherwise read-only, the
    ///    timeline card's own convention.
    static func spawnState(requestID: String, outcome: SpawnOutcome?, itemIsOpen: Bool,
                           transient: AgentSpawnCardState?, canAnswer: Bool) -> AgentSpawnCardState {
        if let outcome { return .resolved(outcome) }
        if !itemIsOpen {
            if let transient, transient.isResolved { return transient }
            return .resolved(.expired(requestID: requestID))
        }
        if let transient { return transient }
        return canAnswer ? .idle : .resolved(.expired(requestID: requestID))
    }

    /// Answers the spawn ask — `POST /agent-spawn/answer`, the one path that
    /// resolves it, exactly as the timeline card answers it. Only against
    /// the card's own payload: the request id comes from a link any agent
    /// can write into any item, so an item whose card has not synced could
    /// be an ask the user has never seen (another conversation's request id
    /// in a benign-looking body). No card, no answer. An accepted answer
    /// settles the card with what the user just did until the journal's
    /// outcome row lands: approved-and-starting (the journal closes the item
    /// at the approval, and approving is not "done" until the child has
    /// started, which the outcome row says), or declined (final at the
    /// answer). A 409 (answered elsewhere, or expired) settles the card as
    /// no longer waiting and refetches the item: the local copy that still
    /// offered the buttons was stale, and the refetch is what takes it out
    /// of the Decisions list. Any other error settles into the card and
    /// leaves it answerable again; cancellation just drops the in-flight
    /// state.
    public func answerSpawn(approve: Bool) async {
        guard let agentSpawn, let consent = spawnConsent, consent.request != nil else { return }
        switch consent.state {
        case .resolved, .sending: return
        case .idle, .failed: break
        }
        spawnTransient = .sending
        refreshSpawnConsent()
        do {
            try await agentSpawn.answerAgentSpawn(requestID: consent.requestID, decision: approve ? .approve : .deny)
            spawnTransient = .resolved(approve
                ? .approved(requestID: consent.requestID)
                : SpawnOutcome(requestID: consent.requestID, outcome: SpawnOutcome.Kind.declined.rawValue))
            await sync.refreshItem(id: itemID)
        } catch is CancellationError {
            spawnTransient = nil
        } catch JournalAPIError.conflict {
            spawnTransient = .resolved(.expired(requestID: consent.requestID))
            await sync.refreshItem(id: itemID)
        } catch {
            spawnTransient = .failed(ChatViewModel.describeAgentSpawnError(error))
        }
        refreshSpawnConsent()
    }

    /// The resolutions the person can close this item with, primary
    /// first. Only outcomes they can honestly claim: a question is
    /// answered by *replying* (the journal hands it back to the agent,
    /// which closes it as answered once it has acted), so "Answered" is
    /// offered only once they have actually replied — before that the
    /// only honest close is to dismiss it. An open decision is already in
    /// force, so reversing it leads. A reply still in the outbox counts
    /// (Bugbot): it is the user's, and it will land.
    ///
    /// A consent ask still awaiting its answer offers none:
    /// Approve and Decline are its only honest closes. Cancelling the item
    /// would hide it while the spawn request stays parked on the journal
    /// for its full life — the journal closes the item itself on every
    /// terminal outcome. Only *awaiting*, though (Bugbot, PR #230): a
    /// closed item offers Reopen, and a user's comment on a closed item
    /// reopens it too. Once the card has resolved — an outcome row, a 409
    /// answered elsewhere — there is nothing left to park unseen, and the
    /// reopened item closes like any other question. A card that has not
    /// synced yet (no request) still counts as awaiting.
    public var availableResolutions: [ItemResolution] {
        if let item, item.isConsentAsk, item.state == .open, !(spawnConsent?.state.isResolved ?? false) { return [] }
        return Self.resolutions(for: item?.kind,
                                userHasReplied: !pendingComments.isEmpty || comments.contains { $0.author == .user && $0.kind == .comment })
    }

    static func resolutions(for kind: ItemKind?, userHasReplied: Bool) -> [ItemResolution] {
        switch kind {
        case .task, .notice: return [.done, .cancelled]
        case .question: return userHasReplied ? [.answered, .cancelled] : [.cancelled]
        case .decision: return [.reversed, .decided, .cancelled]
        case nil: return []
        }
    }

    /// Whether `submitComment()` would do anything — the composer's send
    /// gate. A staged attachment on its own is a perfectly good reply, so
    /// this is not simply "is there text" (mirrors `ComposerViewModel.canSend`).
    public var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty
    }

    /// Sends the composer's contents — the typed text plus every staged
    /// attachment — as one comment. Uploads the attachments first, then
    /// enqueues the comment (localID is minted here, not by `ItemsSyncing`
    /// — the outbox record needs it before the enqueue call returns so the
    /// pending-comments stream can show it).
    ///
    /// Mirrors `ComposerViewModel.send()`: the field and tray clear in the
    /// same tick as the tap, so text typed while the uploads run (the Mac
    /// field stays editable) is the NEXT reply, never wiped by a late
    /// clear. An upload failure (offline, say) happens before anything is
    /// queued: the attachments go back at the front of the tray and the
    /// text comes back — unless the user has already typed something new,
    /// which a restore must not overwrite (the error still says what
    /// happened). Once the uploads land the comment is durable: the outbox
    /// holds the text and blob refs and retries on its own; `submitComment`
    /// returns as soon as the reply is queued, without awaiting delivery.
    public func submitComment() async {
        guard canSubmit, !isBusy else { return }
        if let failure = await sendReply(leading: nil) { error = failure }
    }

    /// A staged voice note leading a reply, and where the recorder wrote
    /// it — a note that can't go back to a closed item's tray is moved
    /// back there, so `VoiceNoteSession` can still offer Retry.
    private struct LeadingVoiceNote {
        let attachment: StagedAttachment
        let recording: URL
    }

    /// The send itself, shared by the send button and voice notes: the
    /// text as the body, then the tray, with `leading` (a staged voice
    /// note) as the FIRST attachment when given — one comment, so the
    /// agent gets the text, the transcript and the attachments in one 📌
    /// turn. Returns `nil` once queued, or the failure's message with
    /// everything already back in the composer for its caller to report.
    private func sendReply(leading note: LeadingVoiceNote?) async -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = (note.map { [$0.attachment] } ?? []) + stagedAttachments
        busyCount += 1
        defer { busyCount -= 1 }
        let pending = draft
        let localID = UUID().uuidString
        draft = ""
        stagedAttachments = []
        sendingReplies.append(SendingReply(localID: localID, body: text, attachmentCount: attachments.count))
        var uploaded: [TrackerAttachment] = []
        do {
            for a in attachments {
                let url = a.url
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                let ref = try await api.uploadMedia(data, contentType: a.mimeType)
                uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mimeType, name: a.filename, size: Int64(data.count)))
            }
        } catch {
            restoreUnsent(attachments, text: pending, note: note, localID: localID)
            return "Couldn't upload an attachment: \(error.localizedDescription)"
        }
        // Returns once the outbox row is durable; delivery is the drain's.
        let queued = await sync.queueComment(itemID: itemID, localID: localID, body: text, attachments: uploaded)
        guard queued else {
            // Nothing was queued (sync stopped, or the local write failed):
            // the reply comes back whole — text and tray, staged copies
            // intact — as on an upload failure. Its uploaded blobs are
            // orphaned; a retry uploads again.
            restoreUnsent(attachments, text: pending, note: note, localID: localID)
            return "Couldn't queue your reply."
        }
        attachments.forEach { $0.deleteStagedCopy() }
        // The sending row stays until the thread can show the reply itself.
        if let index = sendingReplies.firstIndex(where: { $0.localID == localID }) {
            sendingReplies[index].isQueued = true
        }
        settleSendingReplies()
        return nil
    }

    /// Puts a reply that didn't go out back in the composer: its
    /// attachments at the front of the tray, ahead of anything attached
    /// meanwhile, and its text unless something new has been typed. A
    /// closed item has no tray to go back to: its staged copies are
    /// deleted, and a leading voice note is moved back to the recorder's
    /// file instead, for `VoiceNoteSession`'s Retry.
    private func restoreUnsent(_ attachments: [StagedAttachment], text pending: String,
                               note: LeadingVoiceNote?, localID: String) {
        removeSendingReply(localID)
        if draft.isEmpty { draft = pending }
        guard isStopped else {
            stagedAttachments = attachments + stagedAttachments
            return
        }
        for attachment in attachments {
            if let note, attachment.id == note.attachment.id {
                try? FileManager.default.moveItem(at: attachment.url, to: note.recording)
            }
            attachment.deleteStagedCopy()
        }
    }

    /// The largest file the tray accepts. Tracker uploads have always been
    /// capped here (the Mac pane's old attach path enforced it); the check
    /// runs at attach time so an oversized file is refused while the user
    /// is still looking at what they picked, not at Send.
    public nonisolated static let maxAttachmentBytes = 25 * 1024 * 1024

    /// The refusal for a file over `maxAttachmentBytes`, shared with the
    /// iOS host's pre-read check so both say the same thing.
    public nonisolated static func oversizeMessage(filename: String) -> String {
        "\(filename) is larger than 25 MB and wasn't attached."
    }

    // MARK: Staged attachments

    /// Empties the tray and deletes every staged copy.
    public func discardAttachments() {
        stagedAttachments.forEach { $0.deleteStagedCopy() }
        stagedAttachments = []
    }

    /// Removes one attachment from the tray (its ✕) and deletes its copy.
    public func removeAttachment(id: UUID) {
        guard let index = stagedAttachments.firstIndex(where: { $0.id == id }) else { return }
        stagedAttachments.remove(at: index).deleteStagedCopy()
    }

    // MARK: Item action buttons (contract 2026-09-24)

    /// The tap being enqueued right now. Held until the enqueue has
    /// returned AND the view model holds the store's own answer (the
    /// queued row, or the item the posted tap updated) — the streams
    /// report both a hop later, and clearing any earlier let the button
    /// flicker back to unselected and take a duplicate second tap
    /// (review, PR #242).
    private var enqueueingAction: String?
    /// Whether the outbox stream has shown the in-flight tap's row — only
    /// then does the row's later absence mean it left the outbox.
    private var sawEnqueuedRow = false

    /// The action buttons to draw: the item's actions while it is open,
    /// none once it is closed.
    public var offeredActions: [String] { item?.offeredActions ?? [] }

    /// Which offered action shows as chosen: a tap still on its way (in
    /// flight, then the newest queued one) outranks the journal's
    /// `chosen_action`, since it is the user's latest word. A label the
    /// item no longer offers never shows — the agent may have replaced the
    /// actions, and the journal will reject a tap on a withdrawn one.
    public var selectedAction: String? {
        let offered = offeredActions
        guard !offered.isEmpty else { return nil }
        // A queued tap on a comment's buttons is that comment's answer,
        // never the item's — even when both offer the same label.
        let queued = pendingComments.last(where: { $0.commentAction != nil && $0.commentReplyTo == nil })?.commentAction
        for candidate in [enqueueingAction, queued, item?.chosenAction] {
            if let candidate, offered.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Answers the item with one of its actions: exactly as if the user
    /// had typed the label as a reply (the journal hands the item back to
    /// the agent), plus `action` so the journal records which button it
    /// was. Goes through the same offline-safe outbox as a typed reply and
    /// leaves `draft` alone. Ignored for a label the item does not offer
    /// (closed, or replaced meanwhile), for the one already chosen or on
    /// its way, and while another write is in flight (`isBusy` — a tap
    /// racing a close would reopen the item).
    public func chooseAction(_ label: String) async {
        guard !isBusy, offeredActions.contains(label), label != selectedAction else { return }
        enqueueingAction = label
        sawEnqueuedRow = false
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: label, attachments: [], action: label, replyTo: nil)
        // Take the store's answer now rather than waiting on the streams:
        // the row still queued (offline) or the item the posted tap
        // updated. Only then does the in-flight marker give way.
        let rows = try? store.itemOutboxRows(itemID: itemID)
        if let rows { pendingComments = rows }
        let fresh = try? store.item(id: itemID)
        if let fresh {
            item = fresh
            subscribeConsentRows()
            refreshSpawnConsent()
        }
        // The marker outlives this read until the ITEM STREAM confirms the
        // choice: a snapshot the streams had already in flight (an empty
        // outbox, the item before the tap) can land after the read above,
        // and without the marker the button would drop to unselected and
        // take a duplicate tap (CodeRabbit, PR #242). Stream snapshots
        // arrive in order, so the first one that carries the choice is
        // newer than any stale one. Only a tap that landed nowhere — no
        // queued row, no recorded choice — clears it now.
        let queued = rows?.contains { $0.commentAction == label && $0.commentReplyTo == nil } ?? false
        if !queued, fresh?.chosenAction != label, enqueueingAction == label { enqueueingAction = nil }
    }

    /// Hands the in-flight tap over to the journal once the item stream
    /// reports it as the choice — or drops it when the item stops offering
    /// the label (the agent replaced the actions; the tap is re-sent as a
    /// typed reply).
    /// A queued tap leaves the outbox either posted — the item carrying
    /// the choice is written in the same transaction as the row's delete —
    /// or dropped as poison, which writes no item (Bugbot, PR #242). Once
    /// the stream has shown the row and then stops showing it, the store's
    /// item says which: confirmed, or gone, and the marker yields either way.
    private func settleEnqueueingAction(outbox rows: [ItemOutboxRecord]) {
        guard let pending = enqueueingAction else { return }
        if rows.contains(where: { $0.commentAction == pending && $0.commentReplyTo == nil }) { sawEnqueuedRow = true; return }
        guard sawEnqueuedRow else { return }
        if let fresh = try? store.item(id: itemID) { item = fresh }
        enqueueingAction = nil
        sawEnqueuedRow = false
    }

    private func settleEnqueueingAction(with fresh: TrackerItem?) {
        guard let pending = enqueueingAction else { return }
        if fresh?.chosenAction == pending || !(fresh?.offeredActions.contains(pending) ?? false) {
            enqueueingAction = nil
        }
    }

    // MARK: Comment action buttons (contract 2026-10-04)

    /// The taps on comments' buttons being enqueued right now, by asking
    /// comment id — `enqueueingAction`, one per question, held for the
    /// same reason and until the same kind of proof: the outbox row, or
    /// the asking comment carrying the choice.
    private var enqueueingCommentActions: [String: String] = [:]
    /// The asking comments whose in-flight tap the outbox stream has shown.
    private var sawEnqueuedCommentRows: Set<String> = []

    /// Which label shows as chosen under each comment that offers buttons,
    /// by comment id. As for the item's own buttons, a tap still on its way
    /// (in flight, then the newest queued one for that comment) outranks
    /// the journal's `chosen_action`, and a label the comment doesn't offer
    /// never shows. Empty once the item is closed: no buttons draw then.
    public var selectedCommentActions: [String: String] {
        guard let item, item.state == .open else { return [:] }
        var selected: [String: String] = [:]
        for comment in comments where !comment.actions.isEmpty {
            let queued = pendingComments.last(where: { $0.commentAction != nil && $0.commentReplyTo == comment.id })?.commentAction
            for candidate in [enqueueingCommentActions[comment.id], queued, comment.chosenAction] {
                if let candidate, comment.actions.contains(candidate) { selected[comment.id] = candidate; break }
            }
        }
        return selected
    }

    /// Answers a follow-up question with one of its comment's buttons:
    /// `chooseAction`, with `reply_to` naming the asking comment so the
    /// journal records the choice on that comment and leaves the item's
    /// own alone. Same outbox, same guards — ignored for a comment or a
    /// label the thread doesn't offer, for the one already chosen or on
    /// its way, on a closed item, and while another write is in flight.
    public func chooseCommentAction(commentID: String, label: String) async {
        guard !isBusy, let item, let asking = comments.first(where: { $0.id == commentID }),
              asking.offeredActions(itemIsOpen: item.state == .open).contains(label),
              label != selectedCommentActions[commentID] else { return }
        enqueueingCommentActions[commentID] = label
        sawEnqueuedCommentRows.remove(commentID)
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: label, attachments: [], action: label, replyTo: commentID)
        // The store's answer now, as in `chooseAction`: the row still
        // queued (offline), or the thread the posted tap updated — the
        // drain marks the asking comment in the transaction that removes
        // the row.
        let rows = try? store.itemOutboxRows(itemID: itemID)
        if let rows { pendingComments = rows }
        if let fresh = try? store.item(id: itemID) {
            self.item = fresh
            subscribeConsentRows()
            refreshSpawnConsent()
        }
        let thread = try? store.comments(itemID: itemID)
        if let thread { comments = thread }
        // Held until the COMMENTS STREAM confirms the choice, for the
        // reason `chooseAction` holds its own; only a tap that landed
        // nowhere — no queued row, no recorded choice — clears now.
        let queued = rows?.contains { $0.commentAction == label && $0.commentReplyTo == commentID } ?? false
        let recorded = thread?.first { $0.id == commentID }?.chosenAction == label
        if !queued, !recorded, enqueueingCommentActions[commentID] == label { clearEnqueueingCommentAction(commentID) }
    }

    private func clearEnqueueingCommentAction(_ commentID: String) {
        enqueueingCommentActions[commentID] = nil
        sawEnqueuedCommentRows.remove(commentID)
    }

    /// `settleEnqueueingAction(outbox:)` for the comment taps: once the
    /// stream has shown a tap's row and then stops showing it, the row was
    /// posted or dropped, and the store's thread says which.
    private func settleEnqueueingCommentActions(outbox rows: [ItemOutboxRecord]) {
        var left = false
        for (commentID, pending) in enqueueingCommentActions {
            if rows.contains(where: { $0.commentAction == pending && $0.commentReplyTo == commentID }) {
                sawEnqueuedCommentRows.insert(commentID)
            } else if sawEnqueuedCommentRows.contains(commentID) {
                clearEnqueueingCommentAction(commentID)
                left = true
            }
        }
        if left, let thread = try? store.comments(itemID: itemID) { comments = thread }
    }

    /// Hands an in-flight tap over to the journal once the comments stream
    /// reports it as the asking comment's choice — or drops it when that
    /// comment stops offering the label. A snapshot without the comment
    /// proves neither (a stale one can predate the thread), so it waits.
    private func settleEnqueueingCommentActions(with thread: [TrackerComment]) {
        for (commentID, pending) in enqueueingCommentActions {
            guard let asking = thread.first(where: { $0.id == commentID }) else { continue }
            if asking.chosenAction == pending || !asking.actions.contains(pending) { clearEnqueueingCommentAction(commentID) }
        }
    }

    /// Uploads and enqueues an attachment-only comment (body `""`) without
    /// ever reading or clearing `draft` or the tray. Only a voice note that
    /// couldn't be staged uses it (`sendUnstagedVoiceNote`): it goes out
    /// alone rather than not at all.
    func submitAttachments(_ attachments: [(data: Data, name: String, mime: String)]) async -> Bool {
        guard !attachments.isEmpty else { return true }
        busyCount += 1
        defer { busyCount -= 1 }
        var uploaded: [TrackerAttachment] = []
        do {
            for a in attachments {
                let ref = try await api.uploadMedia(a.data, contentType: a.mime)
                uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mime, name: a.name, size: Int64(a.data.count)))
            }
        } catch {
            self.error = "Couldn't upload an attachment: \(error.localizedDescription)"
            return false
        }
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: "", attachments: uploaded, action: nil, replyTo: nil)
        return true
    }

    /// What a voice note travels as, whatever the recorder named its file.
    static let voiceNoteFilename = "voice-note.m4a"
    static let voiceNoteMimeType = "audio/mp4"

    /// Moves a finished recording into the staging directory as a voice
    /// note. A seam so a test can make staging fail (a full disk).
    @ObservationIgnored
    var stageVoiceNote: (URL) throws -> StagedAttachment = { url in
        try StagedAttachment.stage(moving: url, filename: ItemDetailViewModel.voiceNoteFilename,
                                   mimeType: ItemDetailViewModel.voiceNoteMimeType)
    }

    /// Sends a recorded voice note together with whatever the reply holds,
    /// as `ComposerViewModel.sendVoiceNote` does in
    /// chat: ONE comment, the typed text as its body, the note as the
    /// first attachment and the tray after it, so the agent gets the text,
    /// the transcript and the attachments in one 📌 turn. With nothing
    /// typed or staged it is the voice-only comment it always was.
    ///
    /// The recording is staged (moved into the tray's directory) and sent
    /// through the send button's path, so the field and tray clear as the
    /// send starts and a failure restores them the same way, the note at
    /// the head of the tray: the whole reply is back as it was composed and
    /// Send re-sends it as one. The session's file has moved, so its
    /// failure row offers Dismiss, not a second Retry. When the item has
    /// closed meanwhile there is no tray to go back to: the note is moved
    /// back to the recorder's file and the row keeps Retry.
    ///
    /// An empty or unreadable recording is deleted (it will read the same
    /// way again). If staging fails the note goes out on its own straight
    /// from the recorder's file, leaving the draft and tray alone.
    ///
    /// Returns `nil` once queued, or the failure's message for
    /// `VoiceNoteSession`, which reports it app-wide (the note may have been
    /// recorded while this item was off screen). Reported there ONLY: `error`
    /// is left clear, as the chat path does, so the item's own alert doesn't
    /// repeat it — or outlive a Retry that went through.
    @discardableResult
    public func sendVoiceNote(url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return "Voice note was empty."
        }
        let staged: StagedAttachment
        do {
            staged = try stageVoiceNote(url)
        } catch {
            return await sendUnstagedVoiceNote(data, url: url)
        }
        guard let failure = await sendReply(leading: LeadingVoiceNote(attachment: staged, recording: url)) else {
            return nil
        }
        return isStopped ? failure : "\(failure) — it's back in the reply."
    }

    /// The note alone, from the recorder's own file, which is deleted once
    /// sent and kept for `VoiceNoteSession`'s Retry when the send fails.
    private func sendUnstagedVoiceNote(_ data: Data, url: URL) async -> String? {
        let ok = await submitAttachments([(data, Self.voiceNoteFilename, Self.voiceNoteMimeType)])
        if ok {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let message = error ?? "Couldn't send the voice note."
        error = nil
        return message
    }

    public func close(resolution: ItemResolution, comment: String?) async {
        await run { _ = try await self.api.closeItem(id: self.itemID, resolution: resolution, comment: comment) }
    }

    public func reopen() async {
        await run { _ = try await self.api.reopenItem(id: self.itemID, comment: nil) }
    }

    public func reverse() async { await close(resolution: .reversed, comment: nil) }

    private func run(_ op: @escaping () async throws -> Void) async {
        busyCount += 1
        defer { busyCount -= 1 }
        do { try await op(); await sync.refreshItem(id: itemID) }
        catch { self.error = error.localizedDescription }
    }
}

extension ItemDetailViewModel: AttachmentStaging {
    /// Stages each file into the reply's tray — the choke point every attach
    /// route (paperclip, photo picker, paste, drop) goes through, as
    /// `ComposerViewModel.attachFiles(_:)` is for chat. The caller keeps its
    /// file: ours is a copy, made off the main actor (a dropped video is not
    /// a main-thread read) and up front, because several routes hand over a
    /// URL that stops being readable once their callback returns. A file
    /// that can't be read, or is over `maxAttachmentBytes`, is reported and
    /// skipped; the rest are still staged.
    public func attachFiles(_ urls: [URL]) async {
        await stage(urls, moving: false)
    }

    /// Temporary files the app wrote itself (a paste, a picked photo, a
    /// file read out of its security scope): MOVED into the tray rather
    /// than copied, so each attachment exists once on disk instead of as a
    /// temp file plus a staged copy nobody deletes. A refused file is
    /// deleted too.
    public func attachTemporaryFiles(_ urls: [URL]) async {
        await stage(urls, moving: true)
        // The files have moved (or been refused and deleted): this clears
        // the per-item directories they waited in.
        for url in urls { PastedAttachment.removeStagingFile(url) }
    }

    public func reportAttachmentError(_ message: String) {
        error = message
    }

    private func stage(_ urls: [URL], moving: Bool) async {
        for url in urls {
            let staged = await Task.detached(priority: .userInitiated) { () -> Result<StagedAttachment, AttachmentStagingError> in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                if let size, size > Self.maxAttachmentBytes {
                    if moving { try? FileManager.default.removeItem(at: url) }
                    return .failure(AttachmentStagingError(message: Self.oversizeMessage(filename: url.lastPathComponent)))
                }
                do {
                    return .success(moving ? try StagedAttachment.stage(moving: url) : try StagedAttachment.stage(copying: url))
                } catch {
                    return .failure(AttachmentStagingError(message: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"))
                }
            }.value
            switch staged {
            case .success(let attachment):
                // The item closed while this was copying: nothing will
                // show or send it.
                if isStopped { attachment.deleteStagedCopy() } else { stagedAttachments.append(attachment) }
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}

/// Why a file didn't make it into the reply tray, worded for the tracker alert.
struct AttachmentStagingError: Error {
    let message: String
}
