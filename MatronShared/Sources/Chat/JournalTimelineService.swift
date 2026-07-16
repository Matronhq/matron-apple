import Foundation
import os
import MatronJournal
import MatronModels
import MatronSearch

private extension Duration {
    /// `Task.sleep(for:)` takes a `Duration` directly, but overlay staleness
    /// cutoffs are computed against `Date`, which only understands
    /// `TimeInterval` (seconds as `Double`). This is the one conversion
    /// point so call sites stay in `Duration` (the injectable, testable
    /// unit) end to end.
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

/// `TimelineService` over the local journal mirror (Phase 7 replacement for
/// the Matrix-SDK-backed `TimelineServiceLive`). One instance per open room.
///
/// `items()` merges three inputs into a single snapshot stream:
///  1. `store.eventsStream(convoID:)`, mapped through `JournalTimelineMapper`;
///  2. streaming "ephemeral" overlay rows (assistant output arriving token
///     by token, before the finalize journal row lands);
///  3. local-echo rows for in-flight `sendText` calls, so the composer's
///     send feels instant instead of waiting on a round trip.
///
/// All three are coalesced on `OverlayState`, an actor, so mutation from the
/// ephemeral-fan-out task and from `sendText` (called from the main actor)
/// can never race.
public final class JournalTimelineService: TimelineService, @unchecked Sendable {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-timeline")
    private let convoID: String
    private let store: JournalStore
    private let engine: JournalSyncEngine
    private let api: JournalAPI
    private let ownSender: String
    private let search: (any SearchService)?
    private let overlay: OverlayState
    private let sweepInterval: Duration

    public init(
        convoID: String, store: JournalStore, engine: JournalSyncEngine,
        api: JournalAPI, session: UserSession, search: (any SearchService)? = nil,
        overlayStaleness: Duration = .seconds(30), sweepInterval: Duration = .seconds(10),
        toolStreamStaleness: Duration = .seconds(600)
    ) {
        self.convoID = convoID
        self.store = store
        self.engine = engine
        self.api = api
        self.ownSender = "user:\(session.userID)"
        self.search = search
        self.overlay = OverlayState(staleness: overlayStaleness.timeInterval,
                                    toolStaleness: toolStreamStaleness.timeInterval)
        self.sweepInterval = sweepInterval
    }

    /// Streaming overlays + local echoes, isolated on one actor.
    ///
    /// Re-emit plumbing: `sendText` registers a local echo from whatever
    /// context called it (usually the main actor), and `items()` subscribers
    /// need to see that echo immediately rather than waiting for the next
    /// store or ephemeral event. Rather than stash a mutable closure on the
    /// service (racy: multiple concurrent `items()` calls would clobber each
    /// other's callback, and it's a plain `var` on a class marked
    /// `@unchecked Sendable`), `OverlayState` exposes a `changes()`
    /// `AsyncStream<Void>` using the same continuation-registry pattern
    /// `JournalSyncEngine` already uses for `stateStream()` /
    /// `ephemerals(convoID:)`: a `nonisolated` accessor hands out a fresh
    /// `AsyncStream`, registers its continuation on the actor, and
    /// unregisters on termination. Every actor-isolated mutation that a
    /// subscriber must react to (currently just `addEcho`) broadcasts to all
    /// registered continuations. This supports multiple concurrent `items()`
    /// callers correctly and needs no mutable stored closures.
    actor OverlayState {
        struct Echo { let localID: String; let body: String; let created: Date; var failed = false }
        private(set) var streaming: [String: (text: String, updated: Date)] = [:]
        /// Latest event list from the store's `ValueObservation`. The
        /// observation already fetches the full row set on every change,
        /// so `emit()` reuses that instead of issuing its own second
        /// full-table read — which it used to do on EVERY tick, including
        /// each coalesced streaming-token tick that never touched the
        /// store at all.
        private(set) var events: [JournalEvent] = []
        /// Mapped-item memo keyed by event seq. Journal events are
        /// immutable once written (streaming mutations ride the ephemeral
        /// overlay, never the row), so a mapped `TimelineItem` never goes
        /// stale — re-mapping the whole conversation per emit was pure
        /// waste that grew with history length.
        private var mappedCache: [Int64: TimelineItem] = [:]
        /// Seqs the mapper returned `nil` for — memoized separately so
        /// hidden event types aren't re-parsed on every emit either.
        private var unmappable: Set<Int64> = []

        func setEvents(_ events: [JournalEvent]) {
            self.events = events
        }

        /// Maps the cached events through `JournalTimelineMapper`, reusing
        /// memoized results. Runs on this actor so a long conversation's
        /// first full map stays off the main actor.
        func mappedItems(ownSender: String, serverURL: URL) -> [TimelineItem] {
            var items: [TimelineItem] = []
            items.reserveCapacity(events.count)
            for event in events {
                if let cached = mappedCache[event.seq] {
                    items.append(cached)
                } else if unmappable.contains(event.seq) {
                    continue
                } else if let item = JournalTimelineMapper.timelineItem(
                    from: event, ownSender: ownSender, serverURL: serverURL) {
                    mappedCache[event.seq] = item
                    items.append(item)
                } else {
                    unmappable.insert(event.seq)
                }
            }
            // Bound the memo: after a mirror wipe (snapshot_required) the
            // event list shrinks and old seqs may never come back.
            if mappedCache.count + unmappable.count > events.count + 256 {
                let live = Set(events.map(\.seq))
                mappedCache = mappedCache.filter { live.contains($0.key) }
                unmappable = unmappable.intersection(live)
            }
            return items
        }
        /// Current activity indicator (typing / tool-use), if any. Per-convo,
        /// latest-wins; `.idle` clears it. Pruned by the same staleness sweep
        /// as streaming so a crashed agent's indicator can't stick forever.
        private(set) var activity: (label: String, updated: Date)?
        private(set) var echoes: [Echo] = []
        private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        private let staleness: TimeInterval
        private let toolStaleness: TimeInterval

        /// One live tool-output stream, keyed by message_ref. All positions
        /// are UTF-8 BYTE offsets into the command's full output; `bytes[0]`
        /// sits at absolute offset `startOffset` (nonzero after a
        /// head-truncated sync).
        struct ToolStream {
            var tool: String?
            var command: String?      // nil until a sync supplies meta
            var bytes: [UInt8]
            var startOffset: Int
            var headTruncated: Bool
            var updated: Date
        }
        private(set) var toolStreams: [String: ToolStream] = [:]
        /// Refs already retired by a durable row (FIFO, capped). Ephemerals
        /// can flush up to 200ms after the completion frame (protocol.md) —
        /// anything for a retired ref is ignored, never re-opened.
        private var retiredToolRefs: [String] = []
        /// Debounce ledger for viewing re-sends (the client's only resync
        /// mechanism). Per-ref so one broken stream can't spam the socket.
        private var resyncRequested: [String: Date] = [:]

        init(staleness: TimeInterval, toolStaleness: TimeInterval = 600) {
            self.staleness = staleness
            self.toolStaleness = toolStaleness
        }

        /// Applies one tool_stream frame. Returns true when the caller
        /// should re-send `viewing` — the protocol's client-side resync
        /// path — because we're missing bytes (gap / mid-join) or meta
        /// (an offset-0 start carries no command string; only a sync does).
        func applyToolStream(_ update: ToolStreamUpdate) -> Bool {
            let ref = update.messageRef
            guard !retiredToolRefs.contains(ref) else { return false }
            switch update.event {
            case let .append(offset, chunk):
                let chunkBytes = Array(chunk.utf8)
                guard var stream = toolStreams[ref] else {
                    guard offset == 0 else { return resyncDue(ref) } // mid-join: need full scrollback
                    toolStreams[ref] = ToolStream(tool: nil, command: nil, bytes: chunkBytes,
                                                  startOffset: 0, headTruncated: false, updated: Date())
                    return resyncDue(ref) // appends carry no meta — fetch the command via sync
                }
                let end = stream.startOffset + stream.bytes.count
                if offset == end {
                    stream.bytes.append(contentsOf: chunkBytes)
                } else if offset < end {
                    let overlap = end - offset
                    guard overlap < chunkBytes.count else { return false } // fully-duplicate retry
                    stream.bytes.append(contentsOf: chunkBytes.dropFirst(overlap))
                } else {
                    return resyncDue(ref) // gap: drop the chunk, ask for scrollback
                }
                stream.updated = Date()
                toolStreams[ref] = stream
                return false
            case let .sync(tool, command, offset, content, headTruncated):
                toolStreams[ref] = ToolStream(tool: tool, command: command,
                                              bytes: Array(content.utf8), startOffset: offset,
                                              headTruncated: headTruncated, updated: Date())
                return false
            case .end:
                // The server told us the buffer was freed (idle sweep, dead
                // bridge) — "drop the tile" per the protocol doc above. That
                // must be permanent like a durable-row retirement: without
                // recording the ref here, a reordered/late `append` or
                // `sync` for the same ref sailed past the `retiredToolRefs`
                // guard at the top of this method and re-created a live
                // tile the server had already disowned (bugbot: "tool_stream
                // end leaves ref unretired").
                toolStreams.removeValue(forKey: ref)
                retire(ref)
                return false
            }
        }

        /// Marks `ref` as retired (FIFO-capped) so any further frame for it
        /// is dropped by the guard at the top of `applyToolStream`. Shared
        /// by `.end` and by `reconcile`'s durable-row retirement so both
        /// paths stay in lockstep.
        private func retire(_ ref: String) {
            guard !retiredToolRefs.contains(ref) else { return }
            retiredToolRefs.append(ref)
            if retiredToolRefs.count > 64 { retiredToolRefs.removeFirst() }
        }

        private func resyncDue(_ ref: String) -> Bool {
            if let last = resyncRequested[ref], Date().timeIntervalSince(last) < 2 { return false }
            resyncRequested[ref] = Date()
            return true
        }

        func applyEphemeral(_ update: EphemeralUpdate) {
            let current = streaming[update.messageRef]?.text ?? ""
            let text = update.replaceText ?? (current + (update.textDelta ?? ""))
            streaming[update.messageRef] = (text, Date())
        }

        /// Applies an activity update. `.idle` clears the indicator; any
        /// other state (re)arms it with a freshly-computed label. A `nil`
        /// label (only `.idle` yields that) also clears.
        func applyActivity(_ update: ActivityUpdate) {
            if let label = JournalTimelineMapper.activityLabel(state: update.state, detail: update.detail) {
                activity = (label, Date())
            } else {
                activity = nil
            }
        }

        /// High-water mark of seqs already walked by `reconcile`. Echo
        /// retirement must only react to rows ARRIVING, not to the full
        /// event list re-walked on every emit — otherwise any old own
        /// message with the same body retires a fresh echo immediately
        /// (and, worse, clears a failed echo's "Not delivered" state
        /// while the send is still failed — bugbot "History clears
        /// failed echo").
        private var lastReconciledSeq: Int64 = 0

        func reconcile(with events: [JournalEvent], ownSender: String) {
            let newSeqFloor = lastReconciledSeq
            for event in events {
                if let ref = event.payload["message_ref"] as? String {
                    streaming.removeValue(forKey: ref)
                    // Retire the live tool tile: the durable row IS the
                    // command's completed form. Recorded even when no tile
                    // is open — a late ephemeral flush (≤200ms after the
                    // completion frame, protocol.md) must not re-open one.
                    toolStreams.removeValue(forKey: ref)
                    resyncRequested.removeValue(forKey: ref)
                    retire(ref)
                }
                // Finalize de-dup fallback: the bridge may omit `message_ref`
                // from the finalized row's payload (it's only guaranteed in
                // the stream frames and the server-side idem key). An agent
                // text row whose body equals a live overlay's accumulated
                // text IS that stream's finalized form — retire the overlay
                // so it doesn't double-show the message until staleness.
                if event.sender != ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String {
                    for (ref, entry) in streaming where entry.text == body {
                        streaming.removeValue(forKey: ref)
                    }
                }
                // Body-match is the only available signal: the server folds
                // `local_id` into the row's idem_key and strips idem_key from
                // broadcast/pagination rows, so the echo's id never comes
                // back. FIFO removal is order-correct for sequential sends of
                // identical text; prefer a *pending* echo so a delivered
                // copy's ack can't retire an undelivered one — but when only
                // a failed copy matches, this own-row IS its successful
                // retry landing, so the failure is resolved and can go.
                // Gated on seq > newSeqFloor: only rows arriving in THIS
                // reconcile may retire echoes — see `lastReconciledSeq`.
                if event.seq > newSeqFloor,
                   event.sender == ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String,
                   let index = echoes.firstIndex(where: { $0.body == body && !$0.failed })
                            ?? echoes.firstIndex(where: { $0.body == body }) {
                    echoes.remove(at: index)
                }
                lastReconciledSeq = max(lastReconciledSeq, event.seq)
            }
            let cutoff = Date().addingTimeInterval(-staleness)
            streaming = streaming.filter { $0.value.updated > cutoff }
            // Failed echoes are exempt from staleness: sweeping a "Not
            // delivered" row away 30s later silently vanishes the user's
            // message (2026-07-13 phone incident — send on a dead socket,
            // message evaporated). They clear on a delivered retry (above)
            // or when the per-room service is dropped.
            echoes = echoes.filter { $0.failed || $0.created > cutoff }
            if let current = activity, current.updated <= cutoff { activity = nil }
            // Tool streams are exempt from the short text-overlay cutoff —
            // a quiet build step legitimately produces nothing for minutes.
            // Their own (long) staleness is only a backstop: the server's
            // idle sweep emits `end` when a bridge dies while we're viewing.
            let toolCutoff = Date().addingTimeInterval(-toolStaleness)
            toolStreams = toolStreams.filter { $0.value.updated > toolCutoff }
            resyncRequested = resyncRequested.filter { $0.value > toolCutoff }
        }

        func addEcho(localID: String, body: String) {
            echoes.append(Echo(localID: localID, body: body, created: Date()))
            broadcastChange()
        }

        /// A `sendText` op failed (e.g. offline): flip the echo to `.failed`
        /// so it renders as undelivered instead of spinning forever. It
        /// still expires via the normal staleness sweep in `reconcile`.
        func markEchoFailed(localID: String) {
            guard let index = echoes.firstIndex(where: { $0.localID == localID }) else { return }
            echoes[index].failed = true
            broadcastChange()
        }

        /// A tick is emitted whenever isolated state changes in a way that
        /// `items()` subscribers must re-render for (see the doc comment on
        /// `OverlayState` above). Mirrors `JournalSyncEngine.ephemerals(convoID:)`.
        nonisolated func changes() -> AsyncStream<Void> {
            AsyncStream { continuation in
                let id = UUID()
                Task { await self.registerChange(id: id, continuation: continuation) }
                continuation.onTermination = { _ in
                    Task { await self.unregisterChange(id: id) }
                }
            }
        }

        private func registerChange(id: UUID, continuation: AsyncStream<Void>.Continuation) {
            changeContinuations[id] = continuation
        }

        private func unregisterChange(id: UUID) {
            changeContinuations.removeValue(forKey: id)
        }

        private func broadcastChange() {
            for continuation in changeContinuations.values { continuation.yield(()) }
        }
    }

    public func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        let convoID = convoID
        let engine = engine
        let store = store
        let overlay = overlay
        let ownSender = ownSender
        let serverURL = api.serverURL
        let sweepInterval = sweepInterval
        return AsyncThrowingStream { continuation in
            let emit: @Sendable () async -> Void = {
                let events = await overlay.events
                await overlay.reconcile(with: events, ownSender: ownSender)
                var items = await overlay.mappedItems(ownSender: ownSender, serverURL: serverURL)
                let lastTS = items.last?.timestamp ?? Date()
                for (ref, entry) in await overlay.streaming.sorted(by: { $0.key < $1.key }) {
                    items.append(JournalTimelineMapper.streamingItem(messageRef: ref, text: entry.text, convoTS: max(lastTS, entry.updated)))
                }
                for (ref, stream) in await overlay.toolStreams.sorted(by: { $0.key < $1.key }) {
                    items.append(JournalTimelineMapper.toolStreamItem(
                        messageRef: ref, command: stream.command,
                        text: JournalTimelineMapper.toolStreamText(bytes: stream.bytes),
                        headTruncated: stream.headTruncated,
                        convoTS: max(lastTS, stream.updated)))
                }
                for echo in await overlay.echoes {
                    items.append(TimelineItem(id: "echo:\(echo.localID)", sender: ownSender,
                                              timestamp: echo.created,
                                              kind: .text(body: echo.body, formattedHTML: nil),
                                              isOwn: true,
                                              sendState: echo.failed ? .failed(reason: "Not delivered") : .sending))
                }
                // Activity indicator sits below every other row. Dated to the
                // last row's timestamp (not "now") so it stays in that row's
                // day bucket — using `now` would spawn a spurious "Today"
                // separator above the indicator whenever the last message is
                // from an earlier day.
                if let activity = await overlay.activity {
                    let ts = items.last?.timestamp ?? activity.updated
                    items.append(JournalTimelineMapper.activityItem(label: activity.label, convoTS: ts))
                }
                continuation.yield(items)
            }

            // Producers (store changes, ephemeral fan-out, echo changes, the
            // staleness sweep) never call `emit()` directly — they just
            // signal this tick stream. A single consumer loop below performs
            // the read-store -> reconcile -> yield sequence strictly
            // serially, so two producers firing back-to-back can never race
            // to `continuation.yield` out of order (an in-flight emit
            // reading older state finishing after a newer one). Buffering
            // the ticks at 1 and keeping "newest" coalesces any signals that
            // pile up while an emit is in flight into a single follow-up
            // emit, rather than replaying every intermediate state.
            let (ticks, tickContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let signal: @Sendable () -> Void = { tickContinuation.yield(()) }

            let emitTask = Task {
                for await _ in ticks { await emit() }
            }
            // `setViewing` rides the live socket (a network send). It used
            // to gate the store subscription below, which held the first
            // snapshot — and therefore the first paint of an already-cached
            // conversation — hostage to a network round-trip (or its
            // timeout, when offline). Fire it concurrently instead: the
            // local mirror is the source of truth for what to draw, and
            // viewing scope only affects ephemeral fan-out.
            let viewingTask = Task {
                await engine.setViewing(convoID: convoID)
            }
            let storeTask = Task {
                // The observation delivers the full ordered row set on
                // every change; stash it on the overlay actor so `emit()`
                // (and every non-store tick — streaming tokens, echoes,
                // the staleness sweep) renders from memory instead of
                // re-reading the whole table from SQLite each time.
                for await events in store.eventsStream(convoID: convoID) {
                    await overlay.setEvents(events)
                    signal()
                }
                // The store stream now self-heals observation errors, so a
                // non-cancelled finish here should be impossible — log it
                // un-gated if it ever happens, because it kills live
                // updates for this timeline (blank/frozen panel evidence).
                if !Task.isCancelled {
                    Self.logger.warning("store events stream finished for \(convoID, privacy: .public) — timeline items stream ending")
                }
                continuation.finish()
            }
            let ephemeralTask = Task {
                for await update in engine.ephemerals(convoID: convoID) {
                    await overlay.applyEphemeral(update)
                    signal()
                }
            }
            let activityTask = Task {
                for await update in engine.activities(convoID: convoID) {
                    await overlay.applyActivity(update)
                    signal()
                }
            }
            let toolStreamTask = Task {
                for await update in engine.toolStreams(convoID: convoID) {
                    if await overlay.applyToolStream(update) {
                        // Client-side resync: re-sending `viewing` makes the
                        // server re-emit a full-scrollback sync per active
                        // stream (clients cannot send stream_append).
                        await engine.setViewing(convoID: convoID)
                    }
                    signal()
                }
            }
            let echoTask = Task {
                for await _ in overlay.changes() { signal() }
            }
            // Overlays (streaming + echoes) only get pruned inside
            // `reconcile`, which only runs from `emit()`. Without this, a
            // stalled overlay (e.g. an ephemeral stream that never gets a
            // finalize, or a failed echo nobody retries) sits in the
            // snapshot forever once activity stops, since nothing else
            // triggers another emit. This sweep guarantees a re-emit at
            // least every `sweepInterval` for as long as the stream is
            // being observed, so `reconcile`'s staleness cutoff always gets
            // a chance to run.
            let sweepTask = Task {
                while true {
                    try? await Task.sleep(for: sweepInterval)
                    if Task.isCancelled { break }
                    signal()
                }
            }
            continuation.onTermination = { _ in
                viewingTask.cancel()
                storeTask.cancel()
                ephemeralTask.cancel()
                activityTask.cancel()
                toolStreamTask.cancel()
                echoTask.cancel()
                sweepTask.cancel()
                emitTask.cancel()
                tickContinuation.finish()
                Task { await engine.setViewing(convoID: nil) }
            }
        }
    }

    public func sendText(_ body: String, inReplyTo: String?) async throws {
        if let inReplyTo, let target = Int64(inReplyTo) {
            try await engine.sendOp(.promptReply(convoID: convoID, targetSeq: target, choice: nil, text: body))
            return
        }
        let localID = UUID().uuidString
        await overlay.addEcho(localID: localID, body: body)
        do {
            try await engine.sendOp(.send(convoID: convoID, body: body, localID: localID))
        } catch {
            // Flip the echo to failed rather than leave it stuck in
            // `.sending` forever, and rethrow so the composer surfaces the
            // error and keeps the user's text instead of silently eating it.
            await overlay.markEchoFailed(localID: localID)
            throw error
        }
    }

    public func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
        // A prompt's timeline id is its journal seq. Anything non-numeric
        // (echo ids, streaming ids) must fail loudly — `?? 0` used to send
        // target_seq 0 and attach the answer to the wrong row (bugbot
        // "Invalid prompt ID sends seq zero").
        guard let targetSeq = Int64(promptEventID) else {
            throw JournalChatError.invalidPromptReference(promptEventID)
        }
        try await engine.sendOp(.promptReply(convoID: convoID,
                                             targetSeq: targetSeq,
                                             choice: selectedValues.joined(separator: ", "), text: nil))
    }

    public func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
        try await sendMedia(data, filename: filename, mimeType: mimeType, type: "image", caption: caption)
    }

    public func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
        try await sendMedia(data, filename: filename, mimeType: mimeType, type: "file", caption: caption)
    }

    /// Uploads the bytes to `POST /media` and sends the returned `blob_ref`
    /// as a media `send` op. `type` is the wire kind (`"image"` for
    /// `image/*`, `"file"` otherwise) — the caller (`sendImage`/`sendFile`)
    /// has already made that split. The op's `payload` carries the
    /// filename, content type, byte size and optional caption alongside the
    /// blob ref.
    private func sendMedia(
        _ data: Data, filename: String, mimeType: String, type: String, caption: String?
    ) async throws {
        let blobRef = try await api.uploadMedia(data, contentType: mimeType)
        try await engine.sendOp(.sendMedia(convoID: convoID, type: type, blobRef: blobRef,
                                           name: filename, contentType: mimeType,
                                           size: data.count, caption: caption,
                                           localID: UUID().uuidString))
    }

    public func paginateBackward(requestSize: UInt16) async throws -> Bool {
        let before = try store.minSeq(convoID: convoID)
        let events = try await api.messages(convoID: convoID, beforeSeq: before, limit: Int(requestSize))
        let newOnes = events.filter { before == nil || $0.seq < before! }
        try store.insertHistory(newOnes)
        if let search {
            for event in newOnes {
                let body: String? = switch event.type {
                case JournalEventType.text: event.payload["body"] as? String
                case JournalEventType.toolOutput: event.payload["snippet"] as? String
                // diff → snippet precedence mirrors JournalTimelineMapper,
                // same as the live-sync indexer in JournalSyncEngine.
                case JournalEventType.diff: event.payload["diff"] as? String ?? event.payload["snippet"] as? String
                default: nil
                }
                if let body, !body.isEmpty {
                    try? await search.index(roomID: event.convoID, eventID: String(event.seq),
                                            sender: event.sender, timestamp: event.ts, body: body)
                }
            }
        }
        return !newOnes.isEmpty
    }

    public func sessionStatus() -> AsyncStream<SessionStatusUpdate> {
        engine.sessionStatus(convoID: convoID)
    }

    public func markAsRead() async throws {
        guard let maxSeq = try store.maxSeq(convoID: convoID) else { return }
        do {
            try await engine.sendOp(.readMarker(convoID: convoID, upToSeq: maxSeq))
        } catch JournalSyncError.offline {
            // Best-effort; the next markAsRead after reconnect converges devices.
        }
    }
}
