import Foundation
import os

/// One day of sync work on this device: what Settings shows, so the two sync
/// scopes can be compared on a real phone over a real day.
public struct SyncDayStats: Equatable, Sendable, Codable {
    /// Journal events written to the mirror, live and replayed.
    public var events: Int = 0
    /// Catch-ups: a connect that started behind and reached the head.
    public var catchUps: Int = 0
    /// Their total length, in seconds.
    public var catchUpSeconds: Double = 0
    /// Conversations fetched because they were opened (`forYou` only).
    public var conversationFetches: Int = 0
    /// Silent pushes iOS delivered with the app in the background.
    public var backgroundWakes: Int = 0

    public init() {}

    /// By hand so a day stored before a count existed still decodes: the
    /// synthesized decoder would throw on the missing key and lose the day.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
        catchUps = try c.decodeIfPresent(Int.self, forKey: .catchUps) ?? 0
        catchUpSeconds = try c.decodeIfPresent(Double.self, forKey: .catchUpSeconds) ?? 0
        conversationFetches = try c.decodeIfPresent(Int.self, forKey: .conversationFetches) ?? 0
        backgroundWakes = try c.decodeIfPresent(Int.self, forKey: .backgroundWakes) ?? 0
    }
}

/// Counts sync work per calendar day, kept in `UserDefaults` for today and
/// yesterday. Cheap enough to call per applied frame: the counts live in
/// memory and are written back at most every few seconds.
/// `@unchecked`: `UserDefaults` is thread-safe; the counts sit behind the lock.
public final class SyncStatsRecorder: @unchecked Sendable {
    private struct State {
        var day: String
        var today = SyncDayStats()
        var yesterday: SyncDayStats?
        var lastWrite = Date.distantPast
    }

    static let defaultsKey = "sync.stats"
    private static let writeInterval: TimeInterval = 5

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let state: OSAllocatedUnfairLock<State>

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let today = Self.dayKey(now())
        var initial = State(day: today)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: SyncDayStats].self, from: data) {
            initial.today = stored[today] ?? SyncDayStats()
            initial.yesterday = stored[Self.dayKey(now().addingTimeInterval(-86_400))]
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func noteEvents(_ count: Int) {
        guard count > 0 else { return }
        update { $0.events += count }
    }

    public func noteCatchUp(seconds: Double) {
        update { $0.catchUps += 1; $0.catchUpSeconds += seconds }
    }

    public func noteConversationFetch() {
        update { $0.conversationFetches += 1 }
    }

    /// Written straight away: iOS may suspend the process seconds after a
    /// wake, and a count held back by the write interval would be lost.
    public func noteBackgroundWake() {
        update(writeNow: true) { $0.backgroundWakes += 1 }
    }

    /// Today's counts and yesterday's, if this device recorded any.
    public func snapshot() -> (today: SyncDayStats, yesterday: SyncDayStats?) {
        let date = now()
        return state.withLock { s in
            Self.roll(&s, to: date)
            return (s.today, s.yesterday)
        }
    }

    /// Writes back whatever the interval is holding, for the end of a
    /// background run: the process may not get another chance.
    public func flush() {
        let date = now()
        write(state.withLock { s in
            Self.roll(&s, to: date)
            s.lastWrite = date
            return Self.stored(s, at: date)
        })
    }

    private func update(writeNow: Bool = false, _ change: (inout SyncDayStats) -> Void) {
        let date = now()
        write(state.withLock { s in
            Self.roll(&s, to: date)
            change(&s.today)
            guard writeNow || date.timeIntervalSince(s.lastWrite) >= Self.writeInterval else { return nil }
            s.lastWrite = date
            return Self.stored(s, at: date)
        })
    }

    private static func stored(_ s: State, at date: Date) -> [String: SyncDayStats] {
        var out = [s.day: s.today]
        if let yesterday = s.yesterday { out[dayKey(date.addingTimeInterval(-86_400))] = yesterday }
        return out
    }

    private func write(_ days: [String: SyncDayStats]?) {
        if let days, let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func roll(_ s: inout State, to date: Date) {
        let day = dayKey(date)
        guard day != s.day else { return }
        s.yesterday = dayKey(date.addingTimeInterval(-86_400)) == s.day ? s.today : nil
        s.today = SyncDayStats()
        s.day = day
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
