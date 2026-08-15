import Foundation
import Network
import os
import MatronModels
import MatronSearch

public enum JournalSyncError: Error, Equatable, Sendable {
    case offline
    case authRevoked
}

/// Surfaced verbatim in UI banners via `localizedDescription` — without
/// this, an offline send rendered as "MatronJournal.JournalSyncError
/// error 0." (Dan's 2026-07-30 screenshot).
extension JournalSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offline: return "No connection to the server."
        case .authRevoked: return "This device was signed out by the server."
        }
    }
}

/// An agent's answer to `agentRequest` — either the method's result (raw
/// JSON bytes, caller decodes) or the bridge/server error code.
public enum RPCReply: Equatable, Sendable {
    case ok(resultData: Data)
    case failure(code: String, detail: String?)
}

public enum RPCRequestError: Error, Equatable, Sendable {
    /// No answer within the deadline. The relay is at-most-once and keeps no
    /// state, so the caller re-asks (for non-idempotent methods, only after
    /// the user acts again).
    case timeout
    /// No live journal connection to send on (or it died mid-request).
    case offline
}

extension RPCRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout: return "The agent didn't answer in time."
        case .offline: return "No connection to the server."
        }
    }
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
    /// `var`, not `let`, purely so `attachSearch(_:)` can fill it in later —
    /// see there. Only ever goes nil → non-nil.
    private var search: (any SearchService)?
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
    /// Trailing-edge debounce for path-change rebinds. A flapping network
    /// (Wi-Fi↔cellular handoff, train travel) fires the monitor in bursts;
    /// each burst used to close the socket and start a zero-delay
    /// TCP+TLS+upgrade handshake immediately. Waiting out the burst rebinds
    /// once, on the path that actually sticks.
    private var pathDebounceTask: Task<Void, Never>?
    /// When the last debounced rebind happened. A second path change inside
    /// `pathRebindCooldown` means the network is flapping — skip the forced
    /// close entirely and let the ping watchdog (or a failed write) surface
    /// a genuinely dead socket through the normal backoff path.
    private var lastPathRebind: ContinuousClock.Instant?
    private static let pathDebounce: Duration = .seconds(1)
    private static let pathRebindCooldown: Duration = .seconds(10)
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

    /// One in-flight agent RPC. The verbatim op is kept because `not_ready`
    /// means "nothing was forwarded — re-send the identical frame".
    private struct PendingRPC {
        let op: ClientOp
        let notReadyBackoff: Duration
        var resendsRemaining: Int
        let continuation: CheckedContinuation<RPCReply, Error>
    }
    private var rpcPending: [String: PendingRPC] = [:]

    /// Liveness-probe cadence. 60s (not the original 20s): a 20s ping is
    /// the worst case for cellular battery — the radio never reaches its
    /// idle state between wakes — and the server runs its own 20s ws-level
    /// heartbeat that terminates dead clients regardless. The client ping
    /// only exists so WE notice a black-holed socket; the path monitor
    /// covers the common cause (interface change) far faster than any ping.
    private let pingInterval: Duration
    /// When the last server frame arrived on the live socket. A frame is
    /// proof of liveness — the watchdog skips its ping (and the radio wake
    /// it costs) whenever one arrived within the last interval.
    private var lastFrameAt: ContinuousClock.Instant?

    public init(
        api: JournalAPI, store: JournalStore, connector: any WebSocketConnecting,
        token: String, ownSender: String, search: (any SearchService)?,
        backoffBaseSeconds: Double = 1.0, pingInterval: Duration = .seconds(60)
    ) {
        self.api = api
        self.store = store
        self.connector = connector
        self.token = token
        self.ownSender = ownSender
        self.search = search
        self.backoffBaseSeconds = backoffBaseSeconds
        self.pingInterval = pingInterval
    }

    /// Hands the engine a search index it was built without.
    ///
    /// On iOS the index is `NSFileProtectionComplete`, so it cannot be opened
    /// while the device is locked — and the app is launched locked, by push
    /// wake and background refresh. An engine built during one of those
    /// launches captured `nil` and stopped indexing for the entire life of the
    /// process, even though the index became available the moment the user
    /// unlocked. Since the engine outlives the session and nothing rebuilds
    /// it, the only way out is to attach the index once it opens.
    ///
    /// No-op once a search service is set: the index is a process-wide
    /// singleton, so a second attach would be the same object, and swapping
    /// one mid-flight would strand writes queued against the first.
    public func attachSearch(_ service: any SearchService) {
        guard search == nil else { return }
        search = service
    }

    /// Whether an index is currently attached. Lets the owner decide whether a
    /// core still needs `attachSearch(_:)` without tracking that separately.
    public var hasSearch: Bool { search != nil }

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
        pathDebounceTask?.cancel()
        pathDebounceTask = nil
        failReadyWaiters(JournalSyncError.offline)
        failAllRPC(RPCRequestError.offline)
        // Drop the status replay cache with the connection: values cached
        // here are only as fresh as the live stream, and a future
        // beginSync()'s `viewing` replay repopulates it.
        lastSessionStatus.removeAll()
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

    /// True when the socket is up AND caught up (`.running`). Read by the
    /// iOS background-refresh path to decide whether the post-catch-up
    /// settle sleep is owed at all.
    public var isConnectedAndCaughtUp: Bool {
        if case .running = state { return true }
        return false
    }

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
        // Debounce (trailing edge): rebind once the burst settles, not once
        // per callback. Each new change restarts the wait.
        pathDebounceTask?.cancel()
        pathDebounceTask = Task {
            try? await Task.sleep(for: Self.pathDebounce)
            guard !Task.isCancelled else { return }
            self.performPathRebind()
        }
    }

    private func performPathRebind() {
        guard liveConnection != nil else { return }
        let now = ContinuousClock.now
        if let last = lastPathRebind, now - last < Self.pathRebindCooldown {
            // Still flapping. Don't force another handshake — if the socket
            // really died with the old path, the watchdog ping or the next
            // write notices and the normal backoff paces the reconnects.
            return
        }
        lastPathRebind = now
        pathChangeReconnect = true
        liveConnection?.close()
    }

    // MARK: Public surface

    public func sendOp(_ op: ClientOp) async throws {
        guard let connection = liveConnection else { throw JournalSyncError.offline }
        try await connection.send(op)
        // A media send occupies a rejection-FIFO slot like any other
        // `op:"send"` — see `mediaSendsThisConnection`.
        if case let .sendMedia(_, _, blobRef, _, _, _, _, _, localID) = op {
            mediaSendsThisConnection[localID] = blobRef
            sendOrderThisConnection.append(localID)
        }
    }

    // MARK: Offline outbox

    /// Rows already written to the CURRENT socket. A row stays in the
    /// outbox until its journal frame confirms delivery, so without this
    /// set every extra flush pass on the same connection would resend it.
    /// Cleared on each new connection: the server's idem key (folded from
    /// `local_id`) dedups the once-per-connection resend of anything that
    /// actually landed but wasn't confirmed before the socket died.
    private var sentOnThisConnection: Set<String> = []
    /// FIFO of the same localIDs, in write order. A server rejection frame
    /// (`op:'error', ref:'send'`) names only the op, not the row — but the
    /// socket is processed in order on both ends, so the rejection belongs
    /// to the oldest write that hasn't been confirmed or failed yet.
    private var sendOrderThisConnection: [String] = []
    /// Media sends in flight on the current socket, `localID → blobRef`.
    /// `sendMedia` goes over the wire as `op:"send"` too, so a rejected
    /// media op consumes a FIFO slot exactly like a text send — without a
    /// slot of its own it would fail an innocent queued TEXT row instead
    /// ("media rejection misattributed", ported from matron-android #14).
    /// There is no durable outbox row for media, so a media slot absorbs
    /// its own rejection, and delivery retires it when the own-sender
    /// file/image journal frame echoes the blobRef back
    /// (`confirmMediaSend`) — a delivered media slot left in the FIFO
    /// would swallow the NEXT text rejection.
    private var mediaSendsThisConnection: [String: String] = [:]
    /// Single-flight latch for `flushOutbox()`.
    private var flushingOutbox = false
    /// Set when a flush is requested while one is running: the running
    /// flush re-drains before releasing the latch, so a row enqueued after
    /// the in-flight flush's last outbox read can't strand until the next
    /// reconnect (bugbot "Concurrent flush task dropped").
    private var flushRequestedWhileBusy = false

    /// Queue-and-flush text send — the offline-tolerant replacement for
    /// `sendOp(.send(...))`. The message is durably enqueued first (it
    /// survives relaunch and renders as a queued/sending echo via
    /// `JournalStore.outboxStream`), then flushed immediately when a
    /// connection is live. Never throws for being offline; only a store
    /// write failure (disk) escapes, so the composer can keep the text.
    public func sendMessage(convoID: String, body: String, localID: String) throws {
        try store.outboxInsert(localID: localID, convoID: convoID, body: body)
        if liveConnection != nil {
            Task { await self.flushOutbox() }
        }
    }

    /// Tap-to-retry for a failed (or stuck-queued) outbox row: requeues it,
    /// clears its sent-marker so it's eligible on this connection again,
    /// and kicks a flush — or, when offline, cancels any backoff sleep so
    /// the reconnect (and its connect-flush) happens now.
    public func retryOutboxItem(localID: String) {
        try? store.outboxRequeue(localID: localID)
        sentOnThisConnection.remove(localID)
        if liveConnection != nil {
            Task { await self.flushOutbox() }
        } else {
            nudge()
        }
    }

    /// Removes an unsent message the user chose to discard.
    public func discardOutboxItem(localID: String) {
        try? store.outboxDelete(localID: localID)
        sentOnThisConnection.remove(localID)
    }

    /// A post-hello `{op:'error', ref:'send'}` frame: the server REJECTED a
    /// send op (validation), so retrying it unchanged can never succeed —
    /// flip the row to `.failed` (surfacing "Not delivered — tap to retry")
    /// instead of leaving it silently re-flushing on every reconnect
    /// forever (bugbot "Send rejections never mark rows failed"). The frame
    /// carries no row id; FIFO ordering picks the victim (see
    /// `sendOrderThisConnection`). Exactly ONE slot is consumed per error
    /// frame, dispatched on what the slot actually is:
    ///   - a media slot absorbs the rejection (no durable row to fail);
    ///   - a deleted row means that write was already confirmed — its slot
    ///     is stale, skip to the next;
    ///   - an already-failed row means this is the rejection of a
    ///     DUPLICATE write of the same row (a same-connection retry puts
    ///     two writes in flight, one FIFO slot each) — absorb it, or it
    ///     would fall through and fail the next innocent in-flight send;
    ///   - a queued row is the victim: mark it failed.
    private func handleSendRejected(code: String, detail: String?) {
        while !sendOrderThisConnection.isEmpty {
            let localID = sendOrderThisConnection.removeFirst()
            if mediaSendsThisConnection.removeValue(forKey: localID) != nil {
                Self.logger.warning("server rejected media send \(localID, privacy: .public): \(code, privacy: .public) \(detail ?? "", privacy: .public)")
                return
            }
            guard let row = (try? store.outboxRow(localID: localID)) ?? nil else {
                continue // confirmed-deleted (or discarded): this write succeeded
            }
            if row.state == .failed {
                Self.logger.warning("server rejected duplicate write of failed send \(localID, privacy: .public): \(code, privacy: .public)")
                return
            }
            Self.logger.warning("server rejected send \(localID, privacy: .public): \(code, privacy: .public) \(detail ?? "", privacy: .public)")
            try? store.outboxMarkFailed(localID: localID, error: detail ?? code)
            sentOnThisConnection.remove(localID)
            return
        }
    }

    /// The own-sender file/image journal frame carrying `blobRef` landed:
    /// that media send was delivered, so retire its rejection-FIFO slot.
    /// In-order socket delivery makes this sound — a confirmation for a
    /// media send can only arrive after every rejection that precedes it.
    private func confirmMediaSend(blobRef: String) {
        guard let localID = sendOrderThisConnection.first(where: { mediaSendsThisConnection[$0] == blobRef })
        else { return }
        if let index = sendOrderThisConnection.firstIndex(of: localID) {
            sendOrderThisConnection.remove(at: index)
        }
        mediaSendsThisConnection.removeValue(forKey: localID)
    }

    /// Whether any queued sends are still awaiting delivery confirmation.
    /// The iOS host polls this from its background-task grace window so a
    /// send-then-pocket flush can finish before the process suspends.
    public var hasPendingOutbox: Bool {
        !((try? store.outboxPending())?.isEmpty ?? true)
    }

    /// Sends every queued outbox row not yet written to the current
    /// connection, oldest first. Stops on the first transport failure —
    /// the rows stay queued and the next connection's flush retries them.
    /// `outboxMarkAttempt` runs BEFORE the write: delivery-confirmation
    /// deletes only attempted rows, and marking after a successful write
    /// would race the journal frame (a frame applied before the mark
    /// would skip the delete, and the dedup'd resend gets no fresh frame,
    /// so the row would never clear).
    private func flushOutbox() async {
        guard !flushingOutbox else {
            // A flush is mid-flight and may already have taken its last
            // outbox read; flag it to re-drain so the row that prompted
            // this call can't be skipped until the next reconnect.
            flushRequestedWhileBusy = true
            return
        }
        flushingOutbox = true
        defer { flushingOutbox = false }
        repeat {
            flushRequestedWhileBusy = false
            await drainOutbox()
        } while flushRequestedWhileBusy
    }

    /// One drain pass: sends every eligible queued row FIFO, stopping on
    /// the first transport failure (rows stay queued for the next
    /// connection's flush).
    private func drainOutbox() async {
        while let connection = liveConnection {
            let rows = (try? store.outboxPending()) ?? []
            guard let next = rows.first(where: { !sentOnThisConnection.contains($0.localID) }) else {
                return
            }
            do {
                try store.outboxMarkAttempt(localID: next.localID)
            } catch {
                // A send whose attempt mark didn't persist can never be
                // confirmed (delivery-delete and echo suppression both
                // require attempts > 0) — sending it anyway would leave a
                // permanent ghost "queued" echo beside the delivered
                // message. Stop the drain; the row stays queued for a
                // flush whose mark does persist.
                Self.logger.warning("outbox flush stopped — markAttempt write failed for \(next.localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            do {
                try await connection.send(.send(convoID: next.convoID, body: next.body,
                                                localID: next.localID))
                sentOnThisConnection.insert(next.localID)
                sendOrderThisConnection.append(next.localID)
            } catch {
                Self.logger.warning("outbox flush stopped — socket write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    public func setViewing(convoID: String?) async {
        viewingConvoID = convoID
        try? await liveConnection?.send(.viewing(convoID: convoID))
    }

    /// Sends a structured request to one of the user's agent devices and
    /// awaits the correlated answer (protocol.md §Agent RPC). At-most-once:
    /// on `.timeout` nothing is retried here — re-asking is the caller's
    /// decision. `not_ready` (we raced our own hello replay) is retried
    /// internally with the identical frame, which the server documents as
    /// always safe.
    public func agentRequest(
        agentDeviceID: Int64, method: String, paramsData: Data,
        timeout: Duration = .seconds(15),
        notReadyBackoff: Duration = .seconds(1)
    ) async throws -> RPCReply {
        guard let connection = liveConnection else { throw RPCRequestError.offline }
        let requestID = UUID().uuidString
        let op = ClientOp.agentRequest(requestID: requestID, agentDeviceID: agentDeviceID,
                                       method: method, paramsData: paramsData)
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expireRPC(requestID: requestID)
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            rpcPending[requestID] = PendingRPC(op: op, notReadyBackoff: notReadyBackoff,
                                               resendsRemaining: 2, continuation: continuation)
            Task { [weak self] in
                do { try await connection.send(op) }
                catch { await self?.dropRPC(requestID: requestID, error: RPCRequestError.offline) }
            }
        }
    }

    /// Inserts a placeholder conversation row for a convo id learned
    /// out-of-band (a `start` RPC answer that beat the convo's first journal
    /// frame). Routed through the engine so the store keeps a single
    /// writer; an existing row is never touched.
    public func ensurePlaceholderConversation(id: String, title: String) {
        try? store.ensureConversation(id: id, title: title)
    }

    // MARK: RPC correlator internals

    /// Every resume path funnels through a removal-first take, so a
    /// duplicate response (multicast), a response racing the timeout, or a
    /// timeout racing teardown can never double-resume a continuation.
    private func takeRPC(_ requestID: String) -> PendingRPC? {
        rpcPending.removeValue(forKey: requestID)
    }

    private func resumeRPC(_ response: RPCResponse) {
        guard let pending = takeRPC(response.requestID) else { return } // duplicate or expired
        if response.ok {
            pending.continuation.resume(returning: .ok(resultData: response.resultData ?? Data("null".utf8)))
        } else {
            pending.continuation.resume(returning: .failure(
                code: response.errorCode ?? "unknown", detail: response.errorDetail))
        }
    }

    private func failRPC(requestID: String, code: String, detail: String?) {
        // not_ready = our own hello replay hasn't finished; nothing was
        // forwarded, so the identical frame re-sends safely after a beat.
        if code == "not_ready", var pending = rpcPending[requestID], pending.resendsRemaining > 0 {
            pending.resendsRemaining -= 1
            let op = pending.op
            let backoff = pending.notReadyBackoff
            rpcPending[requestID] = pending
            Task { [weak self] in
                try? await Task.sleep(for: backoff)
                await self?.resendRPC(requestID: requestID, op: op)
            }
            return
        }
        guard let pending = takeRPC(requestID) else { return }
        pending.continuation.resume(returning: .failure(code: code, detail: detail))
    }

    private func resendRPC(requestID: String, op: ClientOp) {
        guard rpcPending[requestID] != nil else { return } // timed out meanwhile
        guard let connection = liveConnection else {
            dropRPC(requestID: requestID, error: RPCRequestError.offline)
            return
        }
        Task { [weak self] in
            do { try await connection.send(op) }
            catch { await self?.dropRPC(requestID: requestID, error: RPCRequestError.offline) }
        }
    }

    private func expireRPC(requestID: String) {
        dropRPC(requestID: requestID, error: RPCRequestError.timeout)
    }

    private func dropRPC(requestID: String, error: Error) {
        guard let pending = takeRPC(requestID) else { return }
        pending.continuation.resume(throwing: error)
    }

    /// Connection teardown: every in-flight RPC fails now — the relay keeps
    /// no state, so an answer can never arrive on the next socket.
    private func failAllRPC(_ error: Error) {
        let pending = rpcPending
        rpcPending.removeAll()
        for (_, entry) in pending { entry.continuation.resume(throwing: error) }
    }

    public func refreshSummaries() async {
        let epoch = storeEpoch
        guard let snapshot = try? await api.snapshot() else { return }
        guard epoch == storeEpoch else { return } // store wiped mid-flight; stale
        try? store.refreshSummaries(snapshot.conversations)
        try? store.replaceAgents(snapshot.agents)
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
            // Catch-up replay buffer: while `.catchingUp`, frames accumulate
            // here and land via `applyJournalBatch` — one transaction + one
            // observation fire per batch instead of per frame (see that
            // method's doc for why per-frame was slow). Declared outside the
            // `do` so every teardown path (stream end, thrown error) can
            // flush it: the buffered frames are real journal rows, and a
            // link that dies early in every replay would otherwise re-buffer
            // the same head-of-backlog forever without ever advancing the
            // cursor (livelock).
            var replayBuffer: [JournalEvent] = []
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
                // Fresh socket: everything unconfirmed is eligible to resend
                // once (idem-dedup'd server-side), including messages queued
                // while offline. Kicked as a child task so the frame loop
                // below starts consuming immediately.
                sentOnThisConnection.removeAll()
                sendOrderThisConnection.removeAll()
                mediaSendsThisConnection.removeAll()
                Task { await self.flushOutbox() }
                // Socket is up: either we're already caught up, or the
                // server is about to replay the backlog. The latter is
                // "loading history", not "connecting" — the distinction
                // matters after a long offline stretch, where the replay
                // can take visible seconds and a "Connecting…" banner
                // reads as a connection that never completes.
                setState(store.cursor >= headSeq ? .running : .catchingUp)

                lastFrameAt = ContinuousClock.now
                let watchdog = Task {
                    var misses = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pingInterval)
                        if Task.isCancelled { return }
                        // A frame within the last interval already proves
                        // the socket is alive — don't wake the radio just
                        // to hear a pong we effectively already have.
                        if let last = lastFrameAt, ContinuousClock.now - last < pingInterval {
                            misses = 0
                            continue
                        }
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
                // Batches flush by size OR elapsed time, so a slow link
                // still renders progressively instead of stalling on a
                // half-full buffer.
                var lastReplayFlush = ContinuousClock.now
                frameLoop: for try await frame in connection.frames() {
                    lastFrameAt = ContinuousClock.now
                    switch frame {
                    case .journal(let event):
                        // Backlog frame mid-catch-up: buffer it. The
                        // publish-new-conversation path below is gated on
                        // `.running` anyway, so batching these frames skips
                        // no behavior — only the per-frame commit.
                        if case .catchingUp = state, event.seq < headSeq {
                            replayBuffer.append(event)
                            if replayBuffer.count < Self.replayBatchSize,
                               ContinuousClock.now - lastReplayFlush < Self.replayFlushInterval {
                                continue
                            }
                            appliedSinceAck += try await applyReplayBatch(replayBuffer, connection: connection)
                            replayBuffer.removeAll(keepingCapacity: true)
                            lastReplayFlush = ContinuousClock.now
                            if appliedSinceAck >= 50 {
                                try? await connection.send(.ack(cursor: store.cursor))
                                appliedSinceAck = 0
                            }
                            continue
                        }
                        // First frame at/past headSeq (or a state change)
                        // while frames are still buffered: flush the buffer
                        // together with this frame, then promote to
                        // `.running` — the same boundary the single-frame
                        // path hits below.
                        if !replayBuffer.isEmpty {
                            replayBuffer.append(event)
                            appliedSinceAck += try await applyReplayBatch(replayBuffer, connection: connection)
                            replayBuffer.removeAll(keepingCapacity: true)
                            lastReplayFlush = ContinuousClock.now
                            if appliedSinceAck >= 50 {
                                try? await connection.send(.ack(cursor: store.cursor))
                                appliedSinceAck = 0
                            }
                            if store.cursor >= headSeq { setState(.running) }
                            continue
                        }
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
                        // Note: delivery-confirmed outbox deletion happens
                        // INSIDE applyJournal's transaction (atomic with the
                        // row insert) — see JournalStore.applyJournal.
                        if try store.applyJournal(event) {
                            didApply(event)
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
                            // Subagent children are silent (spec §6): they
                            // must never yank the user into a sub-chat via
                            // auto-open. Two guards, because the parent
                            // linkage is learned ONLY from the child's
                            // convo_meta and that frame can be applied AFTER
                            // a routed text/tool/status frame for the same
                            // child (the ordering hole that shipped the bug —
                            // the row then exists with parent_convo_id still
                            // NULL and the Mac yanked selection into the
                            // just-started sub-chat):
                            //   1. structural — a child convo id is always
                            //      `<parent>:sub:<agentId>` (the bridge's
                            //      CHILD_CONVO_INFIX). This holds no matter
                            //      which of the child's frames arrives first,
                            //      so it closes the race by construction.
                            //   2. semantic — the learned parent linkage,
                            //      kept as the forward-compatible filter.
                            if isNewConvo, case .running = state,
                               !event.convoID.contains(JournalEventType.childConvoInfix),
                               (try? store.parentConvoID(of: event.convoID)) == nil {
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
                        // Pre-wipe frames must never land post-wipe: drop the
                        // buffer BEFORE the wipe so the teardown flush below
                        // can't replay them onto the emptied store. (The
                        // server sends snapshot_required instead of a replay,
                        // so the buffer should already be empty — belt and
                        // braces.)
                        replayBuffer.removeAll()
                        refreshSummariesTask?.cancel()
                        storeEpoch += 1
                        // The status replay cache mirrors journal state; a
                        // wiped mirror must not replay pre-wipe meters to
                        // post-wipe subscribers.
                        lastSessionStatus.removeAll()
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
                                limits: update.limits ?? held.limits,
                                email: update.email ?? held.email,
                                taskRef: update.taskRef ?? held.taskRef,
                                workdir: update.workdir ?? held.workdir,
                                vitals: update.vitals ?? held.vitals
                            )
                        } else {
                            lastSessionStatus[update.convoID] = update
                        }
                        for (_, entry) in sessionStatusContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .rpcResponse(let response):
                        resumeRPC(response)
                    case .error(let code, let ref, let requestID, let detail):
                        // Correlated RPC errors resume their waiter; a
                        // rejected send op fails its outbox row; other
                        // post-hello control frames are advisory.
                        if let requestID {
                            failRPC(requestID: requestID, code: code, detail: detail)
                        } else if ref == "send" {
                            handleSendRejected(code: code, detail: detail)
                        }
                    case .deviceMeta(let id, let name):
                        // A device was renamed elsewhere — patch the local
                        // roster so open chat lists relabel their chips
                        // without waiting for the next snapshot.
                        try? store.renameAgent(id: id, name: name)
                    case .helloOK, .unknownControl:
                        break // post-hello control frames are advisory
                    }
                }
                // Stream ended (server closed the socket): land whatever the
                // replay buffered before the cut. The next connect's hello
                // acks the advanced cursor, so the server resumes past it.
                flushReplayBufferOnTeardown(&replayBuffer)
            } catch JournalConnectionError.authRejected {
                flushReplayBufferOnTeardown(&replayBuffer)
                Self.logger.warning("server rejected auth — stopping sync (signed out by server)")
                liveConnection = nil
                setState(.offline(reason: "Signed out by server"))
                failReadyWaiters(JournalSyncError.authRevoked)
                failAllRPC(RPCRequestError.offline)
                runTask = nil
                return
            } catch {
                flushReplayBufferOnTeardown(&replayBuffer)
                // Fall through to backoff — but never silently: the
                // 2026-07-13 phone incident sat in this loop for 90
                // minutes (proxy refusing the ws upgrade) with nothing in
                // the persisted log. Backoff paces this to at most ~1
                // line/min at steady state.
                Self.logger.warning("connect/stream failed (attempt \(self.attempt + 1, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            liveConnection?.close()
            liveConnection = nil
            // The relay is stateless — an in-flight request's answer cannot
            // arrive on the next socket, so fail the waiters now rather
            // than leaving them to their timeouts.
            failAllRPC(RPCRequestError.offline)
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
        try store.replaceAgents(snapshot.agents)
        // A cold bootstrap means the replay gap (if any) was unbridgeable —
        // events between the search index's last look at each conversation
        // and the snapshot head were never live-indexed, so any persisted
        // "backfill complete" flags may now hide head-side holes. Reset the
        // bookkeeping (messages stay indexed) so the backfill sweep re-walks
        // every conversation from its head. Best-effort: a failed reset just
        // leaves search coverage where it was.
        if let search { try? await search.resetBackfill() }
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

    /// Max frames per catch-up batch. Big enough that a multi-thousand-frame
    /// backlog costs tens of commits instead of thousands; small enough that
    /// each observation re-fire (full chat-list + open-timeline re-query)
    /// stays a visible-progress heartbeat rather than one monolithic pause.
    private static let replayBatchSize = 250
    /// Max time a buffered frame waits before being flushed — on a slow link
    /// the batch fills slowly, and without this bound the UI would sit on
    /// "Loading messages…" showing nothing until 250 frames trickled in.
    private static let replayFlushInterval: Duration = .milliseconds(200)

    /// Applies a buffered catch-up batch in one store transaction, then runs
    /// the per-event side effects for the frames that actually wrote.
    /// Returns the applied count (duplicates excluded — they must not count
    /// toward the ack batch, same as the single-frame path).
    ///
    /// On a thrown batch (all-or-nothing, fully rolled back) this salvages
    /// the prefix one-by-one via `applyJournal`, preserving the single-frame
    /// path's exactly-once shape: everything before the failing seq lands
    /// and is acked-able, the cursor stops right before the failure, and the
    /// throw still escapes to the reconnect path.
    private func applyReplayBatch(_ batch: [JournalEvent], connection: JournalConnection) async throws -> Int64 {
        var applied: [JournalEvent]
        do {
            applied = try store.applyJournalBatch(batch)
        } catch {
            applied = []
            do {
                for event in batch {
                    if try store.applyJournal(event) { applied.append(event) }
                }
            } catch let salvageError {
                didApplyBatch(applied)
                try? await connection.send(.ack(cursor: store.cursor))
                throw salvageError
            }
            // Whole batch salvaged one-by-one (the batch throw was
            // transient): fall through to the normal side-effect pass.
        }
        didApplyBatch(applied)
        return Int64(applied.count)
    }

    /// Teardown-path flush (stream end, thrown error): best-effort batch
    /// apply with no salvage and no ack — the connection is gone or going,
    /// and the next connect's hello acks whatever cursor this landed. A
    /// failed apply here just leaves the cursor where it was; the reconnect
    /// replays the same frames.
    private func flushReplayBufferOnTeardown(_ buffer: inout [JournalEvent]) {
        guard !buffer.isEmpty else { return }
        if let applied = try? store.applyJournalBatch(buffer) {
            didApplyBatch(applied)
        }
        buffer.removeAll()
    }

    /// Side effects owed to every frame that actually wrote (apply returned
    /// `true`). Kept out of the duplicate path on purpose: a REPLAYED frame
    /// (seq <= cursor, apply no-ops) must not retire a live media-send slot
    /// whose blobRef collides with the replayed one (bugbot "Media confirm
    /// ignores duplicate guard").
    private func didApply(_ event: JournalEvent) {
        confirmMediaSendIfNeeded(event)
        indexForSearch(event)
    }

    /// Batch form of `didApply` for the replay paths: media confirms run
    /// per-event as before, but search indexing collapses into a single
    /// `indexBatch` call — one write transaction and one Task for the whole
    /// batch instead of one of each per frame.
    private func didApplyBatch(_ events: [JournalEvent]) {
        guard !events.isEmpty else { return }
        for event in events { confirmMediaSendIfNeeded(event) }
        guard let search else { return }
        let entries = events.compactMap { event -> SearchIndexEntry? in
            guard let body = event.searchableBody else { return nil }
            return SearchIndexEntry(roomID: event.convoID, eventID: String(event.seq),
                                    sender: event.sender, timestamp: event.ts, body: body)
        }
        guard !entries.isEmpty else { return }
        Task { try? await search.indexBatch(entries) }
    }

    /// A delivered media send retires its rejection-FIFO slot the moment
    /// its own-sender file/image frame echoes the blobRef back — see
    /// confirmMediaSend.
    private func confirmMediaSendIfNeeded(_ event: JournalEvent) {
        if event.sender == ownSender,
           event.type == JournalEventType.file || event.type == JournalEventType.image,
           let blobRef = event.payload["blob_ref"] as? String {
            confirmMediaSend(blobRef: blobRef)
        }
    }

    private func indexForSearch(_ event: JournalEvent) {
        guard let search else { return }
        // Body extraction lives in `JournalEvent.searchableBody` (shared with
        // paginateBackward and the history backfill) so the three feeders
        // can't drift — see SearchBackfill.swift.
        guard let body = event.searchableBody else { return }
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
