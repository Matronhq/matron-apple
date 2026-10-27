import Foundation

/// A one-shot "the file is finished" that can be awaited without holding a
/// thread. The Mac's capture session learns its file is complete from a
/// delegate AVFoundation calls on the main thread; waiting for that with a
/// semaphore on the main thread meant the callback couldn't run until the
/// wait gave up (3 s on every voice note). `wait` suspends instead.
final class RecordingFinishSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Marks the file finished and releases every waiter. Later waits
    /// return at once.
    func signal() {
        lock.lock()
        isSignalled = true
        let released = waiters.values
        waiters = [:]
        lock.unlock()
        released.forEach { $0.resume(returning: true) }
    }

    /// Returns `true` once `signal()` has been called, or `false` when
    /// `timeout` seconds pass first.
    func wait(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { waiter in
            lock.lock()
            if isSignalled {
                lock.unlock()
                waiter.resume(returning: true)
                return
            }
            waiters[id] = waiter
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let expired = waiters.removeValue(forKey: id)
                lock.unlock()
                expired?.resume(returning: false)
            }
        }
    }
}
