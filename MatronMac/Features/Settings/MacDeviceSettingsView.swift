#if os(macOS)
import SwiftUI
import AppKit
import LocalAuthentication
import MatronModels
import MatronVerification

/// Mac analogue of `DeviceSettingsView` (iOS Task 11). Same three
/// sections (Account / Encryption / Recovery key); Mac chrome is a
/// fixed-size sheet hosted from `MatronMacApp` via the existing Help →
/// Show Recovery Key menu item (Task 9c shipped a `MacRecoveryKeyView`
/// stub there; this view replaces it). Same closure-injection
/// (`currentRecoveryKey`) for trivially-testable construction.
///
/// Future Settings scene swap: `MatronMacApp.Settings { ... }` currently
/// hosts a placeholder. Phase 7 lifts this view into the Settings scene
/// proper; for Phase 3 it ships as a sheet so users can read their
/// recovery key without waiting for the Settings UI to land.
struct MacDeviceSettingsView: View {
    let session: UserSession
    let verificationService: VerificationService
    /// Read-only lookup for the recovery-key reveal. See iOS
    /// `DeviceSettingsView.currentRecoveryKey` for the rationale.
    let currentRecoveryKey: () throws -> String?
    /// Re-authentication closure invoked before `currentRecoveryKey()`.
    /// Wave 4 expert-QA #3 — see iOS `DeviceSettingsView.requestAuth`
    /// for the full rationale. On Mac, `.deviceOwnerAuthentication`
    /// covers Touch ID, Apple Watch unlock, and account password.
    var requestAuth: () async -> Bool = Self.defaultRequestAuth
    let onFinished: () -> Void

    @State private var isVerified: Bool? = nil
    @State private var revealedKey: String? = nil
    @State private var revealError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
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
                                .controlSize(.small)
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
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 480, height: 420)
        .navigationTitle("Device")
        .task {
            // Tri-state: `nil` (SDK hasn't loaded the identity yet) falls
            // back to `false` so settings shows the worst-case until
            // proven verified. Same posture as the iOS counterpart.
            isVerified = ((try? await verificationService.isThisDeviceVerified()) ?? nil) == true
        }
    }

    /// Drives the "Show recovery key" tap. Wave 4 expert-QA #3: gate
    /// the reveal behind `requestAuth()` so an unattended unlocked Mac
    /// doesn't expose the key on Settings open. See iOS
    /// `DeviceSettingsView.revealKey` for the full rationale.
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

    /// Default `requestAuth` closure for the Mac. Mirrors the iOS
    /// implementation — see `DeviceSettingsView.defaultRequestAuth`
    /// for the rationale.
    nonisolated static func defaultRequestAuth() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
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
#endif
