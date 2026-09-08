import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs the item detail sheet: one item, its comments, and the local
/// outbox of comments/creates still in flight. Writes go through
/// `ItemsSyncing`, which owns the outbox and refetch coalescing — this view
/// model calls `refreshItem` after every mutating action without worrying
/// about de-duping concurrent calls.
@MainActor @Observable
public final class ItemDetailViewModel {
    public let itemID: String
    public private(set) var item: TrackerItem?
    public private(set) var comments: [TrackerComment] = []
    public private(set) var pendingComments: [ItemOutboxRecord] = []
    public var draft = ""
    public var error: String?
    public private(set) var isBusy = false

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?

    public init(itemID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
        self.itemID = itemID; self.store = store; self.api = api; self.sync = sync
    }

    public func start() {
        stop()
        let id = itemID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemStream(id: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.item = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.commentsStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.comments = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemOutboxStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.pendingComments = v }
        })
        // Comments only reach the local cache through a refetch — opening
        // the detail sheet must trigger one, not just rely on whatever the
        // panel last fetched.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.sync.refreshItem(id: id) }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        refreshTask?.cancel(); refreshTask = nil
    }

    public var availableResolutions: [ItemResolution] {
        switch item?.kind {
        case .task: return [.done, .cancelled]
        case .question: return [.answered, .cancelled]
        case .decision: return [.decided, .reversed, .cancelled]
        case nil: return []
        }
    }

    /// Uploads attachments first, then enqueues the comment (localID is
    /// minted here, not by `ItemsSyncing` — the outbox record needs it
    /// before the enqueue call returns so the pending-comments stream can
    /// show it). Draft is cleared on enqueue, not restored on failure: the
    /// outbox holds the text durably and retries on its own.
    public func submitComment(attachments: [(data: Data, name: String, mime: String)]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var uploaded: [TrackerAttachment] = []
        do {
            for a in attachments {
                let ref = try await api.uploadMedia(a.data, contentType: a.mime)
                uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mime, name: a.name, size: Int64(a.data.count)))
            }
        } catch {
            self.error = "Couldn't upload an attachment: \(error.localizedDescription)"
            return
        }
        draft = ""
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: text, attachments: uploaded)
    }

    public func sendVoiceNote(url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { error = "Voice note was empty."; return }
        await submitComment(attachments: [(data, "voice-note.m4a", "audio/mp4")])
    }

    public func close(resolution: ItemResolution, comment: String?) async {
        await run { _ = try await self.api.closeItem(id: self.itemID, resolution: resolution, comment: comment) }
    }

    public func reopen() async {
        await run { _ = try await self.api.reopenItem(id: self.itemID, comment: nil) }
    }

    public func reverse() async { await close(resolution: .reversed, comment: nil) }

    private func run(_ op: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await op(); await sync.refreshItem(id: itemID) }
        catch { self.error = error.localizedDescription }
    }
}
