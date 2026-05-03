import SwiftUI
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
/// The "show recovery key" reveal is currently a one-tap action — Phase 7
/// will gate it behind device-local re-authentication (Face ID / Touch
/// ID / passcode) per spec §7.1's "show recovery key after re-auth" note.
/// The closure indirection makes it a one-line swap when that lands.
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
                    revealKey()
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

    /// Drives the "Show recovery key" tap. Splits the success / nil /
    /// error branches into distinct UI states so a Keychain failure
    /// reads as something different from "you haven't stored a key" —
    /// silently collapsing both into the same string would mask real
    /// bugs (the bugbot lesson from Phase 3 round 4: don't swallow
    /// recovery-key paths into a single sentinel value).
    private func revealKey() {
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
}
