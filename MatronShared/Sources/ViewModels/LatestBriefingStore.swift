import Foundation
import os
import MatronJournal
import MatronModels

/// The Coordinator's latest briefing and the state of the user's last ask
/// for a new one (journal "Coordinator briefings"): what the "Latest
/// briefing" card at the top of Projects draws, on both apps. One per
/// signed-in session, like `NotifySettingsStore`: reads `GET
/// /briefings/latest` on every connect (the live frame has no replay) and
/// again on every `briefing` frame, which is an invalidation signal only.
/// Also re-reads when a pending refresh's `expires_at` passes — the journal
/// sends no frame for a timeout — and wakes when the refresh cooldown ends so
/// the button comes back on its own.
@Observable @MainActor
public final class LatestBriefingStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "latest-briefing")

    /// Fallback cooldown after a 429 that named no `retry_at`: the
    /// journal's own two minutes.
    public static let fallbackCooldown: TimeInterval = 120
    /// Re-read this often while the journal still calls a refresh pending
    /// after its `expires_at` (this device's clock ahead of the journal's).
    public static let expiredRecheck: TimeInterval = 30

    /// `nil` until the first `GET` answers.
    public private(set) var latest: LatestBriefing?
    /// `nil` until the journal answers; `false` once `GET /briefings/latest`
    /// 404s — a journal predating briefings, where the card hides.
    public private(set) var isSupported: Bool?
    /// A `POST /briefings/refresh` is in flight.
    public private(set) var isAsking = false
    /// Why the last ask failed, for the card's footnote. Cleared by the
    /// next ask and when a new briefing lands.
    public private(set) var notice: String?
    /// Moves on when a cooldown or a pending refresh runs out, so the card
    /// re-renders without anything else changing.
    public private(set) var clock: Date

    private let api: any BriefingsProviding
    private let updates: @Sendable () -> AsyncStream<BriefingSignal>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private let now: @Sendable () -> Date
    private let expiryGrace: TimeInterval

    /// A 429's `retry_at`, until it passes.
    private var rateLimitedUntil: Date?
    /// Every `GET` and `POST` takes the next number as it starts. An answer
    /// is applied only if its request started after the one last applied,
    /// so an older answer landing late (a `202` from an ask that a
    /// `published` frame's re-read overtook, say) never overwrites a newer
    /// one, and a newer one is never dropped for landing second.
    private var nextRequest = 0
    /// The number of the request whose answer `latest` holds; `stop()`
    /// moves it past every request in flight.
    private var appliedRequest = -1
    private var updatesTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    /// - Parameter expiryGrace: how long after a pending refresh's
    ///   `expires_at` to re-read, so the journal has called it timed out.
    public init(api: any BriefingsProviding,
                updates: @escaping @Sendable () -> AsyncStream<BriefingSignal>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>,
                now: @escaping @Sendable () -> Date = { Date() },
                expiryGrace: TimeInterval = 2) {
        self.api = api
        self.updates = updates
        self.connectionStates = connectionStates
        self.now = now
        self.expiryGrace = expiryGrace
        self.clock = now()
    }

    /// The latest briefing, if there is one.
    public var briefing: Briefing? { latest?.briefing }

    /// When the next ask may go: the later of the journal's
    /// `next_refresh_at` and a 429's `retry_at`.
    public var cooldownUntil: Date? {
        [latest?.nextRefreshAt, rateLimitedUntil].compactMap { $0 }.max()
    }

    /// What the card draws, or `nil` for no card: a journal without
    /// briefings, no Coordinator, or nothing read yet.
    public var cardModel: BriefingCardModel? {
        guard isSupported != false, let latest, latest.hasCoordinator else { return nil }
        let state: BriefingCardModel.State
        if isAsking {
            state = .refreshing
        } else {
            switch latest.refresh?.state {
            case .pending?: state = .refreshing
            case .failed?, .timedOut?: state = .failed
            case nil: state = .idle
            }
        }
        let coolingDown = cooldownUntil.map { $0 > clock } ?? false
        return BriefingCardModel(createdAt: latest.briefing?.createdAt, body: latest.briefing?.body ?? "",
                                 state: state, canRefresh: state != .refreshing && !coolingDown, notice: notice)
    }

    public func start() {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.refresh()
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
        wakeTask?.cancel()
        updatesTask = nil
        statesTask = nil
        wakeTask = nil
        // A `GET` still in flight must not land after this.
        appliedRequest = nextRequest
        nextRequest += 1
    }

    /// `GET /briefings/latest`. A transport failure keeps what is shown.
    public func refresh() async {
        let request = beginRequest()
        do {
            let answer = try await api.latestBriefing()
            guard request > appliedRequest else {
                Self.logger.debug("dropping a GET /briefings/latest answer superseded by a newer one")
                return
            }
            apply(answer, request: request)
        } catch BriefingsError.unsupported {
            guard request > appliedRequest else { return }
            isSupported = false
            recompute()
        } catch {
            Self.logger.warning("GET /briefings/latest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The card's refresh button (and "Ask for one"): asks the Coordinator
    /// for a new briefing. Skipped while an ask is in flight, a refresh is
    /// pending, or the cooldown runs. The journal answers with the new
    /// state; its `refreshing` frame then re-reads it on every device.
    public func requestRefresh() async {
        guard cardModel?.canRefresh == true, !isAsking else { return }
        isAsking = true
        notice = nil
        recompute()
        let request = beginRequest()
        do {
            let answer = try await api.refreshBriefing()
            rateLimitedUntil = nil
            isAsking = false
            if request > appliedRequest {
                apply(answer, request: request)
            } else {
                recompute()
            }
            return
        } catch BriefingsError.rateLimited(let retryAt) {
            rateLimitedUntil = retryAt ?? now().addingTimeInterval(Self.fallbackCooldown)
        } catch BriefingsError.unsupported {
            isSupported = false
        } catch BriefingsError.noCoordinator {
            // The re-read below learns `has_coordinator: false` and hides
            // the card; nothing to say on it.
        } catch {
            notice = error.localizedDescription
            Self.logger.warning("POST /briefings/refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        isAsking = false
        recompute()
        // Whatever stopped the ask, the journal's own view of it is the
        // one to show (a refresh another device asked for, say).
        if isSupported != false { await refresh() }
    }

    // MARK: - Internals

    private func beginRequest() -> Int {
        defer { nextRequest += 1 }
        return nextRequest
    }

    private func apply(_ answer: LatestBriefing, request: Int) {
        if answer.briefing?.id != latest?.briefing?.id { notice = nil }
        latest = answer
        isSupported = true
        appliedRequest = request
        recompute()
    }

    private func recompute() {
        clock = now()
        if let until = rateLimitedUntil, until <= clock { rateLimitedUntil = nil }
        scheduleWake()
    }

    /// Wakes at the soonest of: the cooldown's end (the button comes
    /// back), and a pending refresh's `expires_at` plus `expiryGrace` (re-read,
    /// so a timeout shows).
    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        var wakes: [Date] = []
        if let until = cooldownUntil, until > clock { wakes.append(until) }
        if let pending = latest?.refresh, pending.state == .pending, let expiresAt = pending.expiresAt {
            let due = expiresAt.addingTimeInterval(expiryGrace)
            wakes.append(due > clock ? due : clock.addingTimeInterval(Self.expiredRecheck))
        }
        guard let next = wakes.min() else { return }
        let delay = max(0, next.timeIntervalSince(clock))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() async {
        clock = now()
        if let pending = latest?.refresh, pending.state == .pending,
           let expiresAt = pending.expiresAt, expiresAt <= clock {
            await refresh()
        }
        recompute()
    }
}
