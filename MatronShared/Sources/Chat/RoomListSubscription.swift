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
/// **Per-room subscriptions are deliberately NOT attached here.** Phase
/// 2.5 Task 3 spikes the overhead of N× `Room.subscribeToUpdates()`
/// first; until that lands, this type only re-renders rows when the
/// SDK-level room-list diff visits them (Set/Insert/PushBack/etc.).
/// Per-room `latestEvent`/`displayName` changes that don't trigger a
/// list-level diff won't propagate yet — that's the documented gap.
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

    /// Serial queue for diff batches. The listener fires from arbitrary
    /// SDK threads; we hop into a single-consumer Task that pulls batches
    /// off this stream and applies them in order.
    private var batchTask: Task<Void, Never>?
    private let batchContinuation: AsyncStream<[RoomListEntriesUpdate]>.Continuation

    /// Mirrors the SDK's ordered list of rooms. We hold `Room` references
    /// (not just IDs) so we can re-derive `ChatSummary` for touched rows
    /// without re-walking the room list service.
    private var rooms: [MatrixRustSDK.Room] = []

    /// Cached `ChatSummary` per room ID. Recomputed only for rows touched
    /// by the current diff batch, dropped for rows the batch removed.
    private var summaries: [String: ChatSummary] = [:]

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

        let (stream, continuation) = AsyncStream.makeStream(of: [RoomListEntriesUpdate].self)
        self.batchContinuation = continuation

        let listener = BatchListener { batch in
            // `continuation` is `Sendable`; yielding from arbitrary SDK
            // threads is the documented contract for AsyncStream.
            continuation.yield(batch)
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
            for await batch in stream {
                if Task.isCancelled { break }
                await self.handle(batch)
            }
        }
    }

    deinit {
        batchContinuation.finish()
        batchTask?.cancel()
        // Releasing `adapters` cancels the SDK-side subscription. The
        // listener strong-ref drops with `self`.
    }

    /// Handles a single batch from the listener: apply diffs to the
    /// ordered list, recompute summaries for touched rows, drop dead
    /// summaries, broadcast the resulting snapshot exactly once.
    private func handle(_ batch: [RoomListEntriesUpdate]) async {
        let mirrored = batch.map(RoomEntryDiff<MatrixRustSDK.Room>.from)
        let result = RoomListEntriesAlgorithm.apply(mirrored, to: &rooms)

        for id in result.dropped {
            summaries.removeValue(forKey: id)
        }

        if !result.touched.isEmpty {
            let myID = (try? client.userId()) ?? ""
            for i in result.touched {
                guard i < rooms.count else { continue }
                let room = rooms[i]
                summaries[room.id()] = await ChatSummaryMapper.summary(for: room, myID: myID)
            }
        }

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
