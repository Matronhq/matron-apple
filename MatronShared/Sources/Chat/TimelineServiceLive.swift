import Foundation
import os
import MatrixRustSDK
import MatronEvents
import MatronModels
import MatronSearch
import MatronSync

/// Live `TimelineService` backed by the Matrix Rust SDK.
///
/// Holds a single `MatrixRustSDK.Timeline` handle once `items()` is first
/// subscribed. Sends use the same handle. Snapshots are produced by an
/// internal `TimelineSnapshotListener` that walks `TimelineDiff` events
/// and rebuilds an ordered map keyed by `TimelineUniqueId.id`.
///
/// Like `ChatServiceLive`, this is `final class @unchecked Sendable`
/// because the SDK handles are reference-typed across async hops.
public final class TimelineServiceLive: TimelineService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let sync: MatronSync.SyncService
    private let roomID: String

    /// Phase 6 (Search): when present, the snapshot listener indexes decrypted
    /// `.text` / tool-call bodies into the FTS index as they flow through.
    /// Optional so tests and any non-indexing construction path can omit it.
    private let search: SearchService?

    /// Single `MatrixRustSDK.Timeline` instance shared by `items()`,
    /// every send, paginate, and markAsRead. Built lazily on first use.
    ///
    /// Why cache: `Room.timeline()` BUILDS A NEW TIMELINE on every call
    /// — the SDK doc-comment is explicit ("Create a timeline with a
    /// default configuration, i.e. a live timeline…"). Without caching,
    /// `items()` builds Timeline T1 and attaches its listener to it,
    /// while `paginateBackward` builds an unrelated Timeline T2 and
    /// runs paginate on T2's empty internal store — paginate returns
    /// in single-digit milliseconds claiming `reachedStart=false` (T2
    /// is at the live tail, hasn't even started), no `/messages` HTTP
    /// goes out, T2 is dropped, T1 (which the view watches) never
    /// receives any new events. Bug confirmed via SDK trace + view-
    /// model log lining up: paginate "completes" 13ms after enter with
    /// no `messages` span in the SDK trace at all.
    ///
    /// Identity matters not just for paginate but for sends — the
    /// caller's local-echo + send-state listener (when we add one)
    /// will only fire on the SAME Timeline that owns the in-flight
    /// `SendHandle`. Lock-based init so the rare double-first-call
    /// race (e.g. items() and paginate-on-open kicking off in
    /// parallel) doesn't build two Timelines.
    private let timelineLock = NSLock()
    private var cachedTimeline: Timeline?
    /// The `Room` the timeline was built from, cached under the same
    /// lock. `sendButtonResponse` needs it because `sendRaw` is a
    /// Room-level API (the Timeline FFI surface has no raw-event
    /// send) — same call Matron X routes button responses through.
    private var cachedRoom: Room?

    /// Signatures of button responses this device has sent. Owned here
    /// (the writer is `sendButtonResponse`) and handed to every
    /// `TimelineSnapshotListener` so the SDK→DTO mapping can recognise our
    /// own LOCAL echo of a button response and hide it. See
    /// `PendingButtonAnswerStore`.
    private let pendingButtonAnswers = PendingButtonAnswerStore()

    public init(
        provider: ClientProvider,
        session: UserSession,
        sync: MatronSync.SyncService,
        roomID: String,
        search: SearchService? = nil
    ) {
        self.provider = provider
        self.session = session
        self.sync = sync
        self.roomID = roomID
        self.search = search
    }

    public func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            // Holder owns both the setup `Task` and the eventual listener
            // `TaskHandle`. Reassigning `continuation.onTermination` had a
            // race window: if the consumer terminated between
            // `addListener` returning and the second `onTermination = …`
            // assignment, the old closure cancelled the setup task but
            // the freshly-attached listener handle leaked.
            let holder = TimelineLifecycleHolder()
            let task = Task { [self] in
                do {
                    try await sync.waitUntilReady()
                    let timeline = try await timeline()
                    let listener = TimelineSnapshotListener(
                        continuation: continuation,
                        pendingButtonAnswers: pendingButtonAnswers,
                        roomID: roomID,
                        search: search
                    )
                    let handle = await timeline.addListener(listener: listener)
                    holder.setHandle(handle)
                } catch {
                    // Surface the failure to the consumer instead of
                    // silently completing — `ChatViewModel` routes this
                    // into `error` so the View can render a banner /
                    // overlay (QA finding #10).
                    continuation.finish(throwing: error)
                }
            }
            holder.setTask(task)
            // Assigned exactly once. The holder will atomically cancel
            // whichever of (task, handle) exist at termination time.
            continuation.onTermination = { _ in holder.cancelAll() }
        }
    }

    public func sendText(_ body: String, inReplyTo: String?) async throws {
        let timeline = try await timeline()
        let content = messageEventContentFromMarkdown(md: body)
        if let replyID = inReplyTo {
            // `sendReply` (vs hand-rolling `m.relates_to`) so the SDK
            // adds the rich-reply fallback formatting automatically.
            try await timeline.sendReply(msg: content, eventId: replyID)
        } else {
            _ = try await timeline.send(msg: content)
        }
    }

    public func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
        let room = try await room()
        // Byte-compatible with Matron X `TimelineController.sendButtonResponse`
        // and what the bridge's reader expects: structured
        // `selected_values` (preferred by the bridge) + the joined
        // plaintext fallback in `body`, related to the prompt via the
        // `chat.matron.button_answer` rel_type.
        let body = selectedValues.joined(separator: ", ")
        let content: [String: Any] = [
            "msgtype": "m.text",
            "body": body,
            MatronEventType.buttonResponse: [
                "selected_values": selectedValues
            ],
            "m.relates_to": [
                "rel_type": MatronEventType.buttonAnswer,
                "event_id": promptEventID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TimelineServiceError.encodingFailed
        }
        // Record BEFORE the send so the signature exists before the local
        // echo can surface on the timeline (see `pendingButtonAnswers`).
        pendingButtonAnswers.record(body: body, promptID: promptEventID, values: selectedValues)
        try await room.sendRaw(eventType: "m.room.message", content: json)
    }

    public func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        let timeline = try await timeline()
        let params = UploadParameters(
            source: .data(bytes: data, filename: filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        let info = ImageInfo(
            height: nil,
            width: nil,
            mimetype: mimeType,
            size: UInt64(data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil,
            blurhash: nil,
            isAnimated: nil
        )
        // No `await`: in matrix-rust-components-swift v26 `sendImage` is
        // declared `throws -> SendAttachmentJoinHandle` (synchronous),
        // not `async throws`. The handle represents the in-flight upload
        // that the SDK runs on its own runtime; the call itself returns
        // immediately. See `matrix_sdk_ffi.swift` line ~16051. Compare
        // with `Timeline.send(msg:)` above, which *is* `async throws`.
        _ = try timeline.sendImage(params: params, thumbnailSource: nil, imageInfo: info)
    }

    public func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        let timeline = try await timeline()
        let params = UploadParameters(
            source: .data(bytes: data, filename: filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        let info = FileInfo(
            mimetype: mimeType,
            size: UInt64(data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil
        )
        // No `await`: see `sendImage` above. `Timeline.sendFile` is
        // `throws -> SendAttachmentJoinHandle` in the v26 SDK, not
        // `async throws`. (`matrix_sdk_ffi.swift` line ~16041.)
        _ = try timeline.sendFile(params: params, fileInfo: info)
    }

    public func paginateBackward(requestSize: UInt16) async throws -> Bool {
        let timeline = try await timeline()
        // SDK's `paginateBackwards` returns `true` when the timeline has
        // reached the start of history. Forward that so the view-model
        // can stop firing paginate from the topmost-row `.onAppear`.
        return try await timeline.paginateBackwards(numEvents: requestSize)
    }

    public func markAsRead() async throws {
        let timeline = try await timeline()
        try await timeline.markAsRead(receiptType: .read)
    }

    // MARK: - Helpers

    /// Returns the cached `Timeline`, building it on first call. Every
    /// caller (items listener, sends, paginate, markAsRead) gets the
    /// same instance — see the `cachedTimeline` doc-comment for the
    /// reason. Keep `await sync.waitUntilReady()` upstream of this
    /// helper (caller's responsibility) — building a Timeline before
    /// sliding sync's room store is hydrated would force the SDK to
    /// build it against an empty room view.
    ///
    /// The previous "fresh Timeline per operation" approach was
    /// motivated by a worry about SDK-driven teardown, but that risk
    /// was hypothetical — `Room.timeline()` is documented to *build*
    /// a new timeline each call, not return a shared handle, and the
    /// resulting Timeline is owned by us. Holding a strong reference
    /// for the lifetime of `TimelineServiceLive` (which itself is
    /// LRU-cached per `(userID, roomID)` in `AppDependencies`) ties
    /// the Timeline lifecycle to the cache's eviction, which is the
    /// behaviour we want.
    private func timeline() async throws -> Timeline {
        timelineLock.lock()
        if let cached = cachedTimeline {
            timelineLock.unlock()
            return cached
        }
        timelineLock.unlock()
        let room = try await room()
        let built = try await room.timeline()
        timelineLock.lock()
        // Re-check under the lock — a parallel first call may have
        // beaten us; keep whichever instance won the race so both
        // callers observe the same handle. The loser instance is
        // dropped (its async drop runs on the SDK's runtime).
        if let winner = cachedTimeline {
            timelineLock.unlock()
            return winner
        }
        cachedTimeline = built
        timelineLock.unlock()
        return built
    }

    /// Returns the cached `Room`, resolving it on first call. Same
    /// lock + re-check-after-await shape as `timeline()`; the two
    /// caches stay independent so `sendButtonResponse` on a freshly-
    /// opened room doesn't force a Timeline build it never uses.
    private func room() async throws -> Room {
        timelineLock.lock()
        if let cached = cachedRoom {
            timelineLock.unlock()
            return cached
        }
        timelineLock.unlock()
        let resolved = try await Self.resolveRoom(roomID: roomID, sync: sync, provider: provider, session: session)
        timelineLock.lock()
        if let winner = cachedRoom {
            timelineLock.unlock()
            return winner
        }
        cachedRoom = resolved
        timelineLock.unlock()
        return resolved
    }

    /// Bridges from the chat-list-visible `summary.id` to a usable
    /// `MatrixRustSDK.Room` for the SDK timeline call. The chat list is
    /// sourced from sliding sync via `RoomListService`/`RoomList`, but
    /// `Client.getRoom` only sees rooms once the BaseClient store has
    /// hydrated from the sync stream. On a cold start we observed every
    /// chat opening with `TimelineServiceError.roomNotFound` even though
    /// the chat list was rendering 300+ rooms — `getRoom` was returning
    /// nil for rooms that only existed in the room-list-service view.
    /// Fall back to the same upstream the chat list uses
    /// (`SyncService.roomListService().room(roomId:)`) — that path
    /// returns a registered, subscribed `Room` for any ID currently
    /// surfaced by sliding sync, which by definition includes everything
    /// the user can see in the list.
    static func resolveRoom(
        roomID: String,
        sync: MatronSync.SyncService,
        provider: ClientProvider,
        session: UserSession
    ) async throws -> Room {
        let client = try await provider.client(for: session)
        if let room = try client.getRoom(roomId: roomID) {
            return room
        }
        if let sdkSync = await sync.sdkService() {
            do {
                return try sdkSync.roomListService().room(roomId: roomID)
            } catch {
                // Fall through to a typed not-found if the room-list
                // service also has no record of this ID — surfaces the
                // same overlay as before for genuinely-missing rooms.
            }
        }
        throw TimelineServiceError.roomNotFound(roomID)
    }
}

public enum TimelineServiceError: Error, Equatable, Sendable {
    case roomNotFound(String)
    /// `JSONSerialization` produced non-UTF8 output for a raw event
    /// body — practically unreachable, but typed so the send path
    /// never crashes on a force-unwrap.
    case encodingFailed
}

/// Owns the setup `Task` and the SDK listener `TaskHandle` for a single
/// `items()` subscription. `cancelAll()` is invoked from the AsyncStream
/// termination closure and atomically cancels both — even if the consumer
/// terminates between `setTask` and `setHandle`. This replaces the prior
/// double-assignment of `continuation.onTermination` which had a race
/// window where the listener handle could leak.
///
/// The holder stores cancellation as opaque `() -> Void` closures so it
/// stays testable without needing to construct a real SDK `TaskHandle`.
final class TimelineLifecycleHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var taskCancel: (() -> Void)?
    private var handleCancel: (() -> Void)?
    private var cancelled = false

    func setTask(_ t: Task<Void, Never>) {
        setTaskCancel { t.cancel() }
    }

    func setHandle(_ h: TaskHandle) {
        setHandleCancel { h.cancel() }
    }

    /// Test seam — lets `TimelineLifecycleHolderTests` register a
    /// cancel-recorder without needing a real `TaskHandle`.
    func setTaskCancel(_ cancel: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            cancel()
            return
        }
        self.taskCancel = cancel
        lock.unlock()
    }

    func setHandleCancel(_ cancel: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            cancel()
            return
        }
        self.handleCancel = cancel
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let t = taskCancel
        let h = handleCancel
        taskCancel = nil
        handleCancel = nil
        lock.unlock()
        t?()
        h?()
    }
}

// MARK: - Pending button-answer signatures

/// Thread-safe record of button responses this device has sent, keyed by
/// the joined `body` on the wire. `TimelineServiceLive.sendButtonResponse`
/// writes; the `TimelineSnapshotListener` it owns reads (and clears on the
/// server echo) to recognise our own LOCAL echo of a button response.
///
/// Why this exists: `Room.sendRaw` returns no send handle and rust-sdk
/// exposes no raw content for a local echo, so the echo arrives as a plain
/// `m.text` with no `originalJson` and a `transactionId` — the JSON path in
/// `mapButtonsMessage` can't see the `chat.matron.button_response` key and
/// the echo would render its raw `selected_values` body (e.g. "cancel:0")
/// until the server echo lands. matrix-js-sdk (Matron X) keeps the full
/// content on its local echoes, so it doesn't need this; rust-sdk does.
///
/// FIFO-capped so a failed send — which never produces a clearing server
/// echo — can't grow the store without bound. Body-keyed matching can in
/// principle collide with a genuine own text message of the same body, but
/// the consequence is only hiding it for the ~1s until its own echo
/// re-maps it; for the queue-action shape (value ≠ label, e.g. "cancel:0")
/// a collision is essentially impossible.
final class PendingButtonAnswerStore: @unchecked Sendable {
    struct PendingButtonAnswer: Equatable {
        let promptID: String
        let values: [String]
    }

    private let lock = NSLock()
    private var byBody: [String: PendingButtonAnswer] = [:]
    private var order: [String] = []
    private let cap = 16

    func record(body: String, promptID: String, values: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if byBody[body] == nil { order.append(body) }
        byBody[body] = PendingButtonAnswer(promptID: promptID, values: values)
        while order.count > cap {
            let oldest = order.removeFirst()
            byBody[oldest] = nil
        }
    }

    func match(forBody body: String) -> PendingButtonAnswer? {
        lock.lock()
        defer { lock.unlock() }
        return byBody[body]
    }

    func clear(forBody body: String) {
        lock.lock()
        defer { lock.unlock() }
        if byBody.removeValue(forKey: body) != nil {
            order.removeAll { $0 == body }
        }
    }
}

// MARK: - Diff listener

/// Walks `MatrixRustSDK.TimelineDiff` updates and rebuilds an ordered
/// snapshot keyed by `TimelineUniqueId.id`. The same logic is mirrored
/// by `SnapshotApplier` in `TimelineDiffApplicationTests` so the
/// production switch-statement is regression-protected without standing
/// up a real SDK.
final class TimelineSnapshotListener: TimelineListener, @unchecked Sendable {
    /// Always-on (not `MatronDebug`-gated) so a timeline that clears to
    /// empty is visible in Console without a debug flag — clears are rare
    /// and significant. Confirms the "messages flash away then come back"
    /// trigger: a non-empty→empty snapshot names the diff kinds that
    /// caused it (a bare `clear` vs an atomic `reset`).
    private static let logger = os.Logger(subsystem: "chat.matron", category: "timeline-listener")

    private let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation

    /// Maintains the current ordered snapshot. Items are keyed by their
    /// stable id (event id once the homeserver has acked, transaction id
    /// before).
    private var byID: [String: TimelineItem] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    /// Shared with the owning `TimelineServiceLive` so `mapButtonsMessage`
    /// can recognise our own local-echo button responses. Read (and cleared
    /// on the server echo) here; written by `sendButtonResponse`.
    private let pendingButtonAnswers: PendingButtonAnswerStore

    /// Phase 6 (Search): the room this timeline belongs to + the index to write
    /// decrypted bodies into. `search` is nil when indexing is disabled (tests,
    /// or any construction without an injected service).
    private let roomID: String
    private let search: SearchService?

    /// `isOwn` is sourced from `EventTimelineItem.isOwn` — the SDK already
    /// knows which events came from us, so we don't need to thread the
    /// user ID through here. (Earlier drafts stored `myID` for a manual
    /// comparison; the property was unused and has been removed.)
    init(
        continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation,
        pendingButtonAnswers: PendingButtonAnswerStore = PendingButtonAnswerStore(),
        roomID: String = "",
        search: SearchService? = nil
    ) {
        self.continuation = continuation
        self.pendingButtonAnswers = pendingButtonAnswers
        self.roomID = roomID
        self.search = search
    }

    /// SDK callback. Apply each diff to the in-memory snapshot, then
    /// yield the resulting `[TimelineItem]` to the AsyncStream consumer.
    /// Synchronous (matches `TimelineListener`'s requirement) so this
    /// runs on whatever thread the SDK calls us on.
    ///
    /// The snapshot is built and copied out *while* the lock is held, but
    /// `continuation.yield(_:)` runs *after* the lock is released. The
    /// AsyncStream consumer's continuation can run synchronously (or stall
    /// under back-pressure); yielding inside the lock would block the
    /// SDK's timeline thread waiting for the consumer to drain.
    func onUpdate(diff: [TimelineDiff]) {
        var countBefore = 0
        let snapshot: [TimelineItem] = {
            lock.lock()
            defer { lock.unlock() }
            countBefore = order.count
            for d in diff {
                switch d {
                case .append(let values):
                    for v in values { upsertAtEnd(map(v)) }
                case .clear:
                    byID.removeAll()
                    order.removeAll()
                case .pushFront(let value):
                    insert(map(value), at: 0)
                case .pushBack(let value):
                    upsertAtEnd(map(value))
                case .popFront:
                    guard !order.isEmpty else { break }
                    let id = order.removeFirst()
                    byID.removeValue(forKey: id)
                case .popBack:
                    guard !order.isEmpty else { break }
                    let id = order.removeLast()
                    byID.removeValue(forKey: id)
                case .insert(let index, let value):
                    insert(map(value), at: Int(index))
                case .set(let index, let value):
                    replace(at: Int(index), with: map(value))
                case .remove(let index):
                    removeAt(Int(index))
                case .truncate(let length):
                    truncate(to: Int(length))
                case .reset(let values):
                    byID.removeAll()
                    order.removeAll()
                    for v in values { upsertAtEnd(map(v)) }
                }
            }
            return order.compactMap { byID[$0] }
        }()
        if snapshot.isEmpty && countBefore > 0 {
            Self.logger.notice("timeline cleared to empty (was \(countBefore, privacy: .public) items); diffs=[\(Self.describe(diff), privacy: .public)]")
        }
        continuation.yield(snapshot)
    }

    /// Names the diff kinds in an update for the cleared-to-empty log —
    /// a bare `clear` means the SDK didn't repopulate in the same batch
    /// (the flash window), vs an atomic `reset` which carries the new
    /// values and never yields empty.
    private static func describe(_ diff: [TimelineDiff]) -> String {
        diff.map { d in
            switch d {
            case .append: return "append"
            case .clear: return "clear"
            case .pushFront: return "pushFront"
            case .pushBack: return "pushBack"
            case .popFront: return "popFront"
            case .popBack: return "popBack"
            case .insert: return "insert"
            case .set: return "set"
            case .remove: return "remove"
            case .truncate: return "truncate"
            case .reset: return "reset"
            }
        }.joined(separator: ",")
    }

    // MARK: - Snapshot mutators

    private func upsertAtEnd(_ item: TimelineItem) {
        if byID[item.id] == nil { order.append(item.id) }
        byID[item.id] = item
    }

    private func insert(_ item: TimelineItem, at index: Int) {
        let clamped = max(0, min(index, order.count))
        if byID[item.id] != nil {
            order.removeAll { $0 == item.id }
        }
        let target = min(clamped, order.count)
        order.insert(item.id, at: target)
        byID[item.id] = item
    }

    private func replace(at index: Int, with item: TimelineItem) {
        guard order.indices.contains(index) else {
            upsertAtEnd(item)
            return
        }
        let oldID = order[index]
        // If the new id already lives at some *other* position in `order`,
        // remove that stale entry first — otherwise `order` would carry
        // duplicate ids for the same item, and `compactMap { byID[$0] }`
        // would yield the same `TimelineItem` twice. Defensive against
        // SDK diffs that move-via-set rather than emitting an explicit
        // remove + insert pair. We do the dedup *before* overwriting
        // `order[index]` so the foreign occurrence is unambiguous.
        if oldID != item.id {
            if let existing = order.firstIndex(of: item.id) {
                order.remove(at: existing)
                // Removing before `index` shifts our target left by one.
                let adjusted = existing < index ? index - 1 : index
                byID.removeValue(forKey: oldID)
                order[adjusted] = item.id
            } else {
                byID.removeValue(forKey: oldID)
                order[index] = item.id
            }
        }
        byID[item.id] = item
    }

    private func removeAt(_ index: Int) {
        guard order.indices.contains(index) else { return }
        let id = order.remove(at: index)
        byID.removeValue(forKey: id)
    }

    private func truncate(to length: Int) {
        guard length < order.count else { return }
        let removed = order.suffix(order.count - length)
        order.removeLast(order.count - length)
        for id in removed { byID.removeValue(forKey: id) }
    }

    // MARK: - SDK → DTO mapping

    /// Convert an SDK `TimelineItem` into our DTO. Unknown SDK kinds map
    /// to `.unknown(eventType:)` so they round-trip into the UI as a
    /// placeholder rather than disappearing silently.
    private func map(_ sdk: MatrixRustSDK.TimelineItem) -> TimelineItem {
        let id = sdk.uniqueId().id
        if let event = sdk.asEvent() {
            return mapEvent(event, id: id)
        }
        if let virtual = sdk.asVirtual() {
            return mapVirtual(virtual, id: id)
        }
        // Should be unreachable per FFI contract but keep a safe fallback.
        return TimelineItem(
            id: id,
            sender: "",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .unknown(eventType: "unknown"),
            isOwn: false,
            sendState: .sent
        )
    }

    private func mapEvent(_ ev: EventTimelineItem, id: String) -> TimelineItem {
        let ts = Date(timeIntervalSince1970: TimeInterval(ev.timestamp) / 1000)
        // Phase 5 Task 6: custom Matron event types (`chat.matron.tool_call`,
        // `.ask_user`) come through as `MsgLikeKind.other(.other("chat.matron.…"))`
        // — the SDK's MessageLikeEventType has no first-class case for them.
        // `mapMatronCustomEvent` checks for the type, pulls the original
        // JSON via `ev.lazyProvider.debugInfo().originalJson`, and parses
        // into the typed DTO. Falls through to `mapContent` when the event
        // isn't a Matron custom type or its JSON couldn't be parsed (graceful
        // degradation: a malformed payload still renders as `.unknown`).
        let kind = mapMatronCustomEvent(ev) ?? mapButtonsMessage(ev) ?? mapContent(ev.content)
        indexIfNeeded(kind: kind, ev: ev, timestamp: ts)
        let sendState: TimelineItem.SendState = mapSendState(ev.localSendState)
        // Surface the `m.in_reply_to` target so `ChatViewModel` can
        // mark `ask_user` prompts answered when a reply to them lands
        // (including from the user's other devices).
        var inReplyToEventID: String?
        if case .msgLike(let msg) = ev.content {
            inReplyToEventID = msg.inReplyTo?.eventId()
        }
        return TimelineItem(
            id: id,
            sender: ev.sender,
            timestamp: ts,
            kind: kind,
            isOwn: ev.isOwn,
            sendState: sendState,
            inReplyToEventID: inReplyToEventID
        )
    }

    /// Phase 6 (Search): index a decrypted `.text` / tool-call body into the FTS
    /// index as it flows through the snapshot mapper. No-op when no `search`
    /// service is wired (tests / non-indexing paths).
    ///
    /// Only events with a server-acked Matrix event ID are indexed. Local echoes
    /// (`.transactionId`) are skipped: their unique IDs aren't navigable, and the
    /// same event re-indexes under its real event ID once the server echo lands
    /// (a `.set` diff re-runs the mapper). Storing the real event ID is what lets
    /// search's jump-to-message focus the timeline via the SDK's `focusedAt`.
    ///
    /// `.text` and tool-call *results* only. `.askUser` / `.askUserAnswer`
    /// (buttons) bodies are protocol noise (e.g. "cancel:0"); images / files /
    /// state changes carry no searchable text. Idempotent re-indexing on every
    /// re-map (incl. `.reset` on re-sync) is harmless — `index` is INSERT OR
    /// REPLACE keyed on the UNIQUE event ID.
    private func indexIfNeeded(kind: TimelineItem.Kind, ev: EventTimelineItem, timestamp: Date) {
        guard let search else { return }
        guard case .eventId(let eventID) = ev.eventOrTransactionId else { return }
        let body: String
        switch kind {
        case .text(let text, _):
            body = text
        case .toolCall(_, let evt):
            guard let result = evt.resultText else { return }
            body = "[\(evt.tool)] \(result)"
        default:
            return
        }
        let sender = ev.sender
        let roomID = self.roomID
        // Fire-and-forget: the SDK drives `onUpdate` synchronously on its timeline
        // thread and we're inside the snapshot lock here, so the SQLite write must
        // not block. A failed index is non-fatal — the next snapshot or backfill
        // re-attempts.
        Task { [search] in
            try? await search.index(roomID: roomID, eventID: eventID, sender: sender, timestamp: timestamp, body: body)
        }
    }

    /// Returns `.askUser` / `.askUserAnswer` when `ev` is an ordinary
    /// `m.room.message` carrying one of the Matron X buttons-protocol
    /// content keys (`chat.matron.buttons` / `.button_response`),
    /// else nil so the caller falls through to standard mapping.
    ///
    /// Unlike the Phase 5 custom event types (which arrive as
    /// `MsgLikeKind.other`), buttons piggyback on plain `m.text`
    /// messages, so the only place they're visible is the original
    /// event JSON. Pulling `debugInfo().originalJson` per message has
    /// an FFI cost; the cheap `contains("chat.matron.")` substring
    /// pre-check (same trick Matron X's factory uses) keeps the JSON
    /// parse off the hot path for normal traffic.
    private func mapButtonsMessage(_ ev: EventTimelineItem) -> TimelineItem.Kind? {
        guard case .msgLike(let msg) = ev.content,
              case .message(let messageContent) = msg.kind else {
            return nil
        }
        // Remote echo: the server has the event, so the raw JSON (with the
        // `chat.matron.button_response` / `.buttons` keys) is available.
        if let json = ev.lazyProvider.debugInfo().originalJson,
           json.contains("chat.matron.") {
            guard case .eventId(let eventID) = ev.eventOrTransactionId,
                  let kind = Self.parseButtonsMessage(originalJson: json, eventID: eventID) else {
                return nil
            }
            // Our button response's server echo has landed — the local-echo
            // signature is no longer needed.
            if case .askUserAnswer = kind {
                pendingButtonAnswers.clear(forBody: messageContent.body)
            }
            return kind
        }
        // Local echo: no `originalJson`, a `transactionId` rather than an
        // `eventId`, and rust-sdk surfaces no raw content for it — so the
        // JSON path above can't recognise our own just-sent button
        // response. Match it against the body recorded in
        // `sendButtonResponse` so it's hidden (`.askUserAnswer`) instead of
        // flashing its raw `selected_values` body. See `pendingButtonAnswers`.
        let isLocalEcho: Bool
        if case .transactionId = ev.eventOrTransactionId { isLocalEcho = true } else { isLocalEcho = false }
        return Self.localEchoButtonAnswer(
            isOwn: ev.isOwn,
            isLocalEcho: isLocalEcho,
            body: messageContent.body,
            pending: pendingButtonAnswers.match(forBody: messageContent.body)
        )
    }

    /// Pure decision for the local-echo branch of `mapButtonsMessage`,
    /// split out so it's unit-testable without a Rust-handle-backed
    /// `EventTimelineItem`. Returns the hidden `.askUserAnswer` only for an
    /// own, not-yet-sent (`transactionId`) echo whose body matches a
    /// recorded button-response signature.
    static func localEchoButtonAnswer(
        isOwn: Bool,
        isLocalEcho: Bool,
        body: String,
        pending: PendingButtonAnswerStore.PendingButtonAnswer?
    ) -> TimelineItem.Kind? {
        guard isOwn, isLocalEcho, let pending else { return nil }
        return .askUserAnswer(promptEventID: pending.promptID, selectedValues: pending.values)
    }

    /// Pure JSON → Kind mapping for the buttons protocol, split out of
    /// `mapButtonsMessage` so unit tests can exercise it without a
    /// real `EventTimelineItem` Rust handle (same pattern as
    /// `parseCustomEvent`).
    ///
    /// Checked in this order:
    /// 1. `chat.matron.button_response` content key → `.askUserAnswer`
    ///    (hidden by the renderers, consumed by `pendingAsk()`).
    ///    Matron X hides every button-response message including the
    ///    legacy `button_response: true` form, so a response whose
    ///    structured fields don't parse still maps to `.askUserAnswer`
    ///    with whatever could be recovered rather than rendering its
    ///    raw `value1, value2` body as chat text.
    /// 2. `chat.matron.buttons` content key parsing cleanly →
    ///    `.askUser` riding the same sheet UI as `ask_user` events.
    /// 3. Anything else → nil (plaintext fallback rendering).
    static func parseButtonsMessage(originalJson: String, eventID: String) -> TimelineItem.Kind? {
        guard let data = originalJson.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = parsed["content"] as? [String: Any] else {
            return nil
        }
        if content[MatronEventType.buttonResponse] != nil {
            let response = content[MatronEventType.buttonResponse] as? [String: Any]
            let values = response?["selected_values"] as? [String] ?? []
            let relates = content["m.relates_to"] as? [String: Any]
            let promptID = relates?["event_id"] as? String ?? ""
            return .askUserAnswer(promptEventID: promptID, selectedValues: values)
        }
        if let evt = AskUserEvent.parseButtons(content: content) {
            return .askUser(eventID: eventID, evt)
        }
        return nil
    }

    /// Returns a `.toolCall` / `.askUser` `TimelineItem.Kind` when `ev`
    /// is one of the custom Matron event types, else nil. The caller
    /// falls through to the standard `mapContent` mapping when this
    /// returns nil — same shape Phase 5 graceful-degradation contract:
    /// any failure (wrong type, missing JSON, malformed content)
    /// re-routes through `.unknown(eventType:)`. The SDK-handle-bound
    /// bits (lazyProvider, eventOrTransactionId) are extracted here;
    /// the testable JSON → kind mapping lives in `Self.parseCustomEvent`.
    private func mapMatronCustomEvent(_ ev: EventTimelineItem) -> TimelineItem.Kind? {
        guard case .msgLike(let msg) = ev.content,
              case .other(let messageLikeEventType) = msg.kind,
              case .other(let typeString) = messageLikeEventType else {
            return nil
        }
        // Pull the original event JSON from the lazy provider. Local
        // echoes don't have one (the event hasn't been sent yet) —
        // those fall through to `.unknown` via the nil return.
        guard let json = ev.lazyProvider.debugInfo().originalJson else {
            return nil
        }
        // The Matrix event ID — used by the case to correlate
        // `m.replace` updates against a running tool call. Local echo's
        // transactionId branch isn't reached here because originalJson
        // is nil for local echoes.
        guard case .eventId(let eventID) = ev.eventOrTransactionId else {
            return nil
        }
        return Self.parseCustomEvent(typeString: typeString, originalJson: json, eventID: eventID)
    }

    /// Pure JSON → Kind mapping for the two custom Matron event types,
    /// pulled out of `mapMatronCustomEvent` so unit tests can exercise
    /// it without standing up a real `EventTimelineItem` Rust handle.
    /// Returns nil for non-Matron type strings, malformed JSON, missing
    /// `content` field, or content that doesn't parse cleanly via the
    /// per-type parsers in `MatronEvents`.
    static func parseCustomEvent(
        typeString: String,
        originalJson: String,
        eventID: String
    ) -> TimelineItem.Kind? {
        guard typeString == MatronEventType.toolCall ||
              typeString == MatronEventType.askUser else {
            return nil
        }
        guard let data = originalJson.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = parsed["content"] as? [String: Any] else {
            return nil
        }
        switch typeString {
        case MatronEventType.toolCall:
            guard let evt = ToolCallEvent.parse(content: content) else { return nil }
            return .toolCall(eventID: eventID, evt)
        case MatronEventType.askUser:
            guard let evt = AskUserEvent.parse(content: content) else { return nil }
            return .askUser(eventID: eventID, evt)
        default:
            return nil  // Already filtered above; defensive only.
        }
    }

    private func mapVirtual(_ v: VirtualTimelineItem, id: String) -> TimelineItem {
        let kind: TimelineItem.Kind
        let ts: Date
        // TODO Phase 3 (QA finding #16): split this into proper
        // `TimelineItem.Kind.dateDivider(Date)` / `.readMarker` /
        // `.timelineStart` cases instead of collapsing all three into
        // `.stateChange(text: "")`. The renderer's `shouldRender(_:)`
        // hides the empty-state-change today, but a real implementation
        // wants distinct visual treatment for each (sticky date pill,
        // unread divider line, "beginning of conversation" tombstone).
        switch v {
        case .dateDivider(let t):
            ts = Date(timeIntervalSince1970: TimeInterval(t) / 1000)
            kind = .stateChange(text: "")
        case .readMarker:
            ts = Date(timeIntervalSince1970: 0)
            kind = .stateChange(text: "")
        case .timelineStart:
            ts = Date(timeIntervalSince1970: 0)
            kind = .stateChange(text: "")
        }
        return TimelineItem(
            id: id,
            sender: "",
            timestamp: ts,
            kind: kind,
            isOwn: false,
            sendState: .sent
        )
    }

    private func mapContent(_ content: TimelineItemContent) -> TimelineItem.Kind {
        switch content {
        case .msgLike(let msg):
            return mapMsgLike(msg.kind)
        case .callInvite:
            return .unknown(eventType: "m.call.invite")
        case .rtcNotification:
            return .unknown(eventType: "m.rtc.notification")
        case .roomMembership(_, let displayName, let change, _):
            return .stateChange(text: membershipText(displayName: displayName, change: change))
        case .profileChange(let displayName, let prevDisplayName, _, _):
            let name = displayName ?? prevDisplayName ?? ""
            return .stateChange(text: "\(name) updated their profile")
        case .state:
            return .stateChange(text: "Room state changed")
        case .failedToParseMessageLike(let eventType, _):
            return .unknown(eventType: eventType)
        case .failedToParseState(let eventType, _, _):
            return .unknown(eventType: eventType)
        }
    }

    private func mapMsgLike(_ kind: MsgLikeKind) -> TimelineItem.Kind {
        switch kind {
        case .message(let content):
            return mapMessageType(content.msgType, fallbackBody: content.body)
        case .sticker:
            return .unknown(eventType: "m.sticker")
        case .poll:
            return .unknown(eventType: "m.poll.start")
        case .redacted:
            return .stateChange(text: "Message deleted")
        case .unableToDecrypt:
            return .unknown(eventType: "m.room.encrypted")
        case .other(let eventType):
            return .unknown(eventType: String(describing: eventType))
        case .liveLocation:
            return .unknown(eventType: "org.matrix.msc3672.beacon_info")
        }
    }

    private func mapMessageType(_ type: MessageType, fallbackBody: String) -> TimelineItem.Kind {
        switch type {
        case .text(let c):
            return .text(body: c.body, formattedHTML: c.formatted?.body)
        case .notice(let c):
            return .text(body: c.body, formattedHTML: c.formatted?.body)
        case .emote(let c):
            return .text(body: c.body, formattedHTML: c.formatted?.body)
        case .image(let c):
            let url = URL(string: c.source.url())
            // `c.info?.size.map { Int64($0) }` already yields `Int64?` —
            // the previous `?? nil` was a no-op and read like an intent
            // to coalesce when there's nothing to coalesce against.
            let size = c.info?.size.map { Int64($0) }
            return .image(url: url, caption: c.caption, sizeBytes: size)
        case .file(let c):
            let url = URL(string: c.source.url())
            // See `.image` above re: dropped `?? nil` — same reasoning.
            let size = c.info?.size.map { Int64($0) }
            return .file(url: url, filename: c.filename, sizeBytes: size)
        case .audio:
            return .unknown(eventType: "m.audio")
        case .video:
            return .unknown(eventType: "m.video")
        case .gallery:
            return .unknown(eventType: "m.gallery")
        case .location:
            return .unknown(eventType: "m.location")
        case .other(let msgtype, _):
            // fallbackBody isn't surfaced today — `.unknown` doesn't carry a
            // body. Phase 3+ should extend `.unknown` so unknown msgtypes
            // can render their plain-text body. Until then drop the param
            // on the floor (formerly a `_ = fallbackBody` dead store —
            // bugbot caught the false-utility line).
            return .unknown(eventType: msgtype)
        }
    }

    private func mapSendState(_ state: EventSendState?) -> TimelineItem.SendState {
        guard let state else { return .sent }
        switch state {
        case .notSentYet:
            return .sending
        case .sendingFailed(let error, _):
            return .failed(reason: String(describing: error))
        case .sent:
            return .sent
        }
    }

    private func membershipText(displayName: String?, change: MembershipChange?) -> String {
        let name = displayName ?? "User"
        switch change ?? .none {
        case .joined: return "\(name) joined"
        case .left: return "\(name) left"
        case .invited: return "\(name) was invited"
        case .banned: return "\(name) was banned"
        case .unbanned: return "\(name) was unbanned"
        case .kicked: return "\(name) was removed"
        case .kickedAndBanned: return "\(name) was removed and banned"
        case .invitationAccepted: return "\(name) accepted the invitation"
        case .invitationRejected: return "\(name) rejected the invitation"
        case .invitationRevoked: return "\(name)'s invitation was revoked"
        case .knocked: return "\(name) requested to join"
        case .knockAccepted: return "\(name) was admitted"
        case .knockRetracted: return "\(name) withdrew their request"
        case .knockDenied: return "\(name)'s request was denied"
        case .none, .error, .notImplemented: return "\(name) updated membership"
        }
    }
}
