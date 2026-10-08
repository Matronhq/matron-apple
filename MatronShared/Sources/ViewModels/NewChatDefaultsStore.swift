import Foundation
import os
import MatronJournal
import MatronModels

/// The user's default model and effort for new chats (journal `GET`/`PUT
/// /defaults`): what Settings → New chats edits. A port of matron-web's
/// `MatronJournalClient` defaults logic, so the three apps behave alike.
///
/// Reads `GET /defaults` on every connect (the live `defaults` frame has no
/// replay, so one missed while offline is caught there) and applies live
/// frames as they land.
///
/// Shown state is the journal's latest value (`server`: the last `GET`,
/// frame or `PUT` answer) with the picks not yet stored laid on top. Saves
/// are single-flight per key: at most one `PUT` per key is in flight, and a
/// pick made meanwhile only replaces the waiting value. When the `PUT`
/// settles its answer applies to its own key only, and if a newer pick is
/// waiting, one more `PUT` sends it — so an older answer can never land over
/// a newer pick, on screen or in the journal. A failed `PUT` drops its pick
/// (the key goes back to the journal's latest value, with an error) and any
/// newer pick waiting is still sent.
///
/// A save error belongs to its key and stays until that key's next pick or
/// successful save — a read or frame landing after the picker snapped back
/// must not hide it. A load error stays until the next successful read,
/// frame or save.
@Observable @MainActor
public final class NewChatDefaultsStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "new-chat-defaults")

    /// `nil` until the first `GET /defaults` answers.
    public private(set) var defaults: NewChatDefaults?
    /// `nil` until the journal answers; `false` once `GET /defaults` 404s —
    /// a journal predating per-user defaults, where the screen says so.
    public private(set) var isSupported: Bool?
    /// What failed, for the screen to show: each key's failed save, then a
    /// failed read. `nil` when nothing has.
    public var errorMessage: String? {
        let messages = NewChatDefaults.Key.allCases.compactMap { saveErrors[$0] } + [loadError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private let api: any NewChatDefaultsProviding
    private let updates: @Sendable () -> AsyncStream<NewChatDefaults>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>

    /// The journal's latest value: the last `GET`, frame or `PUT` answer.
    private var server: NewChatDefaults?
    /// Picks not stored yet, per key (`.some(nil)` = Box default): shown on
    /// top of `server` until their key's `PUT` answers.
    private var pending: [NewChatDefaults.Key: String?] = [:]
    /// Keys with a `PUT` loop running.
    private var saving: Set<NewChatDefaults.Key> = []
    /// A failed save, per key: cleared only by that key's next pick or
    /// successful save.
    private var saveErrors: [NewChatDefaults.Key: String] = [:]
    /// A failed read: cleared by the next successful read, frame or save.
    private var loadError: String?
    /// Bumped by every `GET` sent, pick, frame and `PUT` answer: a `GET`
    /// answer from before the latest of them is older news and is dropped.
    private var seq = 0
    /// Bumped by `stop()`: a `PUT` loop from before it ends.
    private var generation = 0
    private var updatesTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?

    public init(api: any NewChatDefaultsProviding,
                updates: @escaping @Sendable () -> AsyncStream<NewChatDefaults>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api
        self.updates = updates
        self.connectionStates = connectionStates
    }

    public func start() {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await defaults in stream {
                guard !Task.isCancelled else { return }
                self?.applyLive(defaults)
            }
        }
        // The state stream replays `.running` once caught up, cold start
        // included, so this is also the first read.
        let states = connectionStates()
        statesTask = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .running = state { await self?.refresh() }
            }
        }
        // Picks kept across a `stop()` are sent now. A key whose old `PUT`
        // is still in flight is picked up when that loop ends (`drain`).
        for key in NewChatDefaults.Key.allCases where pending[key] != nil && !saving.contains(key) {
            Task { [weak self] in await self?.drain(key) }
        }
    }

    /// Stops listening. Picks not saved yet are kept, still shown, and sent
    /// on the next `start()`; an answer to a `PUT` sent before this is
    /// dropped (its pick stays waiting and is sent again).
    public func stop() {
        updatesTask?.cancel()
        statesTask?.cancel()
        updatesTask = nil
        statesTask = nil
        // A `GET` or `PUT` still in flight must not land after this.
        seq += 1
        generation += 1
    }

    /// `GET /defaults`. A 404 means the journal predates per-user defaults;
    /// any other failure keeps what is shown and says so.
    public func refresh() async {
        seq += 1
        let sentSeq = seq
        do {
            let answer = try await api.newChatDefaults()
            guard seq == sentSeq else {
                Self.logger.debug("dropping a GET /defaults answer superseded by newer news")
                return
            }
            server = answer
            isSupported = true
            loadError = nil
            show()
        } catch JournalAPIError.notFound {
            guard seq == sentSeq else { return }
            isSupported = false
            loadError = nil
        } catch {
            guard seq == sentSeq else { return }
            loadError = "Couldn't load the defaults: \(error.localizedDescription)"
            Self.logger.warning("GET /defaults failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Picks `value` (`nil` = Box default) for `key`: shown at once, then
    /// `PUT`. Nothing happens before the first read has answered. While the
    /// key already has a `PUT` in flight this only replaces the waiting
    /// value and returns; otherwise it returns once the key's last `PUT`
    /// has settled.
    public func set(_ key: NewChatDefaults.Key, to value: String?) async {
        guard server != nil, defaults?[key] != value else { return }
        // A read already in flight predates this pick: drop its answer.
        seq += 1
        pending[key] = .some(value)
        saveErrors[key] = nil
        show()
        await drain(key)
    }

    // MARK: - Internals

    /// One key's `PUT` loop: sends the waiting pick, applies the answer, and
    /// goes round again while a newer pick waits. At most one per key.
    private func drain(_ key: NewChatDefaults.Key) async {
        guard !saving.contains(key) else { return }
        saving.insert(key)
        let loopGeneration = generation
        sending: while generation == loopGeneration, let desired = pending[key] {
            do {
                let stored = try await api.setNewChatDefault(key, to: desired)
                // An answer from before a `stop()` is not applied.
                guard generation == loopGeneration else { break sending }
                seq += 1
                // The answer's own key, in the journal's spelling (trimmed,
                // lowercased). Its other key is never newer than a frame
                // already applied, so it is left alone.
                server?[key] = stored[key]
                if pending[key] == .some(desired) { pending.removeValue(forKey: key) }
                saveErrors[key] = nil
                loadError = nil
                show()
            } catch {
                guard generation == loopGeneration else { break sending }
                // Drop the failed pick; a newer one waiting is sent next.
                if pending[key] == .some(desired) { pending.removeValue(forKey: key) }
                saveErrors[key] = "Couldn't save the \(key.errorName): \(error.localizedDescription)"
                Self.logger.warning("PUT /defaults failed: \(error.localizedDescription, privacy: .public)")
                show()
            }
        }
        saving.remove(key)
        // Left on a stale generation (a `stop()` while the `PUT` was in
        // flight): a pick waiting now — made after a `start()`, or kept
        // across the stop — would otherwise never be sent.
        if generation != loopGeneration, pending[key] != nil, updatesTask != nil {
            await drain(key)
        }
    }

    /// A live `defaults` frame: the full new state from any device or agent,
    /// including the echo of this device's own save. Picks still waiting stay
    /// on top until their own `PUT` answers. A newer full state, so it ends
    /// a load error; a save error stays with its key.
    private func applyLive(_ answer: NewChatDefaults) {
        seq += 1
        server = answer
        isSupported = true
        loadError = nil
        show()
    }

    /// The journal's latest value with the waiting picks on top.
    private func show() {
        guard var value = server else { return }
        for (key, pick) in pending { value[key] = pick }
        defaults = value
    }
}
