import Foundation
import os
import UIKit

/// Thread-safe view of whether the device's protected data (files with
/// `NSFileProtectionComplete`, i.e. the search index) can be read right now,
/// for `LockAwareSearchService` to consult from its own actor.
///
/// `UIApplication.isProtectedDataAvailable` is main-actor state, so it is
/// mirrored into a lock here and kept current by the two protected-data
/// notifications. The one deliberate difference from the system flag is the
/// warning window: `protectedDataWillBecomeUnavailableNotification` arrives
/// about ten seconds BEFORE the key is evicted, while the system flag still
/// reads `true`, and this monitor reports `false` from that moment — the
/// window exists precisely so in-flight work can stop before the file goes
/// dark, and new work must not start inside it.
///
/// Notifications are not a complete record, though: a process that was
/// suspended when the phone locked or unlocked never sees the post. So the
/// host also calls `refresh()` at every point it regains control (scene
/// phase changes, a BGAppRefresh wake), which re-reads the system flag.
@MainActor
final class ProtectedDataMonitor {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "protected-data")
    /// Comfortably longer than the ~10 s between the will-notification and
    /// the key actually going away. A system flag still reading `true` this
    /// long after the warning means the lock never engaged or the device has
    /// been unlocked since (with the did-notification missed while
    /// suspended).
    private static let warningWindow: Duration = .seconds(60)

    private let available: OSAllocatedUnfairLock<Bool>
    /// When the last will-notification arrived, while still unmatched by a
    /// did-notification.
    private var warnedAt: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []

    /// Called on the main actor when the monitor flips to unavailable.
    var onWillBecomeUnavailable: (() -> Void)?
    /// Called on the main actor when the monitor flips back to available.
    var onDidBecomeAvailable: (() -> Void)?

    init() {
        available = OSAllocatedUnfairLock(initialState: UIApplication.shared.isProtectedDataAvailable)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warnedAt = ContinuousClock.now
                self.set(false)
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warnedAt = nil
                self.set(true)
            }
        })
    }

    /// Current state; callable from any thread.
    nonisolated var isAvailable: Bool {
        available.withLock { $0 }
    }

    /// Re-reads the system flag, for the moments a notification may have
    /// been missed while suspended. A pending warning (inside its window)
    /// keeps the monitor unavailable even though the system flag has not
    /// caught up yet.
    func refresh() {
        let systemAvailable = UIApplication.shared.isProtectedDataAvailable
        if !systemAvailable {
            warnedAt = nil
            set(false)
            return
        }
        if let warnedAt, ContinuousClock.now - warnedAt < Self.warningWindow { return }
        warnedAt = nil
        set(true)
    }

    private func set(_ newValue: Bool) {
        let old = available.withLock { value -> Bool in
            let old = value
            value = newValue
            return old
        }
        guard old != newValue else { return }
        Self.logger.info("protected data \(newValue ? "available" : "unavailable", privacy: .public)")
        if newValue {
            onDidBecomeAvailable?()
        } else {
            onWillBecomeUnavailable?()
        }
    }
}
