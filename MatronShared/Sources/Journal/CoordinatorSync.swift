import Foundation
import os
import MatronModels

/// Keeps this device's cached Coordinator (`CoordinatorSetting`) in step
/// with the journal's (Coordinator redesign §3a). Reads: `GET /coordinator`
/// on start, the `hello_ok` field on every connect (`.snapshot`), and live
/// `coordinator` events. Writes: `set(_:)`, the user's own pick or clear.
/// The cache is what every view reads, so nothing else writes it.
///
/// Reconnect-vs-backlog ordering (a reconnect's fresh `.snapshot` landing
/// before the backlog's own replayed `assigned`/`released` events) is
/// resolved upstream, in `JournalSyncEngine.publishCoordinatorEvent`, by
/// comparing each event's journal `seq` against the hello's head seq — not
/// here. An earlier version of this actor tried to resolve it locally by
/// comparing cached values, which also dropped genuine live `assigned`
/// events (a user with no Coordinator picking one elsewhere arrives as a
/// bare `assigned`, with nothing to contradict); that approach is gone.
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

    /// Bumped by every applied live update (`apply(_:)`) and by `set(_:)`.
    /// `refresh()` snapshots this before its `GET` and checks it again after:
    /// if it moved, a live update landed while the GET was in flight and is
    /// more authoritative than that GET's answer, which is dropped instead
    /// of applied. This guards an actor-reentrancy hazard: `start()` creates
    /// the update-stream subscription (which can replay a fresher snapshot
    /// immediately) and then suspends inside `refresh()`'s `GET` — without
    /// this check, a slow/stale GET answer that resolves afterward can
    /// clobber what the live subscription already correctly set.
    private var epoch = 0

    public init(api: any CoordinatorProviding, setting: CoordinatorSetting,
                updates: @escaping @Sendable () -> AsyncStream<CoordinatorUpdate>) {
        self.api = api
        self.setting = setting
        self.updates = updates
    }

    deinit {
        updatesTask?.cancel()
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
        // Invalidate any `refresh()` still in flight so a GET answer that
        // resolves after `stop()` is dropped rather than resurrecting state
        // once the caller believes the sync has stopped.
        epoch += 1
    }

    /// `GET /coordinator` and reconcile. A transport failure leaves the cache
    /// as it is; the next connect's hello reconciles instead.
    public func refresh() async {
        let startEpoch = epoch
        do {
            let journal = try await api.coordinator()
            // Answered at all: the route exists, even if the value is stale.
            isSupported = true
            guard epoch == startEpoch else {
                Self.logger.debug("dropping a GET /coordinator answer superseded by a live update")
                return
            }
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
            epoch += 1
            return
        }
        do {
            let stored = try await api.setCoordinator(convoID)
            setting.convoID = stored
            setting.migrated = true
            epoch += 1
        } catch JournalAPIError.notFound where isSupported == nil {
            // We never learned whether this journal has the route — the
            // startup GET failed transport-side rather than 404ing — so a
            // 404 here reads as "no route" as plausibly as "convo not
            // owned". Treat it as the former: the user's pick still has to
            // land somewhere, and future calls skip the PUT outright.
            isSupported = false
            setting.convoID = convoID
            epoch += 1
        }
    }

    private func apply(_ update: CoordinatorUpdate) async {
        epoch += 1
        switch update {
        case .snapshot(let journal):
            isSupported = true
            await reconcile(journal: journal)
        case .assigned(let convoID):
            isSupported = true
            setting.convoID = convoID
            setting.migrated = true
        case .released(let convoID):
            isSupported = true
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
            // Guards the same reentrancy hazard as `refresh()`: this PUT
            // suspends the actor, so a live `apply(_:)` (which bumps
            // `epoch`) can land and set a fresher cache while it's in
            // flight. That answer — success or `notFound` — is then stale
            // and must not overwrite what the live update already set.
            // `migrated` is already `true` in that case, set by `apply`.
            let startEpoch = epoch
            do {
                let stored = try await api.setCoordinator(cached)
                guard epoch == startEpoch else {
                    Self.logger.debug("dropping a coordinator migration PUT answer superseded by a live update")
                    return
                }
                setting.convoID = stored
                setting.migrated = true
            } catch JournalAPIError.notFound {
                guard epoch == startEpoch else {
                    Self.logger.debug("dropping a coordinator migration 404 superseded by a live update")
                    return
                }
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
