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
        overlayStaleness: Duration = .seconds(30), sweepInterval: Duration = .seconds(10)
    ) {
        self.convoID = convoID
        self.store = store
        self.engine = engine
        self.api = api
        self.ownSender = "user:\(session.userID)"
        self.search = search
        self.overlay = OverlayState(staleness: overlayStaleness.timeInterval)
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

        init(staleness: TimeInterval) {
            self.staleness = staleness
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

        func reconcile(with events: [JournalEvent], ownSender: String) {
            for event in events {
                if let ref = event.payload["message_ref"] as? String {
                    streaming.removeValue(forKey: ref)
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
                if event.sender == ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String,
                   let index = echoes.firstIndex(where: { $0.body == body && !$0.failed })
                            ?? echoes.firstIndex(where: { $0.body == body }) {
                    echoes.remove(at: index)
                }
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

    public func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        throw JournalChatError.mediaNotSupported
    }

    public func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        throw JournalChatError.mediaNotSupported
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

    public func markAsRead() async throws {
        guard let maxSeq = try store.maxSeq(convoID: convoID) else { return }
        do {
            try await engine.sendOp(.readMarker(convoID: convoID, upToSeq: maxSeq))
        } catch JournalSyncError.offline {
            // Best-effort; the next markAsRead after reconnect converges devices.
        }
    }
}
