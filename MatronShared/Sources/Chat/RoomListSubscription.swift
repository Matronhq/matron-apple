import Foundation
import MatrixRustSDK
import MatronModels
import os

// MARK: - RoomLike test seam

/// Minimal abstraction over `MatrixRustSDK.Room` covering only the fields
/// `RoomListSubscription` reads when applying diffs. Tests inject a tiny
/// struct fake; production wires `MatrixRustSDK.Room` through an extension.
///
/// Why this exists: `MatrixRustSDK.Room` is `open class @unchecked Sendable`,
/// not directly fakeable in unit tests, and the diff-application unit suite
/// (Phase 2.5 Task 5 Step 1) needs to assert ordered-list semantics for
/// every `RoomListEntriesUpdate` variant without spinning up a real
/// homeserver. Keeping the abstraction this thin means production-side
/// behaviour drift would only ever affect summary recomputation, not list
/// ordering — and ordering is what the diff tests assert.
protocol RoomLike: AnyObject, Sendable {
    /// Stable, server-issued room ID. Used as the cache key for
    /// `ChatSummary` and as the equality key when diffs replace one row.
    func id() -> String
}

extension MatrixRustSDK.Room: RoomLike {}

// MARK: - Diff representation

/// SDK-agnostic mirror of `RoomListEntriesUpdate`, parameterised over
/// `RoomLike` so the diff-application algorithm can be exercised by
/// unit tests with a fake `Room`. The SDK listener converts each batch
/// of `RoomListEntriesUpdate` into `[RoomEntryDiff<MatrixRustSDK.Room>]`
/// before handing it to `RoomListEntriesAlgorithm.apply`.
enum RoomEntryDiff<R: RoomLike> {
    case append([R])
    case clear
    case pushFront(R)
    case pushBack(R)
    case popFront
    case popBack
    case insert(index: Int, value: R)
    case set(index: Int, value: R)
    case remove(index: Int)
    case truncate(length: Int)
    case reset([R])
}

extension RoomEntryDiff where R == MatrixRustSDK.Room {
    /// Lifts the SDK's `RoomListEntriesUpdate` into our generic mirror.
    /// Indices are widened from `UInt32` to `Int`; values are pass-through.
    static func from(_ update: RoomListEntriesUpdate) -> RoomEntryDiff<MatrixRustSDK.Room> {
        switch update {
        case .append(let values):    return .append(values)
        case .clear:                 return .clear
        case .pushFront(let value):  return .pushFront(value)
        case .pushBack(let value):   return .pushBack(value)
        case .popFront:              return .popFront
        case .popBack:               return .popBack
        case .insert(let i, let v):  return .insert(index: Int(i), value: v)
        case .set(let i, let v):     return .set(index: Int(i), value: v)
        case .remove(let i):         return .remove(index: Int(i))
        case .truncate(let n):       return .truncate(length: Int(n))
        case .reset(let values):     return .reset(values)
        }
    }
}

// MARK: - Diff application algorithm (pure, generic, testable)

/// Pure ordered-list mutation. Mirrors Element X's reference impl: walk
/// each diff in batch order, mutate the vec, return the touched index
/// set so the caller can recompute summaries only for changed rows.
///
/// `resetAll` is set when a structural diff (`pushFront`, `popFront`,
/// `insert`, `reset`) shifts every index; the caller widens the touched
/// set to `0..<rooms.count`. Tests don't care about the touched set —
/// they assert on the resulting `[String]` of room IDs.
enum RoomListEntriesAlgorithm {

    struct ApplyResult {
        var touched: Set<Int>
        var resetAll: Bool
        /// IDs removed by this batch — caller drops cached summaries.
        var dropped: [String]
    }

    static func apply<R: RoomLike>(
        _ batch: [RoomEntryDiff<R>],
        to rooms: inout [R]
    ) -> ApplyResult {
        var touched: Set<Int> = []
        var resetAll = false
        var dropped: [String] = []

        for diff in batch {
            switch diff {
            case .append(let values):
                let start = rooms.count
                rooms.append(contentsOf: values)
                for i in start..<rooms.count { touched.insert(i) }

            case .pushBack(let value):
                rooms.append(value)
                touched.insert(rooms.count - 1)

            case .pushFront(let value):
                rooms.insert(value, at: 0)
                resetAll = true

            case .popBack:
                if let last = rooms.popLast() {
                    dropped.append(last.id())
                }

            case .popFront:
                if !rooms.isEmpty {
                    let removed = rooms.removeFirst()
                    dropped.append(removed.id())
                    resetAll = true
                }

            case .insert(let index, let value):
                guard index >= 0, index <= rooms.count else { continue }
                rooms.insert(value, at: index)
                resetAll = true

            case .remove(let index):
                guard index >= 0, index < rooms.count else { continue }
                let removed = rooms.remove(at: index)
                dropped.append(removed.id())
                // Cached summaries for rows AFTER `index` are keyed by
                // ID, so they remain valid; only their position changed.

            case .set(let index, let value):
                guard index >= 0, index < rooms.count else { continue }
                let oldID = rooms[index].id()
                rooms[index] = value
                if oldID != value.id() { dropped.append(oldID) }
                touched.insert(index)

            case .truncate(let length):
                guard length < rooms.count else { continue }
                let dropping = rooms[length...]
                for room in dropping { dropped.append(room.id()) }
                rooms.removeLast(rooms.count - length)

            case .clear:
                for room in rooms { dropped.append(room.id()) }
                rooms.removeAll()

            case .reset(let values):
                for room in rooms { dropped.append(room.id()) }
                rooms = values
                resetAll = true
            }
        }

        if resetAll {
            for i in rooms.indices { touched.insert(i) }
        }

        return ApplyResult(touched: touched, resetAll: resetAll, dropped: dropped)
    }
}

// MARK: - Production subscription wiring

/// Owns one `entriesWithDynamicAdapters` subscription against the SDK's
/// `RoomList` and translates the resulting diff stream into a
/// continuously-evolving `[ChatSummary]` snapshot. The snapshot is
/// delivered via `onSnapshot`; the consumer-facing surface is
/// `ChatSummaryBroadcaster` (Task 2 Step 2), which fans out to multiple
/// `chatSummaries()` callers.
///
/// **Phase 2.5 Task 3 — per-room subscriptions:** for each room in the
/// listener window we attach `Room.subscribeToRoomInfoUpdates(...)` (the
/// plan calls this `subscribeToUpdates`; the actual SDK surface in
/// matrix-rust-components-swift 26.4.1 is the `RoomInfo`-typed variant).
/// The per-room callback enqueues a `.roomInfoChanged(roomID:)` event
/// onto the same serial channel that already processes diff batches, so
/// summary recomputation stays single-consumer and snapshot mutation is
/// race-free without an explicit lock. Handles are tracked in
/// `perRoomHandles` and torn down on Remove / Set-with-id-change /
/// Reset / Clear / Truncate (i.e. for every ID returned in
/// `RoomListEntriesAlgorithm.ApplyResult.dropped`).
///
/// **Step 0 spike outcome:** the scaling probe at
/// `MatronIntegrationTests/RoomListSubscriptionSpikeTests` exercises
/// 10×`subscribeToRoomInfoUpdates` over 30s and asserts the callback
/// rate stays ≤ 5N. NOT RUN in this session — the harness wasn't booted.
/// Future sessions can run it via
/// `tests/integration/run-harness.sh roomlist-spike-sdk.sh`. Proceeding
/// optimistically at page-100; if we ever observe per-room churn that
/// dwarfs user-driven mutation in production, scope this to a sliding
/// top-N window per the plan.
///
/// **Phase 2.5 Task 3 Step 0 — scaling spike outcome:** the test
/// `RoomListSubscriptionSpikeTests.testRoomSubscribeToRoomInfoUpdates_scalesAtPage100`
/// exercises 10×`subscribeToRoomInfoUpdates` over 30s and asserts the
/// callback rate stays ≤ 5N. NOT RUN in this session — the integration
/// harness wasn't booted. Future sessions can run it via
/// `tests/integration/run-harness.sh roomlist-spike-sdk.sh` (the
/// existing scenario script picks up both spike test methods). Step 1
/// (per-room wiring) proceeds optimistically at page-100; if the spike
/// later surfaces churn that dwarfs user-driven mutation, scope the
/// listener window to a sliding top-N (~20) per the plan.
///
/// **History note (do not delete without re-confirming):** Phase 1's
/// `ChatServiceLive.chatSummaries()` blamed a crash inside the SDK's
/// `VectorDiff::map / BaseStateStore` pipeline when this API was called
/// against tuwunel. The Phase 2.5 Task 1 spike (commit `393faa1`,
/// 2026-05-05) verified that against `matrix-rust-components-swift
/// 26.4.1` + tuwunel the listener fires `.reset` immediately on
/// subscribe and `.pushBack`/`.set` for subsequent mutations, with no
/// crash. The construction-throw fallback in `ChatServiceLive` exists
/// for future SDK or homeserver regressions only.
final class RoomListSubscription: @unchecked Sendable {

    /// Default page size for the `entriesWithDynamicAdapters` window.
    /// Matches the Phase 2.5 spike (`393faa1`). Task 3 evaluates whether
    /// `Room.subscribeToUpdates()` is feasible at this scale; if not, a
    /// follow-up may shrink the window to the top ~20 rooms.
    static let defaultPageSize: UInt32 = 100

    /// Snapshot delivery callback. Invoked from the internal serial
    /// batch-processing Task; the broadcaster is itself an actor so it
    /// re-serialises across consumer threads.
    typealias SnapshotHandler = @Sendable ([ChatSummary]) -> Void

    private let client: Client
    private let onSnapshot: SnapshotHandler
    private let logger: Logger

    /// Strong reference keeps the SDK-side subscription alive. Dropping
    /// this cancels the listener (the type is a thin controller).
    private var adapters: RoomListEntriesWithDynamicAdaptersResult?

    /// Strong listener ref: the SDK weakly retains via the FFI handle map,
    /// so we must hold the listener for the subscription's lifetime.
    private var listener: BatchListener?

    /// Unified event type processed by the single-consumer batch task.
    /// The list-level listener yields `.batch(...)`; per-room listeners
    /// yield `.roomInfoChanged(...)`. Funnelling both onto the same
    /// channel keeps `rooms`/`summaries`/`perRoomHandles` mutation
    /// single-threaded without an explicit lock.
    private enum SubscriptionEvent {
        case batch([RoomListEntriesUpdate])
        case roomInfoChanged(roomID: String)
    }

    /// Serial queue for both list-level batches and per-room state
    /// changes. The listeners fire from arbitrary SDK threads; we hop
    /// into a single-consumer Task that pulls events off this stream and
    /// applies them in order.
    private var batchTask: Task<Void, Never>?
    private let eventContinuation: AsyncStream<SubscriptionEvent>.Continuation

    /// Mirrors the SDK's ordered list of rooms. We hold `Room` references
    /// (not just IDs) so we can re-derive `ChatSummary` for touched rows
    /// without re-walking the room list service.
    private var rooms: [MatrixRustSDK.Room] = []

    /// Cached `ChatSummary` per room ID. Recomputed only for rows touched
    /// by the current diff batch, dropped for rows the batch removed.
    private var summaries: [String: ChatSummary] = [:]

    /// Per-room `subscribeToRoomInfoUpdates` handles, keyed by room ID.
    /// Mutated only from the serial event task. Cancelled-and-removed
    /// for every ID surfaced in `ApplyResult.dropped`; attached for
    /// every new room first observed in `touched` that isn't already
    /// tracked.
    private var perRoomHandles: [String: TaskHandle] = [:]

    /// Bridges the SDK's callback protocol to a `@Sendable` closure,
    /// mirroring the `StateObserver` pattern at `SyncServiceLive.swift:117`.
    private final class BatchListener: RoomListEntriesListener, @unchecked Sendable {
        private let onBatch: @Sendable ([RoomListEntriesUpdate]) -> Void
        init(onBatch: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) {
            self.onBatch = onBatch
        }
        func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
            onBatch(roomEntriesUpdate)
        }
    }

    /// Bridges `RoomInfoListener` (one per subscribed room) into a
    /// `@Sendable` closure that yields onto the unified event stream.
    /// We don't read `RoomInfo` itself — the production summary mapper
    /// pulls fresh `displayName()` / `latestEvent()` off the `Room`
    /// reference each time, so the callback only needs to signal "this
    /// room changed".
    private final class RoomInfoBridge: RoomInfoListener, @unchecked Sendable {
        private let roomID: String
        private let onChange: @Sendable (String) -> Void
        init(roomID: String, onChange: @escaping @Sendable (String) -> Void) {
            self.roomID = roomID
            self.onChange = onChange
        }
        func call(roomInfo: RoomInfo) {
            onChange(roomID)
        }
    }

    /// Constructs the subscription and immediately attaches the listener.
    /// Caller is responsible for `do/catch` around `roomList.entriesWith...`
    /// throws — in v26 the call itself is non-throwing, but the upstream
    /// `roomListService.allRooms()` is, which is where the construction-
    /// throw fallback in `ChatServiceLive` actually fires.
    init(
        client: Client,
        roomList: RoomList,
        pageSize: UInt32 = RoomListSubscription.defaultPageSize,
        logger: Logger,
        onSnapshot: @escaping SnapshotHandler
    ) {
        self.client = client
        self.logger = logger
        self.onSnapshot = onSnapshot

        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        self.eventContinuation = continuation

        let listener = BatchListener { batch in
            // `continuation` is `Sendable`; yielding from arbitrary SDK
            // threads is the documented contract for AsyncStream.
            continuation.yield(.batch(batch))
        }
        self.listener = listener

        let result = roomList.entriesWithDynamicAdapters(pageSize: pageSize, listener: listener)
        // Without a filter, the dynamic-adapters window is empty and the
        // listener never fires. `.all(filters: [])` matches the SDK
        // Walkthrough example and the spike — "all rooms, no extra
        // filtering" is what the chat list wants.
        _ = result.controller().setFilter(kind: .all(filters: []))
        self.adapters = result

        self.batchTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .batch(let batch):
                    await self.handle(batch)
                case .roomInfoChanged(let roomID):
                    await self.handleRoomInfoChange(roomID: roomID)
                }
            }
        }
    }

    deinit {
        eventContinuation.finish()
        batchTask?.cancel()
        // Cancel every per-room handle. Safe to touch from `deinit` —
        // the serial batch task has been signalled to exit and `self`
        // is being deallocated, so no other code path can be racing.
        for (_, handle) in perRoomHandles { handle.cancel() }
        // Releasing `adapters` cancels the SDK-side subscription. The
        // listener strong-ref drops with `self`.
    }

    /// Handles a single batch from the list-level listener: apply diffs
    /// to the ordered list, recompute summaries for touched rows, drop
    /// dead summaries and per-room handles, attach per-room handles for
    /// newly-tracked rooms, broadcast the resulting snapshot once.
    private func handle(_ batch: [RoomListEntriesUpdate]) async {
        let mirrored = batch.map(RoomEntryDiff<MatrixRustSDK.Room>.from)
        let result = RoomListEntriesAlgorithm.apply(mirrored, to: &rooms)

        // Drop summaries + per-room handles for every removed ID. Order
        // matters: cancel BEFORE forgetting the handle so an in-flight
        // RoomInfo callback can't slip past the cancel and try to
        // recompute a summary for a vanished room.
        for id in result.dropped {
            summaries.removeValue(forKey: id)
            if let handle = perRoomHandles.removeValue(forKey: id) {
                handle.cancel()
            }
        }

        if !result.touched.isEmpty {
            let myID = (try? client.userId()) ?? ""
            for i in result.touched {
                guard i < rooms.count else { continue }
                let room = rooms[i]
                summaries[room.id()] = await ChatSummaryMapper.summary(for: room, myID: myID)
            }
        }

        // Attach a per-room subscription for every room currently in
        // the window that we aren't already tracking. Idempotent —
        // existing handles are kept, so a structural diff (`pushFront`,
        // `insert`) that widens `touched` to every index doesn't cause
        // a churn of cancel-and-re-attach.
        for room in rooms {
            let id = room.id()
            if perRoomHandles[id] != nil { continue }
            let continuation = eventContinuation
            let bridge = RoomInfoBridge(roomID: id) { changedID in
                continuation.yield(.roomInfoChanged(roomID: changedID))
            }
            perRoomHandles[id] = room.subscribeToRoomInfoUpdates(listener: bridge)
        }

        broadcastSnapshot()
    }

    /// Handles a single per-room state change: re-derive the summary
    /// for that one room and broadcast the full snapshot. Skipped if
    /// the room is no longer in the window (race: the room-info
    /// callback fired in flight while a `.remove` / `.reset` was being
    /// applied; the handle cancel will prevent further fires).
    private func handleRoomInfoChange(roomID: String) async {
        guard let room = rooms.first(where: { $0.id() == roomID }) else { return }
        let myID = (try? client.userId()) ?? ""
        summaries[roomID] = await ChatSummaryMapper.summary(for: room, myID: myID)
        broadcastSnapshot()
    }

    /// Builds an ordered snapshot from `rooms` + `summaries` and yields
    /// it via `onSnapshot`. Rooms without a cached summary are skipped
    /// — that should never happen in steady state, but during the brief
    /// window between `.touched` insertion and summary computation a
    /// concurrent RoomInfo fire could land here; skipping is safer than
    /// emitting partial data.
    private func broadcastSnapshot() {
        var ordered: [ChatSummary] = []
        ordered.reserveCapacity(rooms.count)
        for room in rooms {
            if let s = summaries[room.id()] { ordered.append(s) }
        }
        onSnapshot(ordered)
    }
}

// MARK: - Room → ChatSummary mapping

/// Production `Room` → `ChatSummary` mapping, shared between
/// `RoomListSubscription`'s touched-row recompute and
/// `ChatServiceLive`'s construction-throw fallback poll. Centralised so
/// the two paths can't drift.
enum ChatSummaryMapper {

    static func summary(for room: Room, myID: String) async -> ChatSummary {
        let roomID = room.id()
        let title = room.displayName() ?? roomID
        let bot = botIdentity(from: room, excluding: myID, fallbackTitle: title)
        let lastActivity = await timestamp(of: room.latestEvent())
        return ChatSummary(
            id: roomID,
            title: title,
            bot: bot,
            lastActivity: lastActivity,
            unreadCount: 0
        )
    }

    static func summaries(for rooms: [Room], client: Client) async -> [ChatSummary] {
        let myID = (try? client.userId()) ?? ""
        var result: [ChatSummary] = []
        result.reserveCapacity(rooms.count)
        for room in rooms {
            result.append(await summary(for: room, myID: myID))
        }
        return result
    }

    private static func timestamp(of event: LatestEventValue) -> Date? {
        switch event {
        case .none: return nil
        case .remote(let ts, _, _, _, _),
             .remoteInvite(let ts, _, _),
             .local(let ts, _, _, _, _):
            return Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        }
    }

    private static func botIdentity(from room: Room, excluding myID: String, fallbackTitle: String) -> BotIdentity {
        let heroes = room.heroes()
        if let hero = heroes.first(where: { $0.userId != myID }) ?? heroes.first {
            return BotIdentity(
                matrixID: hero.userId,
                displayName: hero.displayName ?? hero.userId,
                avatarURL: hero.avatarUrl.flatMap(URL.init(string:))
            )
        }
        return BotIdentity(matrixID: "@unknown:matron", displayName: fallbackTitle, avatarURL: nil)
    }
}
