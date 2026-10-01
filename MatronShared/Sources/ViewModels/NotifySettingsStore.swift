import Foundation
import os
import MatronJournal
import MatronModels

/// One conversation's notification state as the lists and headers show it.
public struct ConvoNotifyState: Equatable, Sendable {
    /// `nil` = follow the mode.
    public var level: NotifySettings.ConvoLevel?
    /// Only while the mute runs; a lapsed one reads `nil`.
    public var mutedUntil: Date?

    public init(level: NotifySettings.ConvoLevel? = nil, mutedUntil: Date? = nil) {
        self.level = level
        self.mutedUntil = mutedUntil
    }

    /// Nothing from this conversation pushes: the bell-slash.
    public var isSilenced: Bool { level == .silent || mutedUntil != nil }
}

/// The session's notification settings (journal spec 2026-10-01): what the
/// Notifications screen edits and what every conversation row reads for its
/// bell-slash. Reads `GET /notify` on every connect (the live frame has no
/// replay, so one missed while offline is caught there) and applies live
/// `notify` frames as they land. Writes are optimistic: the change shows at
/// once and a failed `PUT` takes back exactly that change.
///
/// Shown state is the journal's last answer (`confirmed`) with the writes
/// still in flight replayed on top, so overlapping writes never roll each
/// other back and a frame or `GET` landing mid-write keeps the user's
/// pending change on screen.
@Observable @MainActor
public final class NotifySettingsStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "notify-settings")

    /// `nil` until the first `GET /notify` answers.
    public private(set) var view: NotifyView?
    /// `nil` until the journal answers; `false` once `GET /notify` 404s — a
    /// journal predating the route, where the screen says so.
    public private(set) var isSupported: Bool?
    /// The last failed write or read, for the screen to show. Cleared by the
    /// next success.
    public private(set) var errorMessage: String?
    /// Re-read when the next running mute ends, so the bell-slash goes away
    /// on time without anything else changing.
    public private(set) var clock: Date

    private let api: any NotifySettingsProviding
    private let updates: @Sendable () -> AsyncStream<NotifySettings>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private let now: @Sendable () -> Date

    private var confirmed: NotifyView?
    private var pending: [(id: Int, change: NotifyChange)] = []
    private var nextWriteID = 0
    /// Bumped whenever `confirmed` takes a newer answer (a live frame or a
    /// `PUT` reply). A `GET` that started before is older news and is
    /// dropped — the `CoordinatorSync` epoch rule.
    private var confirmedEpoch = 0
    private var updatesTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    public init(api: any NotifySettingsProviding,
                updates: @escaping @Sendable () -> AsyncStream<NotifySettings>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.updates = updates
        self.connectionStates = connectionStates
        self.now = now
        self.clock = now()
    }

    public var settings: NotifySettings? { view?.settings }

    /// One conversation's level and running mute, as of `clock`.
    public func state(for convoID: String) -> ConvoNotifyState {
        guard let row = view?.settings.override(for: convoID) else { return ConvoNotifyState() }
        return ConvoNotifyState(level: row.level, mutedUntil: row.isMuted(at: clock) ? row.muteUntil : nil)
    }

    /// The conversations with a level or a running mute, latest change first.
    public var activeOverrides: [NotifySettings.ConvoOverride] {
        (view?.settings.convos ?? []).filter { $0.isActive(at: clock) }
    }

    public func start() {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await settings in stream {
                guard !Task.isCancelled else { return }
                self?.applyLive(settings)
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
    }

    public func stop() {
        updatesTask?.cancel()
        statesTask?.cancel()
        expiryTask?.cancel()
        updatesTask = nil
        statesTask = nil
        expiryTask = nil
        // A `GET` still in flight must not land after this.
        confirmedEpoch += 1
    }

    /// `GET /notify`. A transport failure keeps what is shown.
    public func refresh() async {
        let startEpoch = confirmedEpoch
        do {
            let answer = try await api.notifySettings()
            isSupported = true
            guard confirmedEpoch == startEpoch else {
                Self.logger.debug("dropping a GET /notify answer superseded by a newer one")
                return
            }
            confirmed = answer
            errorMessage = nil
            recompute()
        } catch JournalAPIError.notFound {
            isSupported = false
        } catch {
            Self.logger.warning("GET /notify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Changes

    public func setMode(_ mode: NotifySettings.Mode) async { await apply(.mode(mode)) }

    public func setEvent(_ event: NotifySettings.Event, on: Bool) async {
        guard event != .prompts else { return }
        await apply(.event(event, on))
    }

    public func setDeviceLevel(_ level: NotifyDeviceLevel) async { await apply(.deviceLevel(level)) }

    public func setLevel(_ level: NotifySettings.ConvoLevel?, convoID: String) async {
        await apply(.convoLevel(convoID: convoID, level))
    }

    public func mute(convoID: String, for duration: NotifyMuteDuration, calendar: Calendar = .current) async {
        await apply(.convoMute(convoID: convoID, until: duration.end(from: now(), calendar: calendar)))
    }

    public func unmute(convoID: String) async { await apply(.convoMute(convoID: convoID, until: nil)) }

    public func clearOverride(convoID: String) async { await apply(.clearConvo(convoID: convoID)) }

    /// Shows `change` at once, then `PUT`s it. The answer becomes the new
    /// confirmed state; a failure drops just this change.
    public func apply(_ change: NotifyChange) async {
        let id = nextWriteID
        nextWriteID += 1
        pending.append((id, change))
        recompute()
        do {
            let answer = try await api.updateNotify(change)
            pending.removeAll { $0.id == id }
            confirmed = answer
            confirmedEpoch += 1
            isSupported = true
            errorMessage = nil
        } catch {
            pending.removeAll { $0.id == id }
            errorMessage = "Couldn't save notification settings — \(error.localizedDescription)"
            Self.logger.warning("PUT /notify failed: \(error.localizedDescription, privacy: .public)")
        }
        recompute()
    }

    // MARK: - Internals

    /// A `notify` frame: the synced part only. This device's level stays as
    /// its own `GET`/`PUT` last left it.
    private func applyLive(_ settings: NotifySettings) {
        let deviceLevel = confirmed?.deviceLevel ?? .all
        confirmed = NotifyView(settings: settings, deviceLevel: deviceLevel)
        confirmedEpoch += 1
        isSupported = true
        recompute()
    }

    private func recompute() {
        clock = now()
        view = confirmed.map { base in pending.reduce(base) { $1.change.applied(to: $0) } }
        scheduleExpiry()
    }

    /// Wakes when the soonest running mute ends and moves `clock` past it.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        let ends = (view?.settings.convos ?? []).compactMap(\.muteUntil).filter { $0 > clock }
        guard let next = ends.min() else { return }
        let delay = next.timeIntervalSince(clock)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}
