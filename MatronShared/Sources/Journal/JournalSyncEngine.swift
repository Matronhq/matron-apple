import Foundation
import Network
import os
import MatronModels
import MatronSearch

public enum JournalSyncError: Error, Equatable, Sendable {
    case offline
    case authRevoked
}

/// The single writer of the JournalStore and owner of the reconnect loop.
/// Any failure converges to "reconnect and resume from the store cursor" —
/// there is no other recovery path, so there is nothing to wedge.
///
/// Lifecycle methods are named `beginSync()` / `endSync()` (not
/// `start()` / `stop()`) so a later `SyncService` conformance shim can add
/// protocol-named wrappers without colliding with these concrete methods.
public actor JournalSyncEngine {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-sync")
    private let api: JournalAPI
    private let store: JournalStore
    private let connector: any WebSocketConnecting
    private let token: String
    private let ownSender: String
    private let search: (any SearchService)?
    private let backoffBaseSeconds: Double

    private var runTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Status + sorted interface names of the last observed network path.
    /// macOS fires a burst of path callbacks at app startup (interface
    /// enumeration, VPN utuns coming up) that all describe the same usable
    /// path; comparing signatures lets us ignore those instead of tearing
    /// down a healthy connection per callback.
    private var lastPathSignature: String?
    /// Set when the engine itself closes the socket because the network
    /// path changed. The run loop then goes straight back to `.connecting`
    /// (no `.offline` blip in the UI, no backoff sleep) — the network is
    /// there, we're just rebinding to it.
    private var pathChangeReconnect = false
    private var liveConnection: JournalConnection?
    private var viewingConvoID: String?
    private var backoffSleeper: Task<Void, Never>?
    private var attempt = 0
    private var refreshSummariesTask: Task<Void, Never>?
    /// Bumped on every store wipe; in-flight refreshSummaries results from
    /// before the wipe are discarded (pull-to-refresh racing snapshot_required).
    private var storeEpoch = 0

    private var state: SyncConnectionState = .connecting
    private var stateContinuations: [UUID: AsyncStream<SyncConnectionState>.Continuation] = [:]
    private var ephemeralContinuations: [UUID: (convoID: String, continuation: AsyncStream<EphemeralUpdate>.Continuation)] = [:]
    private var activityContinuations: [UUID: (convoID: String, continuation: AsyncStream<ActivityUpdate>.Continuation)] = [:]
    private var toolStreamContinuations: [UUID: (convoID: String, continuation: AsyncStream<ToolStreamUpdate>.Continuation)] = [:]
    private var sessionStatusContinuations: [UUID: (convoID: String, continuation: AsyncStream<SessionStatusUpdate>.Continuation)] = [:]
    /// Merged session-status per convo, so a subscriber that registers
    /// after a frame already arrived (e.g. `viewing` replay landed in the
    /// gap before `sessionStatus(convoID:)`'s registration task ran) still
    /// gets a populated header immediately instead of waiting for the next
    /// turn-end frame. Frames use absent-means-unchanged semantics, so the
    /// cache merges each incoming frame over the held one (a part replaces
    /// only when present) rather than storing the last frame verbatim —
    /// a partial frame must not erase parts an earlier frame carried.
    private var lastSessionStatus: [String: SessionStatusUpdate] = [:]
    private var newConvoContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    public init(
        api: JournalAPI, store: JournalStore, connector: any WebSocketConnecting,
        token: String, ownSender: String, search: (any SearchService)?,
        backoffBaseSeconds: Double = 1.0
    ) {
        self.api = api
        self.store = store
        self.connector = connector
        self.token = token
        self.ownSender = ownSender
        self.search = search
        self.backoffBaseSeconds = backoffBaseSeconds
    }

    // MARK: Lifecycle

    public func beginSync() {
        guard runTask == nil else { return }
        attempt = 0
        runTask = Task { await runLoop() }
        startPathMonitor()
    }

    public func endSync() async {
        runTask?.cancel()
        runTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        pathChangeReconnect = false
        failReadyWaiters(JournalSyncError.offline)
        liveConnection?.close()
        liveConnection = nil
        backoffSleeper?.cancel()
        refreshSummariesTask?.cancel()
        refreshSummariesTask = nil
        // Don't clobber a terminal offline reason (e.g. auth revocation) that
        // was already set before endSync() was called.
        if case .offline = state {} else {
            setState(.offline(reason: nil))
        }
    }

    public var isRunning: Bool { runTask != nil }

    public func waitUntilReady() async throws {
        if case .running = state { return }
        guard runTask != nil else { throw JournalSyncError.offline }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    public func nudge() {
        backoffSleeper?.cancel()
    }

    /// Reconnect promptly when the network path changes instead of waiting
    /// on the 2×20s ping watchdog. A socket that survived sleep/wake or a
    /// Wi-Fi↔Ethernet hop is bound to the old path and almost always dead
    /// but doesn't error until written to — the classic "Mac wakes up,
    /// chat list sits stale" failure. Closing it (with `pathChangeReconnect`
    /// set) routes the run loop straight back to `.connecting`, skipping
    /// the offline banner and the backoff sleep.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))"
            Task { await self?.handlePathUpdate(satisfied: satisfied, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "chat.matron.journal.path-monitor"))
        pathMonitor = monitor
    }

    private func handlePathUpdate(satisfied: Bool, signature: String) {
        let previous = lastPathSignature
        lastPathSignature = signature
        // First callback reports the current path (not a change), and
        // repeated callbacks with an identical signature are noise —
        // reacting to either would tear down a healthy connection.
        guard let previous, signature != previous else { return }
        guard satisfied else { return } // loss surfaces via the run loop itself
        guard liveConnection != nil else {
            nudge() // mid-backoff: retry now on the fresh path
            return
        }
        pathChangeReconnect = true
        liveConnection?.close()
    }

    // MARK: Public surface

    public func sendOp(_ op: ClientOp) async throws {
        guard let connection = liveConnection else { throw JournalSyncError.offline }
        try await connection.send(op)
    }

    public func setViewing(convoID: String?) async {
        viewingConvoID = convoID
        try? await liveConnection?.send(.viewing(convoID: convoID))
    }

    public func refreshSummaries() async {
        let epoch = storeEpoch
        guard let snapshot = try? await api.snapshot() else { return }
        guard epoch == storeEpoch else { return } // store wiped mid-flight; stale
        try? store.refreshSummaries(snapshot.conversations)
    }

    public nonisolated func stateStream() -> AsyncStream<SyncConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerState(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterState(id: id) }
            }
        }
    }

    public nonisolated func ephemerals(convoID: String) -> AsyncStream<EphemeralUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerEphemeral(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterEphemeral(id: id) }
            }
        }
    }

    /// Per-conversation stream of activity indicators (typing / tool-use).
    /// Mirrors `ephemerals(convoID:)` — the timeline subscribes while it's
    /// the viewed conversation and renders a trailing indicator row until
    /// an `.idle` update (or staleness) clears it.
    public nonisolated func activities(convoID: String) -> AsyncStream<ActivityUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerActivity(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterActivity(id: id) }
            }
        }
    }

    /// Per-conversation stream of live tool-output frames (`tool_stream`
    /// ephemerals). Mirrors `activities(convoID:)`; all offset bookkeeping
    /// lives in the subscriber (JournalTimelineService.OverlayState).
    public nonisolated func toolStreams(convoID: String) -> AsyncStream<ToolStreamUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerToolStream(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterToolStream(id: id) }
            }
        }
    }

    /// Emits the id of a conversation created live — one whose first-ever
    /// frame arrives while we're connected and caught up (`.running`), e.g.
    /// the chat the bridge spins up in response to `/start`. Hosts subscribe
    /// to auto-open it so the user doesn't have to hunt for it in the list.
    /// A reconnect backlog does NOT replay through here: only convos born
    /// after the client reached `.running` fire, so resuming after a long
    /// offline stretch can't yank the user through a pile of old sessions.
    public nonisolated func newConversations() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerNewConvo(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterNewConvo(id: id) }
            }
        }
    }

    /// Per-conversation stream of session-status updates (journal `status`
    /// ephemerals). Mirrors `activities(convoID:)`. The journal replays the
    /// last cached status when the client sends `viewing`, and the engine
    /// itself also caches the latest frame per convo and replays it on
    /// subscribe (`registerSessionStatus`), so a subscriber that attaches on
    /// convo-open gets a populated header immediately regardless of whether
    /// the `viewing` replay lands before or after registration.
    public nonisolated func sessionStatus(convoID: String) -> AsyncStream<SessionStatusUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerSessionStatus(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterSessionStatus(id: id) }
            }
        }
    }

    // MARK: Registry plumbing

    private func registerState(id: UUID, continuation: AsyncStream<SyncConnectionState>.Continuation) {
        stateContinuations[id] = continuation
        continuation.yield(state)
    }

    private func unregisterState(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func registerEphemeral(id: UUID, convoID: String, continuation: AsyncStream<EphemeralUpdate>.Continuation) {
        ephemeralContinuations[id] = (convoID, continuation)
    }

    private func unregisterEphemeral(id: UUID) {
        ephemeralContinuations.removeValue(forKey: id)
    }

    private func registerActivity(id: UUID, convoID: String, continuation: AsyncStream<ActivityUpdate>.Continuation) {
        activityContinuations[id] = (convoID, continuation)
    }

    private func unregisterActivity(id: UUID) {
        activityContinuations.removeValue(forKey: id)
    }

    private func registerToolStream(id: UUID, convoID: String, continuation: AsyncStream<ToolStreamUpdate>.Continuation) {
        toolStreamContinuations[id] = (convoID, continuation)
    }

    private func unregisterToolStream(id: UUID) {
        toolStreamContinuations.removeValue(forKey: id)
    }

    private func registerSessionStatus(id: UUID, convoID: String, continuation: AsyncStream<SessionStatusUpdate>.Continuation) {
        sessionStatusContinuations[id] = (convoID, continuation)
        if let cached = lastSessionStatus[convoID] {
            continuation.yield(cached)
        }
    }

    private func unregisterSessionStatus(id: UUID) {
        sessionStatusContinuations.removeValue(forKey: id)
    }

    private func registerNewConvo(id: UUID, continuation: AsyncStream<String>.Continuation) {
        newConvoContinuations[id] = continuation
    }

    private func unregisterNewConvo(id: UUID) {
        newConvoContinuations.removeValue(forKey: id)
    }

    private func publishNewConversation(_ convoID: String) {
        for continuation in newConvoContinuations.values { continuation.yield(convoID) }
    }

    private func setState(_ new: SyncConnectionState) {
        guard new != state else { return }
        state = new
        for continuation in stateContinuations.values { continuation.yield(new) }
        if case .running = new {
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
    }

    private func failReadyWaiters(_ error: Error) {
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters = []
    }

    // MARK: Run loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                setState(.connecting)
                try await coldStartIfNeeded()
                let cursor = store.cursor
                let (connection, headSeq) = try await JournalConnection.establish(
                    connector: connector, wsURL: api.wsURL, token: token, cursor: cursor)
                liveConnection = connection
                attempt = 0
                if let viewingConvoID {
                    try? await connection.send(.viewing(convoID: viewingConvoID))
                }
                // Ack cursor progress on every connect: a dead socket can't
                // take a final flush, so the only place to guarantee the
                // server's stored device cursor isn't stale by more than one
                // reconnect's worth of frames is right after establishing
                // the next one.
                if store.cursor > 0 {
                    try? await connection.send(.ack(cursor: store.cursor))
                }
                refreshSummariesTask?.cancel()
                refreshSummariesTask = Task { await self.refreshSummaries() } // title/state stopgap (spec §7 ask 4)
                if store.cursor >= headSeq { setState(.running) }

                let watchdog = Task {
                    var misses = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        if Task.isCancelled { return }
                        do {
                            try await connection.ping()
                            misses = 0
                        } catch {
                            misses += 1
                            if misses >= 2 { connection.close(); return }
                        }
                    }
                }
                defer { watchdog.cancel() }

                var appliedSinceAck: Int64 = 0
                frameLoop: for try await frame in connection.frames() {
                    switch frame {
                    case .journal(let event):
                        // Propagate a throw (disk full, sqlite I/O error) rather than
                        // swallowing it: the cursor is only advanced inside the same
                        // transaction as a successful write (JournalStore.applyJournal),
                        // so on failure it's untouched, and letting the error escape
                        // this loop routes to the catch below → close → backoff →
                        // reconnect from that unchanged cursor. Swallowing it here
                        // instead would leave the loop discarding frames on a live
                        // socket forever (silent wedge in .connecting), and — worse —
                        // if a later frame then applied successfully, the cursor would
                        // jump past the failed seq and the server would never resend
                        // it (it only replays above the acked cursor).
                        //
                        // `false` (duplicate, seq <= cursor) is a legitimate no-op:
                        // it must not count toward the ack batch.
                        // Whether this convo had no row before this frame —
                        // read before applyJournal creates one. Only the
                        // first-ever frame of a convo sees `false`, so this
                        // is true exactly once per new conversation.
                        let isNewConvo = (try? store.conversationExists(event.convoID)) == false
                        if try store.applyJournal(event) {
                            indexForSearch(event)
                            appliedSinceAck += 1
                            if appliedSinceAck >= 50 {
                                try? await connection.send(.ack(cursor: store.cursor))
                                appliedSinceAck = 0
                            }
                            // Surface a conversation the bridge just created
                            // while we're live (e.g. the user sent /start).
                            // Gated on `.running`: during the initial
                            // catch-up burst state is still `.connecting`, so
                            // a reconnect that replays new-since-offline convos
                            // won't auto-navigate — only ones born while the
                            // user is actively connected do.
                            if isNewConvo, case .running = state {
                                publishNewConversation(event.convoID)
                            }
                        }
                        if store.cursor >= headSeq { setState(.running) }
                    case .ephemeral(let update):
                        for (_, entry) in ephemeralContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .activity(let update):
                        for (_, entry) in activityContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .snapshotRequired:
                        // Gap too large to replay (server valve). Cancel any
                        // in-flight refreshSummaries() first — its response
                        // is stale relative to the wipe and, if it lands
                        // after we clear the store, would repopulate it with
                        // pre-wipe data and defeat coldStartIfNeeded()'s
                        // empty-store check on the next connect. Then wipe
                        // the mirror.
                        Self.logger.warning("snapshot_required: replay gap too large — wiping local mirror (cursor \(self.store.cursor, privacy: .public))")
                        refreshSummariesTask?.cancel()
                        storeEpoch += 1
                        // A failed wipe leaves stale rows in place; the server will
                        // simply re-issue snapshot_required on the next connect
                        // (bounded by the reconnect backoff), so this isn't silently lost.
                        try? store.wipe()
                        // Force the reconnect deterministically rather than relying on
                        // the server closing the socket right after this frame: if it
                        // ever kept the connection open, later journal frames would
                        // apply onto the freshly-wiped store (seq > cursor 0) and skip
                        // coldStartIfNeeded() on this same connection, diverging the
                        // mirror. Breaking here always falls through to the same
                        // close/backoff/reconnect path used for every other exit from
                        // this loop, and the next iteration's coldStartIfNeeded() picks
                        // up from /snapshot regardless of what the server does with
                        // the socket.
                        break frameLoop
                    case .toolStream(let update):
                        for (_, entry) in toolStreamContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .sessionStatus(let update):
                        if let held = lastSessionStatus[update.convoID] {
                            lastSessionStatus[update.convoID] = SessionStatusUpdate(
                                convoID: update.convoID,
                                model: update.model ?? held.model,
                                context: update.context ?? held.context,
                                limits: update.limits ?? held.limits
                            )
                        } else {
                            lastSessionStatus[update.convoID] = update
                        }
                        for (_, entry) in sessionStatusContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .error, .helloOK, .unknownControl:
                        break // post-hello control frames are advisory
                    }
                }
            } catch JournalConnectionError.authRejected {
                Self.logger.warning("server rejected auth — stopping sync (signed out by server)")
                liveConnection = nil
                setState(.offline(reason: "Signed out by server"))
                failReadyWaiters(JournalSyncError.authRevoked)
                runTask = nil
                return
            } catch {
                // Fall through to backoff — but never silently: the
                // 2026-07-13 phone incident sat in this loop for 90
                // minutes (proxy refusing the ws upgrade) with nothing in
                // the persisted log. Backoff paces this to at most ~1
                // line/min at steady state.
                Self.logger.warning("connect/stream failed (attempt \(self.attempt + 1, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            liveConnection?.close()
            liveConnection = nil
            if Task.isCancelled { return }
            if pathChangeReconnect {
                // Engine-initiated rebind after a network-path change: the
                // network is usable (the monitor said so), so reconnect
                // immediately and stay in `.connecting` — flashing the red
                // offline banner for a deliberate sub-second reconnect
                // reads as the app being broken. If the reconnect then
                // genuinely fails, the next loop iteration lands in the
                // normal offline/backoff path (the flag is already cleared).
                pathChangeReconnect = false
                setState(.connecting)
                continue
            }
            setState(.offline(reason: nil))
            await backoff()
        }
    }

    private func coldStartIfNeeded() async throws {
        guard store.cursor == 0, (try? store.conversations().isEmpty) != false else { return }
        let snapshot = try await api.snapshot()
        try store.applyColdSnapshot(snapshot.conversations, headSeq: snapshot.seq)
    }

    private func backoff() async {
        attempt += 1
        let capped = min(backoffBaseSeconds * pow(2, Double(attempt - 1)), 60)
        let jittered = capped * Double.random(in: 0.8...1.2)
        let sleeper = Task { _ = try? await Task.sleep(for: .seconds(jittered)) }
        backoffSleeper = sleeper
        await sleeper.value // nudge() cancels this → immediate retry
        backoffSleeper = nil
    }

    private func indexForSearch(_ event: JournalEvent) {
        guard let search else { return }
        let payload = event.payload
        let body: String?
        switch event.type {
        case JournalEventType.text:
            body = payload["body"] as? String
        case JournalEventType.toolOutput:
            body = payload["snippet"] as? String
        case JournalEventType.diff:
            // Mirror JournalTimelineMapper's precedence (diff, then
            // snippet) so what the user can SEE is what search can FIND —
            // diff rows carrying only a `diff` field were invisible to FTS
            // (bugbot "Diff events omit search text").
            body = payload["diff"] as? String ?? payload["snippet"] as? String
        default:
            body = nil
        }
        guard let body, !body.isEmpty else { return }
        let convoID = event.convoID
        let seq = event.seq
        let sender = event.sender
        let ts = event.ts
        Task {
            try? await search.index(roomID: convoID, eventID: String(seq),
                                    sender: sender, timestamp: ts, body: body)
        }
    }
}
