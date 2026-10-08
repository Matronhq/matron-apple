import Foundation
import os
import Observation
import MatronJournal
import MatronModels

/// The user's journal settings (`GET` / `PATCH /settings`): today only the
/// "Send things I need to read to For you" switch. Reads `GET /settings` on
/// every connect (the live frame has no replay, so one missed while offline
/// is caught there) and applies live `settings` control frames as they land.
/// A write shows at once; a failed `PATCH` puts the switch back. Mirrors
/// `NotifySettingsStore`, without its overlapping-writes replay: there is
/// one switch, so the newest write simply wins.
@Observable @MainActor
public final class UserSettingsStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "user-settings")

    /// `nil` until the first `GET /settings` answers.
    public private(set) var settings: UserSettings?
    /// `nil` until the journal answers; `false` once `GET /settings` 404s —
    /// a journal predating the route, where the settings screens hide the
    /// switch.
    public private(set) var isSupported: Bool?
    /// The last failed write, for the screen to show. Cleared by the next
    /// success.
    public private(set) var errorMessage: String?

    /// The switch's words, in one place so the iPhone and the Mac say the
    /// same thing.
    public static let noticesTitle = "Send things I need to read to For you"
    public static let noticesFooter = "Agents file things you should read as items with a Seen button, instead of leaving them in chat."

    /// Whether the settings screens show the switch at all.
    public var showsNoticesSwitch: Bool { isSupported != false && settings != nil }

    private let api: any UserSettingsProviding
    private let updates: @Sendable () -> AsyncStream<UserSettings>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    /// Bumped whenever `settings` takes a newer answer: a live frame, a
    /// write, or `stop()`. A `GET` applies its answer — or its 404 — only
    /// when the epoch is unchanged since it started; otherwise it is older
    /// news and is dropped (the `NotifySettingsStore` epoch rule).
    private var epoch = 0
    /// `PATCH`es still in flight, and how many have landed (either way).
    /// A `GET` that answers while a write is out, or after one landed
    /// since it started, may predate that write on the journal, so it
    /// never replaces the switch the user just flipped.
    private var writesInFlight = 0
    private var writesLanded = 0
    private var updatesTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?

    public init(api: any UserSettingsProviding,
                updates: @escaping @Sendable () -> AsyncStream<UserSettings>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api
        self.updates = updates
        self.connectionStates = connectionStates
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
        updatesTask = nil
        statesTask = nil
        // A `GET` still in flight must not land after this.
        epoch += 1
    }

    /// `GET /settings`. A transport failure keeps what is shown. The answer
    /// (or a 404) lands only if no write or live frame has come in since
    /// the request started and no write is still in flight.
    public func refresh() async {
        let start = (epoch: epoch, writesLanded: writesLanded)
        do {
            let answer = try await api.userSettings()
            guard isCurrent(since: start) else {
                Self.logger.debug("dropping a GET /settings answer superseded by a newer one")
                return
            }
            isSupported = true
            errorMessage = nil
            settings = answer
        } catch JournalAPIError.notFound {
            guard isCurrent(since: start) else {
                Self.logger.debug("dropping a GET /settings 404 superseded by a newer answer")
                return
            }
            isSupported = false
        } catch {
            Self.logger.warning("GET /settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The For you switch. Shows the change at once, then `PATCH`es it; a
    /// failure puts back what the journal last said.
    public func setNotices(_ on: Bool) async {
        let before = settings ?? .defaults
        guard before.notices != on else { return }
        var shown = before
        shown.notices = on
        settings = shown
        epoch += 1
        let writeEpoch = epoch
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            writesLanded += 1
        }
        do {
            let answer = try await api.updateUserSettings(notices: on)
            isSupported = true
            errorMessage = nil
            // A newer write or frame landed meanwhile: it is the user's or
            // the journal's latest word, so this answer does not override it.
            guard epoch == writeEpoch else { return }
            settings = answer
        } catch {
            errorMessage = "Couldn't save the setting — \(error.localizedDescription)"
            Self.logger.warning("PATCH /settings failed: \(error.localizedDescription, privacy: .public)")
            guard epoch == writeEpoch else { return }
            settings = before
        }
    }

    private func isCurrent(since start: (epoch: Int, writesLanded: Int)) -> Bool {
        epoch == start.epoch && writesLanded == start.writesLanded && writesInFlight == 0
    }

    private func applyLive(_ settings: UserSettings) {
        self.settings = settings
        epoch += 1
        isSupported = true
        // The journal's word is in: a failed write's message is stale now.
        errorMessage = nil
    }
}
