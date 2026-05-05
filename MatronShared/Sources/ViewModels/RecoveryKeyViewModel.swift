import Foundation
import MatronVerification

/// Cross-platform view-model backing the recovery-key UI (spec §7.2 Scenario A).
/// Lives in `MatronViewModels` so iOS (`RecoveryKeyView`) and macOS
/// (`MacRecoveryKeyView`) consume the same state machine — only the SwiftUI
/// layer differs across platforms.
///
/// `RecoveryKeyManager` (which holds the SDK + Keychain wiring) lives in
/// `MatronVerification`, which `MatronViewModels` does *not* depend on. The
/// view-model is intentionally agnostic of the manager: callers wire the
/// async surface in via `generate` / `restore` closures so this type can be
/// tested standalone here without any SDK dance.
///
/// The `.generate` mode is a three-step sub-flow:
///   - `.show`    — key is visible; user must tick "I've saved this".
///   - `.reenter` — user types/pastes the key back to confirm save.
///   - `.confirmed` — terminal; view animates a success affordance and
///     calls `onFinished()` to dismiss. iOS doesn't use `.confirmed` (it
///     dismisses straight from `.reenter` once `canFinish` is true), but
///     the Mac variant transitions through it for the success animation.
///
/// The `.restore` mode is single-phase: user enters a known key, taps
/// "Restore," done.
@Observable
@MainActor
public final class RecoveryKeyViewModel {
    public enum Mode: Sendable { case generate, restore }

    /// Coarse-grained lifecycle state shared across both modes. `.busy`
    /// disables the primary action while an async call is in flight;
    /// `.error(message)` carries the localized failure description for
    /// inline display under the entry field.
    public enum Phase: Equatable, Sendable {
        case idle, busy, done
        case error(String)
    }

    /// Sub-phase within `.generate` mode (spec §7.2 Scenario A).
    public enum GeneratePhase: Equatable, Sendable {
        case notStarted, show, reenter, confirmed
    }

    public let mode: Mode
    public var generatedKey: String?
    /// Restore-mode entry.
    public var enteredKey: String = ""
    /// Generate-mode re-entry (Phase B).
    public var reenteredKey: String = ""
    public var userAcknowledgedSaved: Bool = false
    public var phase: Phase = .idle
    public var generatePhase: GeneratePhase = .notStarted

    private let generate: () async throws -> String
    private let restore: (String) async throws -> Void

    public init(
        mode: Mode,
        generate: @escaping () async throws -> String,
        restore: @escaping (String) async throws -> Void
    ) {
        self.mode = mode
        self.generate = generate
        self.restore = restore
    }

    /// Whether the primary "Confirm" / "Restore" action should be enabled.
    /// For `.generate` we additionally require constant-time equality
    /// between the displayed and re-entered keys (see `keysMatch`).
    public var canFinish: Bool {
        switch mode {
        case .generate:
            // Only finishable from Phase B (`reenter`) once the user has
            // acknowledged saving the key AND the re-entered value matches
            // the generated one (constant-time compare — see `keysMatch`).
            guard generatePhase == .reenter,
                  userAcknowledgedSaved,
                  let key = generatedKey
            else { return false }
            return Self.keysMatch(key, reenteredKey)
        case .restore:
            return !enteredKey.isEmpty
        }
    }

    /// Constant-time string comparison — the bytewise XOR-then-OR is
    /// deliberately written *without* an early-return on first mismatched
    /// byte. The compare runs against a value the user just typed, not a
    /// remote server, so timing leakage isn't a live attack vector today —
    /// but writing it correctly costs nothing and protects against future
    /// callers (or an automation harness) that might wire a slow side
    /// channel into this surface.
    public nonisolated static func keysMatch(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    /// First-device path: invokes the injected `generate` closure (which
    /// production wires to `RecoveryKeyManager.generateAndPersist()`),
    /// stores the plaintext key, and advances to `.show`.
    public func generate() async {
        phase = .busy
        do {
            let key = try await generate()
            generatedKey = key
            phase = .done
            generatePhase = .show
        } catch let persistenceError as RecoveryKeyManager.PersistenceError {
            // Bugbot caught: the SDK generated the key successfully but
            // local persistence (Keychain) failed. Without extracting the
            // key from the associated value the user would never see it
            // and the recovery key would be irrecoverably lost. Surface
            // the key alongside a warning so the user can copy it manually.
            switch persistenceError {
            case .keychainWriteFailedButKeyAvailable(let key, let underlying):
                generatedKey = key
                generatePhase = .show
                // The recovery key itself is fine — it's been generated
                // and registered server-side; only the local Keychain
                // write-back failed (typically `errSecMissingEntitlement`
                // on unsigned dev builds). Tell the user what to do
                // (copy it manually) without surfacing the raw
                // `Keychain error -34018` text. The underlying error
                // is logged via `RecoveryKeyManager.logger` for
                // dev-side inspection in Console.app.
                _ = underlying
                phase = .error("Couldn't auto-save your recovery key — please copy it now and keep it somewhere safe.")
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Advance from Phase A (show) → Phase B (reenter) once the user has
    /// ticked the "I've saved this" toggle. Called from the view's
    /// "Continue" button. No-op if either guard fails so the view doesn't
    /// have to mirror the precondition logic.
    public func advanceFromShow() {
        guard mode == .generate, generatePhase == .show, userAcknowledgedSaved else { return }
        generatePhase = .reenter
    }

    /// Restore-mode action: feeds `enteredKey` to the injected `restore`
    /// closure (production wires to `RecoveryKeyManager.restore(usingKey:)`).
    /// On success the caller dismisses the sheet via the view's
    /// `onFinished` closure; on failure we surface the error inline so the
    /// user can re-try without re-entering the key.
    ///
    /// Wave 4 expert-QA #1: explicit dispatch on `RecoveryKeyManager.RestoreError`
    /// so the UI gets per-case copy ("That recovery key didn't work" vs
    /// "Couldn't reach the homeserver") even if a future refactor drops the
    /// `LocalizedError` conformance on `RestoreError`. Falls through to
    /// `error.localizedDescription` for any non-translated error so a future
    /// `restore` closure that throws a different type still renders SOMETHING
    /// instead of an empty error string.
    public func attemptRestore() async {
        phase = .busy
        do {
            try await restore(enteredKey)
            phase = .done
        } catch let restoreError as RecoveryKeyManager.RestoreError {
            switch restoreError {
            case .invalidKey:
                phase = .error("That recovery key didn't work — check for typos and try again.")
            case .network:
                phase = .error("Couldn't reach the homeserver. Check your connection and try again.")
            case .other(let underlying):
                phase = .error("Couldn't restore: \(underlying.localizedDescription)")
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
