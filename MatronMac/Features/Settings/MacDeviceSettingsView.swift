#if os(macOS)
import SwiftUI
import AppKit
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
            isVerified = (try? await verificationService.isThisDeviceVerified()) ?? false
        }
    }

    /// Drives the "Show recovery key" tap. Splits the success / nil /
    /// error branches into distinct UI states (mirrors the iOS
    /// rationale — don't collapse "no key stored" and "Keychain
    /// failure" into the same sentinel).
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
#endif
