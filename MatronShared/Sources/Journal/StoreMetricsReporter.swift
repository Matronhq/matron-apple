import Foundation
import os

/// Drains `StoreMetrics` once a minute into the unified log, subsystem
/// `chat.matron`, category `store-observation`, one line per active
/// observation or write. Read it back with
/// `log show --predicate 'subsystem == "chat.matron" AND category == "store-observation"'`.
/// A quiet minute logs nothing.
public final class StoreMetricsReporter: @unchecked Sendable {
    public static let shared = StoreMetricsReporter(metrics: .shared)

    private static let logger = os.Logger(subsystem: "chat.matron", category: "store-observation")
    /// `.default` (notice), like `MainThreadStallMonitor`: `.info` lines
    /// stay in memory and never reach `log show`, so a day's measurement
    /// would read back empty.
    static let logLevel: OSLogType = .default
    public static let log: @Sendable ([String]) -> Void = { lines in
        for line in lines { logger.log(level: logLevel, "\(line, privacy: .public)") }
    }

    private let metrics: StoreMetrics
    private let interval: Duration
    private let sink: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "chat.matron.store-metrics", qos: .utility)
    private let lock = OSAllocatedUnfairLock()
    private var timer: (any DispatchSourceTimer)?

    init(metrics: StoreMetrics, interval: Duration = .seconds(60),
         sink: @escaping @Sendable ([String]) -> Void = StoreMetricsReporter.log) {
        self.metrics = metrics; self.interval = interval; self.sink = sink
    }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let nanos = Int(interval.components.seconds) * 1_000_000_000 + Int(interval.components.attoseconds / 1_000_000_000)
            t.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        lock.withLock { timer?.cancel(); timer = nil }
    }

    func tick() {
        let report = metrics.drain()
        guard !report.isEmpty else { return }
        sink(report.logLines())
    }
}
