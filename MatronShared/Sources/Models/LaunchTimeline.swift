import Foundation
import os

/// What the last launch cost, in seconds. `storeOpen` and `migration` are
/// durations; `firstListPaint` and `catchUpComplete` are measured from the
/// kernel's process start, so they are what the user actually waited.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var storeOpen: TimeInterval?
    public var migration: TimeInterval?
    public var firstListPaint: TimeInterval?
    public var catchUpComplete: TimeInterval?
    public var recordedAt: Date

    public init(storeOpen: TimeInterval? = nil, migration: TimeInterval? = nil,
                firstListPaint: TimeInterval? = nil, catchUpComplete: TimeInterval? = nil,
                recordedAt: Date = Date()) {
        self.storeOpen = storeOpen
        self.migration = migration
        self.firstListPaint = firstListPaint
        self.catchUpComplete = catchUpComplete
        self.recordedAt = recordedAt
    }
}

/// Process-wide launch recorder: `OSSignposter` intervals for Instruments,
/// one `os.Logger` line per mark so `log show` / `devicectl` gives the
/// numbers on a phone without Instruments, and the whole record persisted to
/// `UserDefaults` on every mark (not at process exit), so Settings › Storage
/// can show THIS launch — the one the user is in when they open Settings —
/// rather than the previous one (R13; see `currentLaunch`'s doc below).
///
/// Before this existed there was no launch instrumentation anywhere in the
/// app, so which cost dominated on the phone was guesswork.
public final class LaunchTimeline: @unchecked Sendable {
    public enum Mark: String, Sendable, CaseIterable {
        case processStart, storeOpen, migration, firstListPaint, catchUpComplete
    }

    /// The `UserDefaults` key the Settings row reads.
    public static let defaultsKey = "launch.last"

    public static let shared = LaunchTimeline()

    private static let signposter = OSSignposter(
        subsystem: subsystem, category: "launch")
    private static let logger = os.Logger(subsystem: subsystem, category: "launch")

    private static var subsystem: String {
        #if os(macOS)
        "chat.matron.mac"
        #else
        "chat.matron"
        #endif
    }

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let processStart: Date
    private let lock = NSLock()
    private var _record: LaunchRecord
    private var storeOpenBegan: Date?
    private var storeOpenSignpost: OSSignpostIntervalState?

    /// `processStart` defaults to the kernel's start time for this process,
    /// so every mark is launch-relative rather than relative to whenever the
    /// first Swift code happened to run.
    public init(defaults: UserDefaults = .standard,
                processStart: Date? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        self.processStart = processStart ?? Self.kernelProcessStart() ?? clock()
        self._record = LaunchRecord(recordedAt: self.processStart)
    }

    public var record: LaunchRecord {
        lock.lock(); defer { lock.unlock() }
        return _record
    }

    /// First-wins, like `mark(_:)`: the launch record describes the first
    /// store open of the process. A second `core(for:)` call in the same
    /// process (sign-out → sign-in) must not start a second signpost
    /// interval or, via `endStoreOpen`, clobber the first session's timing
    /// with the second session's.
    public func beginStoreOpen() {
        lock.lock()
        defer { lock.unlock() }
        guard _record.storeOpen == nil, storeOpenBegan == nil else { return }
        storeOpenBegan = clock()
        storeOpenSignpost = Self.signposter.beginInterval("storeOpen")
    }

    public func endStoreOpen() {
        lock.lock()
        guard let began = storeOpenBegan else { lock.unlock(); return }
        let elapsed = clock().timeIntervalSince(began)
        _record.storeOpen = elapsed
        storeOpenBegan = nil
        if let state = storeOpenSignpost {
            Self.signposter.endInterval("storeOpen", state)
            storeOpenSignpost = nil
        }
        // Persisted while still holding the lock — see `persist`'s doc:
        // this keeps the write ordered with the mutation, so a mark that
        // lands concurrently on another thread cannot finish its own
        // read-mutate-write in the gap and have this snapshot overwrite it.
        persist(_record)
        lock.unlock()
        Self.logger.info("launch storeOpen \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    /// Records the schema migration that ran inside this launch's store
    /// open. The duration is MEASURED BY THE STORE
    /// (`JournalStore.lastMigrationDuration`) and merely reported here, so
    /// `MatronShared` keeps no dependency on this type and no test writes
    /// `UserDefaults` (R7). First-wins for the same reason as
    /// `beginStoreOpen`/`endStoreOpen`: a second `core(for:)` call must not
    /// overwrite this launch's migration duration with its own (typically
    /// absent) one.
    public func recordMigration(_ duration: Duration) {
        let elapsed = TimeInterval(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        lock.lock()
        guard _record.migration == nil else { lock.unlock(); return }
        _record.migration = elapsed
        persist(_record)
        lock.unlock()
        Self.signposter.emitEvent("migration")
        Self.logger.info("launch migration \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    /// Records a point mark, launch-relative. First one wins: the chat list
    /// re-appears every time the user navigates back, and a reconnect
    /// re-reaches the live cursor — neither is "the launch".
    public func mark(_ mark: Mark) {
        lock.lock()
        let elapsed = clock().timeIntervalSince(processStart)
        switch mark {
        case .firstListPaint:
            guard _record.firstListPaint == nil else { lock.unlock(); return }
            _record.firstListPaint = elapsed
        case .catchUpComplete:
            guard _record.catchUpComplete == nil else { lock.unlock(); return }
            _record.catchUpComplete = elapsed
        case .processStart, .storeOpen, .migration:
            // Intervals (or the anchor), not point marks — see above.
            lock.unlock()
            return
        }
        // Persisted before unlocking (see `persist`'s doc): two marks
        // landing concurrently — e.g. main-actor `firstListPaint` racing
        // the sync engine's `catchUpComplete` — must not let an earlier
        // snapshot persist last and silently drop a field that already
        // landed in memory.
        persist(_record)
        lock.unlock()
        // `OSSignposter.emitEvent` takes a `StaticString`, which cannot be
        // built from a runtime `String` — so one literal per case, not
        // `mark.rawValue`.
        switch mark {
        case .firstListPaint: Self.signposter.emitEvent("firstListPaint")
        case .catchUpComplete: Self.signposter.emitEvent("catchUpComplete")
        case .processStart, .storeOpen, .migration: break
        }
        Self.logger.info("launch \(mark.rawValue, privacy: .public) \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    /// Encodes and writes `record`. Every call site holds `lock` for the
    /// duration of this call — deliberately: a `UserDefaults` write here is
    /// a handful of bytes, cheap enough that serializing it with the
    /// mutation is the simplest way to guarantee the invariant this type
    /// promises: after any interleaving of marks, the persisted record
    /// equals the in-memory one. Doing the write after releasing the lock
    /// (the original shape) let two concurrent callers' writes land
    /// out of order and drop whichever mark's write lost the race.
    private func persist(_ record: LaunchRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The persisted record. Named for what it actually holds: `persist()`
    /// runs on every mark rather than at process exit, so by the time the
    /// user can open Settings this describes the launch they are IN — which
    /// is the useful one, and why the row says "This launch" (R13). On a
    /// launch that crashed before catch-up it is that launch's partial
    /// record, which is also what you want.
    public static func currentLaunch(defaults: UserDefaults = .standard) -> LaunchRecord? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LaunchRecord.self, from: data)
    }

    /// The "This launch" row's copy: `store 1.9 s · first list 2.4 s ·
    /// catch-up 6.1 s`, with `· migration 3.2 s` appended on the one launch
    /// that ran one. Pure, so it is testable without a launch.
    public static func summary(_ record: LaunchRecord?) -> String {
        guard let record else { return "—" }
        var parts: [String] = []
        func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
        if let storeOpen = record.storeOpen { parts.append("store \(seconds(storeOpen))") }
        if let paint = record.firstListPaint { parts.append("first list \(seconds(paint))") }
        if let catchUp = record.catchUpComplete { parts.append("catch-up \(seconds(catchUp))") }
        if let migration = record.migration { parts.append("migration \(seconds(migration))") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Kernel process start time via `sysctl(KERN_PROC_PID)` — the same
    /// number Instruments anchors a launch on, and the only way to include
    /// the time before the first line of Swift ran.
    private static func kernelProcessStart() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
