import SwiftUI
import LocalAuthentication
import MatronModels
import MatronVerification

/// Settings → Device surface (spec §6 / §7.1). Three sections:
///
///   * **Account** — userID, deviceID, homeserver host (read-only).
///   * **Encryption** — this-device verification status (✓ / ⚠ / spinner)
///     plus a "Show recovery key" button that reveals the locally-stored
///     key (synced from iCloud Keychain on additional installs).
///   * **Recovery key** — only renders after the user explicitly taps
///     "Show". Monospaced + selectable so the user can copy or screenshot.
///
/// Closure-injection (`currentRecoveryKey: () throws -> String?`) instead
/// of holding a `RecoveryKeyManager` directly so the view stays trivially
/// testable without standing up a real `KeychainStore`. Mirrors the
/// pattern `RecoveryKeyViewModel` already uses for `generate` / `restore`.
///
/// The "show recovery key" reveal is gated behind device-local
/// re-authentication (`LAContext.deviceOwnerAuthentication` — Face ID /
/// Touch ID / passcode on iOS) per spec §7.1 "show recovery key after
/// re-auth." Wave 4 expert-QA #3 caught this — without the gate, an
/// unattended unlocked device exposed the key on a single tap. The
/// auth call is injected as a closure so binding tests can fake the
/// pass / fail paths; production wiring constructs an `LAContext` per
/// reveal and runs `evaluatePolicy(.deviceOwnerAuthentication, …)`.
struct DeviceSettingsView: View {
    let session: UserSession
    let verificationService: VerificationService
    /// Read-only lookup for the "Show recovery key" reveal. Returns the
    /// locally-stored key (synced from iCloud Keychain on additional
    /// installs) or `nil` if nothing has been stored. Throws are
    /// surfaced to the user as the literal placeholder so a Keychain
    /// failure doesn't silently look like "no key" — that would mask
    /// a real bug. Production wiring lives in `ChatListView` (it
    /// constructs a `RecoveryKeyManager` and forwards `currentKey()`).
    let currentRecoveryKey: () throws -> String?
    /// Re-authentication closure invoked before `currentRecoveryKey()`.
    /// Returns `true` on auth success, `false` on user-cancel /
    /// no-biometrics-enrolled / policy failure. Default constructs an
    /// `LAContext` per reveal and runs
    /// `.deviceOwnerAuthentication` (Face ID / Touch ID / passcode).
    /// Tests inject a fake closure to exercise both arms without
    /// standing up biometrics. Wave 4 expert-QA #3 — auth gate is
    /// mandatory; an unattended unlocked device used to expose the key
    /// on Settings open.
    var requestAuth: () async -> Bool = Self.defaultRequestAuth

    @State private var isVerified: Bool? = nil
    @State private var revealedKey: String? = nil
    @State private var revealError: String? = nil

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("User ID", value: session.userID)
                LabeledContent("Device ID", value: session.deviceID)
                LabeledContent(
                    "Server",
                    value: session.homeserverURL.host ?? session.homeserverURL.absoluteString
                )
            }
            Section("Encryption") {
                LabeledContent("This device verified") {
                    if let isVerified {
                        Image(systemName: isVerified ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(isVerified ? .green : .orange)
                            .accessibilityLabel(isVerified ? "Verified" : "Not verified")
                    } else {
                        ProgressView()
                            .accessibilityLabel("Checking verification state")
                    }
                }
                Button("Show recovery key") {
                    Task { await revealKey() }
                }
            }
            if let key = revealedKey {
                Section("Recovery key") {
                    Text(key)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Recovery key: \(key)")
                }
            } else if let revealError {
                Section("Recovery key") {
                    Text(revealError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Device")
        .task {
            // `try?` because the live impl throws `notConfigured` only
            // when no provider is wired (a programmer error, not a
            // runtime state). Falling back to `false` keeps the
            // ⚠ icon visible so the user is prompted to verify rather
            // than seeing a perpetual spinner.
            isVerified = (try? await verificationService.isThisDeviceVerified()) ?? false
        }
    }

    /// Drives the "Show recovery key" tap. Wave 4 expert-QA #3: gate the
    /// reveal behind `requestAuth()` (production = `LAContext` + Face ID /
    /// Touch ID / passcode) so an unattended unlocked device doesn't
    /// expose the key on Settings open. On auth failure we surface a
    /// distinct error message and keep the key hidden — auth-cancel
    /// reads differently from "no key stored" or "Keychain failure" so
    /// the user knows to retry the auth prompt rather than re-checking
    /// their iCloud Keychain state.
    private func revealKey() async {
        let authed = await requestAuth()
        guard authed else {
            revealedKey = nil
            revealError = "Authentication required to show your recovery key."
            return
        }
        do {
            if let key = try currentRecoveryKey() {
                revealedKey = key
                revealError = nil
            } else {
                revealedKey = nil
                revealError = "No recovery key stored on this device."
            }
        } catch {
            revealedKey = nil
            revealError = "Couldn't read recovery key: \(error.localizedDescription)"
        }
    }

    /// Default `requestAuth` closure — constructs an `LAContext` per
    /// reveal and runs `.deviceOwnerAuthentication`, which falls back
    /// from biometrics to passcode. `nonisolated` so the View struct's
    /// default-arg expression is callable at construction time without
    /// a MainActor hop. Returns `false` on cancel, no-biometrics-and-
    /// no-passcode, or any policy error — caller surfaces the
    /// generic "Authentication required" message either way (we don't
    /// distinguish "user cancelled" from "no biometrics enrolled" in
    /// the UI; the user retries from the same Settings surface).
    nonisolated static func defaultRequestAuth() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics + no passcode set: nothing to evaluate. Treat
            // as auth-fail so we never reveal the key on a device with
            // no local lock at all (which is the case the gate exists for).
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Show your recovery key"
            )
        } catch {
            return false
        }
    }
}
