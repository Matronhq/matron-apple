import Foundation
import os
import MatronModels

/// Keeps this device's cached Coordinator (`CoordinatorSetting`) in step
/// with the journal's (Coordinator redesign §3a). Reads: `GET /coordinator`
/// on start, the `hello_ok` field on every connect (`.snapshot`), and live
/// `coordinator` events. Writes: `set(_:)`, the user's own pick or clear.
/// The cache is what every view reads, so nothing else writes it.
public actor CoordinatorSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "coordinator-sync")

    private let api: any CoordinatorProviding
    private let setting: CoordinatorSetting
    private let updates: @Sendable () -> AsyncStream<CoordinatorUpdate>
    private var updatesTask: Task<Void, Never>?

    /// `nil` until the journal answers; `false` once `GET /coordinator`
    /// 404s — a journal predating the route, where the cache is the only
    /// store and `set(_:)` writes it alone.
    public private(set) var isSupported: Bool?

    /// The cache value as of the most recent `.snapshot` delivered through
    /// the update stream (a fresh reconnect hello) — armed only by that
    /// case, never by `refresh()`'s plain `GET`. Reconnect ordering (Task 2
    /// review, minor 1) means the hello's `.snapshot(current)` publishes
    /// *before* the backlog's replayed `assigned`/`released` events; those
    /// stale events must not be allowed to flicker the cache away from what
    /// the snapshot just established. `hasSnapshotFloor` distinguishes "no
    /// snapshot seen yet" (guard off, e.g. `test_liveEvents_followTheRole`'s
    /// steady-state live events) from "snapshot said nil" (guard on).
    private var hasSnapshotFloor = false
    private var snapshotFloorConvoID: String?

    public init(api: any CoordinatorProviding, setting: CoordinatorSetting,
                updates: @escaping @Sendable () -> AsyncStream<CoordinatorUpdate>) {
        self.api = api
        self.setting = setting
        self.updates = updates
    }

    public func start() async {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { return }
                await self?.apply(update)
            }
        }
        await refresh()
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// `GET /coordinator` and reconcile. A transport failure leaves the cache
    /// as it is; the next connect's hello reconciles instead.
    public func refresh() async {
        do {
            let journal = try await api.coordinator()
            isSupported = true
            await reconcile(journal: journal)
        } catch JournalAPIError.notFound {
            isSupported = false
        } catch {
            Self.logger.warning("GET /coordinator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user's pick or clear (Settings, choosers, the panel's empty
    /// state). The journal first; the cache follows its answer, so a failed
    /// `PUT` changes nothing locally and the error reaches the caller.
    public func set(_ convoID: String?) async throws {
        if isSupported == false {
            setting.convoID = convoID
            return
        }
        let stored = try await api.setCoordinator(convoID)
        setting.convoID = stored
        setting.migrated = true
    }

    private func apply(_ update: CoordinatorUpdate) async {
        switch update {
        case .snapshot(let journal):
            isSupported = true
            await reconcile(journal: journal)
            hasSnapshotFloor = true
            snapshotFloorConvoID = setting.convoID
        case .assigned(let convoID):
            if hasSnapshotFloor, snapshotFloorConvoID == setting.convoID, convoID != setting.convoID {
                // A backlog replay racing the fresh hello snapshot: the
                // snapshot already reflects the journal's current truth, so
                // a stale assigned for a different id is dropped rather
                // than flickering the cache away from it. Any subsequent
                // real change (a matching release, another snapshot, a
                // local `set(_:)`) moves the cache off the floor and this
                // guard stops applying.
                Self.logger.debug("ignoring stale coordinator 'assigned' contradicting the latest snapshot")
                return
            }
            setting.convoID = convoID
            setting.migrated = true
        case .released(let convoID):
            if setting.convoID == convoID { setting.convoID = nil }
            setting.migrated = true
        }
    }

    private func reconcile(journal: String?) async {
        switch CoordinatorSetting.reconcile(journal: journal, cached: setting.convoID, migrated: setting.migrated) {
        case .adopt(let id):
            setting.convoID = id
            setting.migrated = true
        case .push(let cached):
            do {
                setting.convoID = try await api.setCoordinator(cached)
                setting.migrated = true
            } catch JournalAPIError.notFound {
                // The cached chat is gone or not this user's: nothing to carry over.
                setting.convoID = nil
                setting.migrated = true
            } catch {
                // Stays unmigrated: the next hello tries again.
                Self.logger.warning("coordinator migration PUT failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
