import Foundation
import MatrixRustSDK
import MatronModels
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

    public init(
        provider: ClientProvider,
        session: UserSession,
        sync: MatronSync.SyncService,
        roomID: String
    ) {
        self.provider = provider
        self.session = session
        self.sync = sync
        self.roomID = roomID
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
            let task = Task { [provider, session, sync, roomID] in
                do {
                    try await sync.waitUntilReady()
                    let client = try await provider.client(for: session)
                    guard let room = try client.getRoom(roomId: roomID) else {
                        continuation.finish(throwing: TimelineServiceError.roomNotFound(roomID))
                        return
                    }
                    let timeline = try await room.timeline()
                    let listener = TimelineSnapshotListener(continuation: continuation)
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

    public func sendText(_ body: String) async throws {
        let timeline = try await timeline()
        let content = messageEventContentFromMarkdown(md: body)
        _ = try await timeline.send(msg: content)
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

    public func paginateBackward(requestSize: UInt16) async throws {
        let timeline = try await timeline()
        _ = try await timeline.paginateBackwards(numEvents: requestSize)
    }

    public func markAsRead() async throws {
        let timeline = try await timeline()
        try await timeline.markAsRead(receiptType: .read)
    }

    // MARK: - Helpers

    /// Resolves a fresh `Timeline` handle for each operation. The SDK
    /// returns the same per-room handle internally; we don't cache it
    /// here because the cached `Client` already owns lifecycle.
    ///
    /// QA finding #8: relying on the SDK's per-room handle identity is
    /// fragile across SDK bumps — caching here would risk stop()/start()
    /// lifecycle issues with a reused handle that the SDK might tear
    /// down internally. Re-resolving each call is the conservative
    /// choice while we're pinned to v26 (26.04.01). When bumping the
    /// SDK, double-check `room.timeline()`'s identity contract before
    /// considering a cache.
    private func timeline() async throws -> Timeline {
        let client = try await provider.client(for: session)
        guard let room = try client.getRoom(roomId: roomID) else {
            throw TimelineServiceError.roomNotFound(roomID)
        }
        return try await room.timeline()
    }
}

public enum TimelineServiceError: Error, Equatable, Sendable {
    case roomNotFound(String)
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

// MARK: - Diff listener

/// Walks `MatrixRustSDK.TimelineDiff` updates and rebuilds an ordered
/// snapshot keyed by `TimelineUniqueId.id`. The same logic is mirrored
/// by `SnapshotApplier` in `TimelineDiffApplicationTests` so the
/// production switch-statement is regression-protected without standing
/// up a real SDK.
final class TimelineSnapshotListener: TimelineListener, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation

    /// Maintains the current ordered snapshot. Items are keyed by their
    /// stable id (event id once the homeserver has acked, transaction id
    /// before).
    private var byID: [String: TimelineItem] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    /// `isOwn` is sourced from `EventTimelineItem.isOwn` — the SDK already
    /// knows which events came from us, so we don't need to thread the
    /// user ID through here. (Earlier drafts stored `myID` for a manual
    /// comparison; the property was unused and has been removed.)
    init(continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation) {
        self.continuation = continuation
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
        let snapshot: [TimelineItem] = {
            lock.lock()
            defer { lock.unlock() }
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
        continuation.yield(snapshot)
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
        let kind = mapContent(ev.content)
        let sendState: TimelineItem.SendState = mapSendState(ev.localSendState)
        return TimelineItem(
            id: id,
            sender: ev.sender,
            timestamp: ts,
            kind: kind,
            isOwn: ev.isOwn,
            sendState: sendState
        )
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
            _ = fallbackBody
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
