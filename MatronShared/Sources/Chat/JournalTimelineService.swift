import Foundation
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
                if event.sender == ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String,
                   let index = echoes.firstIndex(where: { $0.body == body }) {
                    echoes.remove(at: index)
                }
            }
            let cutoff = Date().addingTimeInterval(-staleness)
            streaming = streaming.filter { $0.value.updated > cutoff }
            echoes = echoes.filter { $0.created > cutoff }
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
                let events = (try? store.events(convoID: convoID)) ?? []
                await overlay.reconcile(with: events, ownSender: ownSender)
                var items = events.compactMap {
                    JournalTimelineMapper.timelineItem(from: $0, ownSender: ownSender, serverURL: serverURL)
                }
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
            let storeTask = Task {
                await engine.setViewing(convoID: convoID)
                for await _ in store.eventsStream(convoID: convoID) { signal() }
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
        try await engine.sendOp(.promptReply(convoID: convoID,
                                             targetSeq: Int64(promptEventID) ?? 0,
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
                case JournalEventType.toolOutput, JournalEventType.diff: event.payload["snippet"] as? String
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
