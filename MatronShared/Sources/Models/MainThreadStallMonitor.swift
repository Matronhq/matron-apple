import Foundation
import os

/// Logs every main-thread stall, un-gated, so "the app feels sluggish" has a
/// number behind it after the fact (`log show --predicate 'subsystem ==
/// "chat.matron" AND category == "main-stall"'`). Added during the 2026-09-17
/// Mac switch-cost dig: the app had no hang instrumentation at all, and every
/// earlier round had to infer stalls from `sample` output taken at a guess.
///
/// A utility-queue timer posts a no-op to the main queue every `interval` and
/// measures how long the hop took. A hop slower than `threshold` is a stall;
/// it is reported once, when the main thread comes back, with its duration.
/// A hop still outstanding after `unresponsiveAfter` is also announced while it
/// is happening ("unresponsive"), which timestamps the START of a long hang and
/// gives an external watcher something to trigger `sample` on before it ends.
/// While a ping is outstanding no further ping is sent, so a long stall costs
/// one queued block, not a backlog. Steady-state cost is ten trivial main-queue
/// blocks a second.
public final class MainThreadStallMonitor: @unchecked Sendable {
    public static let shared = MainThreadStallMonitor()

    private static let logger = Logger(subsystem: "chat.matron", category: "main-stall")
    private let queue = DispatchQueue(label: "chat.matron.main-stall", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingOutstanding = false
    private var pingSent = DispatchTime.now()
    private var announcedUnresponsive = false

    /// Pure so the threshold rule is testable without a run loop.
    public static func isStall(hop: TimeInterval, threshold: TimeInterval) -> Bool {
        hop >= threshold
    }

    /// Idempotent. `onStall` runs on the monitor's queue (tests); production
    /// callers leave it nil and read the log.
    public func start(interval: TimeInterval = 0.1, threshold: TimeInterval = 0.25,
                      unresponsiveAfter: TimeInterval = 1.0,
                      onUnresponsive: (@Sendable () -> Void)? = nil,
                      onStall: (@Sendable (TimeInterval) -> Void)? = nil) {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
            source.setEventHandler { [self] in
                if pingOutstanding {
                    let waited = TimeInterval(DispatchTime.now().uptimeNanoseconds - pingSent.uptimeNanoseconds) / 1_000_000_000
                    if waited >= unresponsiveAfter, !announcedUnresponsive {
                        announcedUnresponsive = true
                        Self.logger.notice("main thread unresponsive for \(Int(waited * 1000), privacy: .public) ms and counting")
                        onUnresponsive?()
                    }
                    return
                }
                pingOutstanding = true
                announcedUnresponsive = false
                let sent = DispatchTime.now()
                pingSent = sent
                DispatchQueue.main.async { [self] in
                    let hop = TimeInterval(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000_000
                    queue.async { [self] in
                        pingOutstanding = false
                        guard Self.isStall(hop: hop, threshold: threshold) else { return }
                        Self.logger.notice("main thread stalled \(Int(hop * 1000), privacy: .public) ms")
                        MatronFileLog.append("main thread stalled \(Int(hop * 1000)) ms")
                        onStall?(hop)
                    }
                }
            }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            pingOutstanding = false
        }
    }
}
