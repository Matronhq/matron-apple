import Foundation
import os
import MatronModels
import MatronEvents

/// Keeps the local tracker cache fresh (spec: Apps → ItemsSync). Three
/// triggers refetch: a marker event for an item (refetch that item), a
/// panel open / explicit refresh (since-watermark list), and a reconnect
/// (same). An item outbox holds comments and creates written offline and
/// drains whenever the connection is running.
public actor ItemsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "items-sync")
    private let api: any ItemsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// Drain re-entrancy: a `while` loop rather than a plain guard so an
    /// enqueue that lands mid-drain (e.g. `enqueueComment` firing while a
    /// reconnect drain is in flight) is never lost — it sets `drainRequested`
    /// and the running drain loops once more before releasing `draining`.
    private var draining = false
    private var drainRequested = false
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(api: any ItemsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
    }

    public func supportedStream() -> AsyncStream<Bool> {
        AsyncStream { c in
            let id = UUID()
            supportedContinuations[id] = c
            c.yield(isSupported)
            c.onTermination = { _ in Task { await self.dropSupported(id) } }
        }
    }
    private func dropSupported(_ id: UUID) { supportedContinuations.removeValue(forKey: id) }
    private func setSupported(_ v: Bool) {
        guard v != isSupported else { return }
        isSupported = v
        for c in supportedContinuations.values { c.yield(v) }
    }

    public func start() {
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (_, marker) in markers {
                guard let self else { return }
                await self.refreshItem(id: marker.itemID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if case .running = state {
                    await self.setSupported(true)   // re-probe: the next refresh decides
                    await self.refresh(scope: .all)
                    await self.drainOutbox()
                }
            }
        }
        Task { [weak self] in await self?.drainOutbox() }
    }

    public func stop() {
        markerTask?.cancel(); markerTask = nil
        stateTask?.cancel(); stateTask = nil
    }

    public func refresh(scope: ItemsScope) async {
        var query = ItemsListQuery()
        query.limit = 500
        query.sort = .updated
        if case .convo(let id) = scope { query.convoID = id }
        if let mark = try? store.itemsMaxUpdatedAt() { query.since = mark.addingTimeInterval(-1) }
        do {
            repeat {
                let page = try await api.listItems(query)
                try store.upsertItems(page.items)
                query.cursor = page.nextCursor
            } while query.cursor != nil
            setSupported(true)
        } catch JournalAPIError.notFound {
            setSupported(false)
        } catch {
            Self.logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshItem(id: String) async {
        do {
            let r = try await api.item(id: id)
            try store.upsertItems([r.item])
            try store.replaceComments(itemID: id, r.comments)
            setSupported(true)
        } catch {
            Self.logger.warning("item refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct CommentPayload: Codable { var body: String; var attachments: [TrackerAttachment] }
    private struct CreatePayload: Codable { var kind: String; var title: String; var body: String; var convoID: String; var attachments: [TrackerAttachment] }

    public func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {
        let payload = (try? String(data: JSONEncoder().encode(CommentPayload(body: body, attachments: attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: itemID, op: "comment", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueComment insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await drainOutbox()
    }

    public func enqueueCreate(localID: String, _ new: NewItem) async {
        let payload = (try? String(data: JSONEncoder().encode(CreatePayload(kind: new.kind.rawValue, title: new.title, body: new.body, convoID: new.convoID, attachments: new.attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: nil, op: "create", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueCreate insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await drainOutbox()
    }

    public func drainOutbox() async {
        guard !draining else { drainRequested = true; return }
        draining = true
        defer { draining = false }
        repeat {
            drainRequested = false
            // `drainOnce` returning `false` means it stopped early on a
            // failure (still offline, most likely) — don't immediately
            // loop even if another caller set `drainRequested` while we
            // were mid-attempt (e.g. the redundant kick from `start()`
            // racing this same first attempt): the failing row stays
            // queued and the NEXT real trigger (reconnect, next enqueue)
            // retries it, rather than hammering a dead network in a tight
            // loop and double-counting attempts. Only a clean pass (no
            // failure) honors a same-cycle re-request, to pick up rows
            // inserted after `rows` was read.
            guard await drainOnce() else { break }
        } while drainRequested
    }

    /// Returns `false` if it stopped early on a failure (offline), `true`
    /// if every pending row was attempted without error.
    private func drainOnce() async -> Bool {
        guard let rows = try? store.itemOutboxPending() else { return true }
        for row in rows {
            do {
                switch row.op {
                case "comment":
                    guard let itemID = row.itemID, let data = row.payloadJSON.data(using: .utf8),
                          let p = try? JSONDecoder().decode(CommentPayload.self, from: data) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let r = try await api.commentItem(id: itemID, body: p.body, attachments: p.attachments, idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([r.item])
                    await refreshItem(id: itemID)
                case "create":
                    guard let data = row.payloadJSON.data(using: .utf8), let p = try? JSONDecoder().decode(CreatePayload.self, from: data),
                          let kind = ItemKind(rawValue: p.kind) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let item = try await api.createItem(NewItem(kind: kind, title: p.title, body: p.body, attachments: p.attachments, convoID: p.convoID), idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([item])
                default:
                    try store.itemOutboxDelete(localID: row.localID)
                }
            } catch {
                do {
                    try store.itemOutboxMarkAttempt(localID: row.localID, error: error.localizedDescription)
                } catch let markError {
                    Self.logger.error("itemOutboxMarkAttempt failed for \(row.localID, privacy: .public): \(markError.localizedDescription, privacy: .public)")
                }
                // Stop at the first failure: the rest will fail the same way
                // (offline) and order matters for comments on one item.
                return false
            }
        }
        return true
    }
}
