import Foundation
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
    private let api: JournalAPI
    private let store: JournalStore
    private let connector: any WebSocketConnecting
    private let token: String
    private let ownSender: String
    private let search: (any SearchService)?
    private let backoffBaseSeconds: Double

    private var runTask: Task<Void, Never>?
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
    }

    public func endSync() async {
        runTask?.cancel()
        runTask = nil
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
                        if try store.applyJournal(event) {
                            indexForSearch(event)
                            appliedSinceAck += 1
                            if appliedSinceAck >= 50 {
                                try? await connection.send(.ack(cursor: store.cursor))
                                appliedSinceAck = 0
                            }
                        }
                        if store.cursor >= headSeq { setState(.running) }
                    case .ephemeral(let update):
                        for (_, entry) in ephemeralContinuations where entry.convoID == update.convoID {
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
                    case .error, .helloOK, .unknownControl:
                        break // post-hello control frames are advisory
                    }
                }
            } catch JournalConnectionError.authRejected {
                liveConnection = nil
                setState(.offline(reason: "Signed out by server"))
                failReadyWaiters(JournalSyncError.authRevoked)
                runTask = nil
                return
            } catch {
                // fall through to backoff
            }
            liveConnection?.close()
            liveConnection = nil
            if Task.isCancelled { return }
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
        case JournalEventType.toolOutput, JournalEventType.diff:
            body = payload["snippet"] as? String
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
