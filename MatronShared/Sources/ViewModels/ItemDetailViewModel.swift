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
    public private(set) var item: TrackerItem?
    public private(set) var comments: [TrackerComment] = []
    public private(set) var pendingComments: [ItemOutboxRecord] = []
    public var draft = ""
    public var error: String?
    public private(set) var isBusy = false
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
    /// The spawn consent ask this item mirrors (item #2318) — `nil` unless
    /// the item carries a `matron://consent/spawn/<id>` link. Re-derived
    /// from the store whenever the item or its thread updates: the journal
    /// closes the item right after appending the ask's `spawn_outcome`, so
    /// the item update is what brings the resolved state in.
    public private(set) var spawnConsent: ItemSpawnConsent?

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    /// The origin conversation's consent rows — the card's own payload and
    /// its outcome. Optional so existing call sites construct unchanged; a
    /// view model without it still answers, it just cannot draw the card.
    private let events: (any ConsentEventsReading)?
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
                events: (any ConsentEventsReading)? = nil, agentSpawn: (any AgentSpawnAnswering)? = nil) {
        self.itemID = itemID; self.store = store; self.api = api; self.sync = sync
        self.events = events; self.agentSpawn = agentSpawn
    }

    public func start() {
        stop()
        let id = itemID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemStream(id: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.item = v; self.refreshSpawnConsent() }
        })
        subscribeComments()
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemOutboxStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.pendingComments = v }
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

    public func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        commentsTask?.cancel(); commentsTask = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    private func subscribeComments() {
        commentsTask?.cancel()
        let id = itemID
        commentsTask = Task { [weak self] in
            guard let s = self?.store.commentsStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.comments = v; self.refreshSpawnConsent() }
        }
    }

    // MARK: Spawn consent (item #2318)

    /// Rebuilds `spawnConsent` from the item and the origin conversation's
    /// consent rows. The card's facts come from the ask's own
    /// `permission_request` payload (never reconstructed from the item's
    /// markdown: what the user approves must be the card's words or
    /// nothing); the resolved state from its `spawn_outcome`, the last one
    /// for the request id winning should there ever be two.
    private func refreshSpawnConsent() {
        guard let item, let requestID = item.spawnConsentRequestID else { spawnConsent = nil; return }
        var request: AgentSpawnRequest?
        var outcome: SpawnOutcome?
        if let events, let rows = try? events.consentEvents(convoID: item.originConvoID) {
            for row in rows {
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
        }
        spawnConsent = ItemSpawnConsent(
            requestID: requestID, request: request,
            state: Self.spawnState(requestID: requestID, outcome: outcome, itemIsOpen: item.state == .open,
                                   transient: spawnTransient, canAnswer: agentSpawn != nil))
    }

    /// Where the ask is, in order of authority:
    ///
    /// 1. A `spawn_outcome` row for the request — the server's durable word,
    ///    outranking everything (answered on another device, expired by the
    ///    sweep: history here too).
    /// 2. A closed item with no local outcome — the row stopped awaiting an
    ///    answer (the journal closes the item on every terminal outcome, and
    ///    the thread's closing note says how); rendered as "no longer
    ///    waiting", the same sentence a 409 earns. Above the transient so a
    ///    `.sending` from this device cannot spin on after the item settled
    ///    without its outcome row having synced.
    /// 3. The in-flight transient.
    /// 4. Answerable when an answerer is wired; otherwise read-only, the
    ///    timeline card's own convention.
    static func spawnState(requestID: String, outcome: SpawnOutcome?, itemIsOpen: Bool,
                           transient: AgentSpawnCardState?, canAnswer: Bool) -> AgentSpawnCardState {
        if let outcome { return .resolved(outcome) }
        if !itemIsOpen { return .resolved(.expired(requestID: requestID)) }
        if let transient { return transient }
        return canAnswer ? .idle : .resolved(.expired(requestID: requestID))
    }

    /// Answers the spawn ask — `POST /agent-spawn/answer`, the one path that
    /// resolves it, exactly as the timeline card answers it. Records nothing
    /// on success: the card settles when the journal's outcome lands (and
    /// closes the item), which is also what makes the resolution honest —
    /// approving is not "approved and done" until the child has started. A
    /// 409 (answered elsewhere, or expired) settles the card as no longer
    /// waiting; any other error settles into the card and leaves it
    /// answerable again; cancellation just drops the in-flight state.
    public func answerSpawn(approve: Bool) async {
        guard let agentSpawn, let consent = spawnConsent else { return }
        switch consent.state {
        case .resolved, .sending: return
        case .idle, .failed: break
        }
        spawnTransient = .sending
        refreshSpawnConsent()
        do {
            try await agentSpawn.answerAgentSpawn(requestID: consent.requestID, decision: approve ? .approve : .deny)
            await sync.refreshItem(id: itemID)
        } catch is CancellationError {
            spawnTransient = nil
        } catch JournalAPIError.conflict {
            spawnTransient = .resolved(.expired(requestID: consent.requestID))
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
    public var availableResolutions: [ItemResolution] {
        Self.resolutions(for: item?.kind,
                         userHasReplied: !pendingComments.isEmpty || comments.contains { $0.author == .user && $0.kind == .comment })
    }

    static func resolutions(for kind: ItemKind?, userHasReplied: Bool) -> [ItemResolution] {
        switch kind {
        case .task: return [.done, .cancelled]
        case .question: return userHasReplied ? [.answered, .cancelled] : [.cancelled]
        case .decision: return [.reversed, .decided, .cancelled]
        case nil: return []
        }
    }

    /// Uploads attachments first, then enqueues the comment (localID is
    /// minted here, not by `ItemsSyncing` — the outbox record needs it
    /// before the enqueue call returns so the pending-comments stream can
    /// show it). Draft is cleared on enqueue, not restored on failure: the
    /// outbox holds the text durably and retries on its own.
    public func submitComment(attachments: [(data: Data, name: String, mime: String)]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var uploaded: [TrackerAttachment] = []
        do {
            for a in attachments {
                let ref = try await api.uploadMedia(a.data, contentType: a.mime)
                uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mime, name: a.name, size: Int64(a.data.count)))
            }
        } catch {
            self.error = "Couldn't upload an attachment: \(error.localizedDescription)"
            return
        }
        draft = ""
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: text, attachments: uploaded)
    }

    /// "Attach a file/photo" — distinct from `submitComment(attachments:)`
    /// (fix wave, item B): both hosts were calling `submitComment` for a
    /// bare attachment action too, which posted whatever half-written text
    /// happened to be sitting in `draft` as that attachment's comment body
    /// and cleared it out from under the person still composing a reply.
    /// This uploads and enqueues an attachment-only comment (body `""`)
    /// without ever reading or clearing `draft`. `sendVoiceNote` is one
    /// such caller — a voice note is always an attachment-only comment.
    public func submitAttachments(_ attachments: [(data: Data, name: String, mime: String)]) async -> Bool {
        guard !attachments.isEmpty else { return true }
        isBusy = true
        defer { isBusy = false }
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
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: "", attachments: uploaded)
        return true
    }

    /// Deletes the recording file only once `submitAttachments` reports
    /// the upload actually succeeded (fix wave, item F) — the previous
    /// `defer`-based cleanup ran unconditionally, so an upload failure
    /// both showed an error AND destroyed the only copy of the recording,
    /// leaving nothing to retry. The empty/unreadable-recording early
    /// return (fix wave, item I4) also cleans up: unlike an upload
    /// failure there's nothing here worth retrying — an empty or
    /// unreadable file will read the same way again — so leaving it
    /// behind only orphans a temp file forever.
    public func sendVoiceNote(url: URL) async {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            error = "Voice note was empty."
            try? FileManager.default.removeItem(at: url)
            return
        }
        let ok = await submitAttachments([(data, "voice-note.m4a", "audio/mp4")])
        if ok { try? FileManager.default.removeItem(at: url) }
    }

    public func close(resolution: ItemResolution, comment: String?) async {
        await run { _ = try await self.api.closeItem(id: self.itemID, resolution: resolution, comment: comment) }
    }

    public func reopen() async {
        await run { _ = try await self.api.reopenItem(id: self.itemID, comment: nil) }
    }

    public func reverse() async { await close(resolution: .reversed, comment: nil) }

    private func run(_ op: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await op(); await sync.refreshItem(id: itemID) }
        catch { self.error = error.localizedDescription }
    }
}
