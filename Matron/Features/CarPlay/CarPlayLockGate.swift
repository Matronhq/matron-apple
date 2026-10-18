import Foundation
import Observation
import MatronViewModels
import MatronVoice

/// The app lock as the car's display sees it. While the lock is on and
/// Matron is locked, the car shows no conversations and opens no voice
/// mode: the iPhone is where Matron is unlocked. Nothing here imports
/// CarPlay, so it is tested without a car.
@MainActor
final class CarPlayLockGate {
    private let lock: AppLockController
    private var onChange: ((Bool) -> Void)?
    private var last: Bool
    /// Each `observe` starts a fresh watch; an older one stops by itself.
    private var generation = 0

    init(lock: AppLockController) {
        self.lock = lock
        last = lock.isLocked
    }

    var isLocked: Bool { lock.isLocked }

    /// The car's scene came to the front. Using Matron on the car counts
    /// as using it, under the same idle timeout as the iPhone: past the
    /// timeout since Matron was last in front anywhere, it locks.
    func arrived() {
        lock.noteBecameActive()
    }

    /// The car's scene left the front. The idle countdown starts only when
    /// Matron is in front nowhere: with the iPhone's window still up it is
    /// still in use.
    func left(phoneInFront: Bool) {
        guard !phoneInFront else { return }
        lock.noteResignedActive()
    }

    /// The iPhone's window left the front. With the car's scene still up,
    /// Matron is still in use and the countdown waits for the car to go.
    static func phoneLeft(_ lock: AppLockController, carInFront: Bool) {
        guard !carInFront else { return }
        lock.noteResignedActive()
    }

    /// What the car's voice screen draws: the locked screen while locked,
    /// whatever else is going on; otherwise the sitting, or `idle` when
    /// there is none.
    func model(sitting: VoiceModeEngine.State?, idle: CarPlayVoiceScreen.Idle) -> CarPlayVoiceScreen.Model {
        if isLocked { return CarPlayVoiceScreen.model(.locked) }
        return sitting.map(CarPlayVoiceScreen.model) ?? CarPlayVoiceScreen.model(idle)
    }

    /// Calls `onChange` with the new value each time Matron locks or
    /// unlocks, until `stop()`.
    func observe(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        last = lock.isLocked
        generation += 1
        track(generation)
    }

    func stop() {
        onChange = nil
        generation += 1
    }

    private func track(_ generation: Int) {
        withObservationTracking {
            _ = lock.isLocked
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                let now = self.lock.isLocked
                if now != self.last {
                    self.last = now
                    self.onChange?(now)
                }
                self.track(generation)
            }
        }
    }
}
