import Foundation
import GRDB
import os

/// Where the store's time goes: each observation fetch and each hot write,
/// timed and counted per name, drained once a minute by
/// `StoreMetricsReporter`. With thousands of conversations and items, every
/// observation that re-fetches a whole table after each write is a cost the
/// writer queue pays; these numbers show which ones.
public final class StoreMetrics: @unchecked Sendable {
    public static let shared = StoreMetrics()

    public struct ObservationStats: Equatable, Sendable {
        public var name: String
        public var fires: Int
        public var totalMS: Double
        public var maxMS: Double
        /// Row count of the latest fetch, when the value is a collection.
        public var rows: Int?
    }

    public struct WriteStats: Equatable, Sendable {
        public var name: String
        public var commits: Int
        public var totalMS: Double
        public var p95MS: Double
        public var maxMS: Double
    }

    public struct Report: Equatable, Sendable {
        public var observations: [ObservationStats]
        public var writes: [WriteStats]
        /// Every write together; `nil` when there were none.
        public var allWrites: WriteStats?

        public var isEmpty: Bool { observations.isEmpty && writes.isEmpty }

        public func logLines() -> [String] {
            func ms(_ v: Double) -> String { String(format: "%.1f", v) }
            var lines = observations.map { o in
                "observe \(o.name) fires=\(o.fires) total_ms=\(ms(o.totalMS)) max_ms=\(ms(o.maxMS))"
                    + (o.rows.map { " rows=\($0)" } ?? "")
            }
            for w in writes + (allWrites.map { [$0] } ?? []) {
                lines.append("write \(w.name) commits=\(w.commits) total_ms=\(ms(w.totalMS)) p95_ms=\(ms(w.p95MS)) max_ms=\(ms(w.maxMS))")
            }
            return lines
        }
    }

    private struct WriteWindow {
        var commits = 0
        var totalMS = 0.0
        var maxMS = 0.0
        /// The first `maxWriteSamplesPerName` durations, for p95. Counts and
        /// totals stay exact past the cap; a catch-up replay can commit
        /// thousands of times a minute.
        var samples: [Double] = []
    }

    private let lock = OSAllocatedUnfairLock()
    private let maxWriteSamplesPerName: Int
    private var fetches: [String: ObservationStats] = [:]
    private var writes: [String: WriteWindow] = [:]

    public init(maxWriteSamplesPerName: Int = 10_000) {
        self.maxWriteSamplesPerName = maxWriteSamplesPerName
    }

    func recordFetch(_ name: String, duration: Duration, rows: Int?) {
        let ms = Self.milliseconds(duration)
        lock.withLock {
            var s = fetches[name] ?? ObservationStats(name: name, fires: 0, totalMS: 0, maxMS: 0, rows: nil)
            s.fires += 1
            s.totalMS += ms
            s.maxMS = max(s.maxMS, ms)
            s.rows = rows
            fetches[name] = s
        }
    }

    func recordWrite(_ name: String, duration: Duration) {
        let ms = Self.milliseconds(duration)
        lock.withLock {
            var w = writes[name] ?? WriteWindow()
            w.commits += 1
            w.totalMS += ms
            w.maxMS = max(w.maxMS, ms)
            if w.samples.count < maxWriteSamplesPerName { w.samples.append(ms) }
            writes[name] = w
        }
    }

    public func drain() -> Report {
        let (f, w) = lock.withLock { () -> ([String: ObservationStats], [String: WriteWindow]) in
            defer { fetches = [:]; writes = [:] }
            return (fetches, writes)
        }
        let byCost: (Double, String, Double, String) -> Bool = { $0 != $2 ? $0 > $2 : $1 < $3 }
        let observations = f.values.sorted { byCost($0.totalMS, $0.name, $1.totalMS, $1.name) }
        let writeStats = w.map { name, window in
            WriteStats(name: name, commits: window.commits, totalMS: window.totalMS,
                       p95MS: Self.p95(window.samples), maxMS: window.maxMS)
        }.sorted { byCost($0.totalMS, $0.name, $1.totalMS, $1.name) }
        var all: WriteStats?
        if !w.isEmpty {
            all = WriteStats(name: "all", commits: w.values.reduce(0) { $0 + $1.commits },
                             totalMS: w.values.reduce(0) { $0 + $1.totalMS },
                             p95MS: Self.p95(w.values.flatMap(\.samples)),
                             maxMS: w.values.map(\.maxMS).max() ?? 0)
        }
        return Report(observations: observations, writes: writeStats, allWrites: all)
    }

    /// Nearest-rank 95th percentile.
    private static func p95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count, rank) - 1)]
    }

    private static func milliseconds(_ d: Duration) -> Double {
        let (seconds, attoseconds) = d.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

extension StoreMetrics {
    private static let signposter = OSSignposter(subsystem: "chat.matron", category: "store-observation")

    /// Times `body` as one fetch of observation `name`. The row count is
    /// the value's `count` when it is a collection. A throw is counted
    /// too, then rethrown untouched.
    func measureFetch<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = Self.signposter.beginInterval(name)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let value = try body()
            Self.signposter.endInterval(name, state)
            recordFetch(String(describing: name), duration: clock.now - start, rows: (value as? any Collection)?.count)
            return value
        } catch {
            Self.signposter.endInterval(name, state)
            recordFetch(String(describing: name), duration: clock.now - start, rows: nil)
            throw error
        }
    }

    /// Times `body`, a whole `dbQueue.write`, as one commit of `name`. On
    /// a `DatabaseQueue` this includes every observer's synchronous
    /// re-fetch, which is why it is the measure of writer contention.
    func measureWrite<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = Self.signposter.beginInterval(name)
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            Self.signposter.endInterval(name, state)
            recordWrite(String(describing: name), duration: clock.now - start)
        }
        return try body()
    }
}

extension ValueObservation {
    /// `tracking(_:)` with each fetch timed under `name`. The fetch closure
    /// is wrapped, not the reducer (GRDB's `mapReducer` is internal), so
    /// the time is the fetch itself, on the queue GRDB runs it on.
    static func measuredTracking<Value>(
        _ name: StaticString, in metrics: StoreMetrics,
        _ fetch: @escaping (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
        tracking { db in try metrics.measureFetch(name) { try fetch(db) } }
    }
}
