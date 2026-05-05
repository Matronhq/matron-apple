#if os(macOS)
import SwiftUI

/// Two-button chooser shown by `HelpMenuVerifyDeviceSheet` (and the
/// chat-list `MacUnverifiedDeviceBanner` route) when this device hasn't
/// been verified yet. The user picks SAS-with-another-device or recovery-
/// key restore.
///
/// Extracted from `HelpMenuVerifyDeviceSheet.chooserView` so the disabled-
/// when-no-other-devices branch can be snapshot-tested without standing
/// up the full sheet, its `Phase` state machine, or a SDK service. The
/// sheet remains the owner of the SAS / recovery-key view-model setup —
/// this view's job is just rendering + dispatching the user's choice via
/// the three closures.
///
/// `hasOtherDevices` reflects the resolved SDK probe
/// (`Encryption.hasDevicesToVerifyAgainst()`); the SAS button is disabled
/// + a one-line caption appears when it's `false`. Without the disabled
/// state, picking SAS would strand the user on a verification flow that
/// can never complete.
struct MacVerifyDeviceChooser: View {
    let hasOtherDevices: Bool
    let onSAS: () -> Void
    let onRecoveryKey: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("Verify this device")
                .font(.title2).bold()
            Text("Choose how to verify this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Button(action: onSAS) {
                    Label("Verify with another device", systemImage: "laptopcomputer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasOtherDevices)
                .accessibilityIdentifier("verifychooser.sas")
                if !hasOtherDevices {
                    Text("No other verified devices found for your account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onRecoveryKey) {
                Label("Use recovery key", systemImage: "key")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("verifychooser.recoveryKey")
            Button("Close", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 480, height: 380)
    }
}
#endif
