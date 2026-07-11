import Foundation
import MatronJournal
import MatronModels
import MatronSearch

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
    private let overlay = OverlayState()

    public init(
        convoID: String, store: JournalStore, engine: JournalSyncEngine,
        api: JournalAPI, session: UserSession, search: (any SearchService)? = nil
    ) {
        self.convoID = convoID
        self.store = store
        self.engine = engine
        self.api = api
        self.ownSender = "user:\(session.userID)"
        self.search = search
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
        struct Echo { let localID: String; let body: String; let created: Date }
        private(set) var streaming: [String: (text: String, updated: Date)] = [:]
        private(set) var echoes: [Echo] = []
        private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

        func applyEphemeral(_ update: EphemeralUpdate) {
            let current = streaming[update.messageRef]?.text ?? ""
            let text = update.replaceText ?? (current + (update.textDelta ?? ""))
            streaming[update.messageRef] = (text, Date())
        }

        func reconcile(with events: [JournalEvent], ownSender: String) {
            for event in events {
                if let ref = event.payload["message_ref"] as? String {
                    streaming.removeValue(forKey: ref)
                }
                if event.sender == ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String,
                   let index = echoes.firstIndex(where: { $0.body == body }) {
                    echoes.remove(at: index)
                }
            }
            let cutoff = Date().addingTimeInterval(-30)
            streaming = streaming.filter { $0.value.updated > cutoff }
            echoes = echoes.filter { $0.created > Date().addingTimeInterval(-30) }
        }

        func addEcho(localID: String, body: String) {
            echoes.append(Echo(localID: localID, body: body, created: Date()))
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
                                              isOwn: true, sendState: .sending))
                }
                continuation.yield(items)
            }
            let storeTask = Task {
                await engine.setViewing(convoID: convoID)
                for await _ in store.eventsStream(convoID: convoID) { await emit() }
                continuation.finish()
            }
            let ephemeralTask = Task {
                for await update in engine.ephemerals(convoID: convoID) {
                    await overlay.applyEphemeral(update)
                    await emit()
                }
            }
            let echoTask = Task {
                for await _ in overlay.changes() { await emit() }
            }
            continuation.onTermination = { _ in
                storeTask.cancel()
                ephemeralTask.cancel()
                echoTask.cancel()
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
        try await engine.sendOp(.send(convoID: convoID, body: body, localID: localID))
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
