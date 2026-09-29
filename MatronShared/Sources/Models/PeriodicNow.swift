import Foundation

/// An async sequence of `Date` ticks: yields ONE immediately, then one
/// every `interval` — never sleeps before its first value. Used to keep a
/// UI value like "now" fresh for a relative-time caption without the
/// first render showing a stale clock.
///
/// Bugbot, PR #273: the Decisions view's "Decided" captions were refreshed
/// by a loop that slept 60s BEFORE writing `decisionsNow`, so opening the
/// view any time between mount and that first tick compared captions
/// against a clock from view-creation time (or the previous tick) —
/// stale by up to a minute, and an item closed in that window rendered
/// "just now" regardless of how long ago it actually closed. `sleep`/`now`
/// are injectable so the "yields before ever sleeping" contract is
/// testable without a real 60-second wait.
public struct PeriodicNow: Sendable {
    private let interval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> Date

    public init(interval: Duration = .seconds(60), sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.interval = interval; self.sleep = sleep; self.now = now
    }

    /// Cancelling the consuming `for await` loop (or the enclosing `Task`)
    /// stops the stream — the underlying `Task` is cancelled from
    /// `onTermination`, same as any other cancellable `AsyncStream`.
    public func ticks() -> AsyncStream<Date> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(now())
                    guard !Task.isCancelled else { break }
                    await sleep(interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
