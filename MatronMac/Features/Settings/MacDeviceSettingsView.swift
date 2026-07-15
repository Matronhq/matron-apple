#if os(macOS)
import SwiftUI
import AppKit
import MatronModels
import MatronDesignSystem

/// Mac analogue of `DeviceSettingsView` (iOS Task 11 / Mac Task 12). Same
/// reduction as the iOS view — the Encryption + Recovery-key sections are
/// gone (Matrix-SDK-only concepts the journal stack has no equivalent for
/// yet) down to a read-only account summary.
///
/// This view's old home was the Help → Show Recovery Key… menu sheet,
/// which Task 12 removes along with the rest of the verification UI.
/// Its new home is the Mac `Settings { … }` scene (⌘,) — the natural
/// macOS-idiomatic place for account info, and a reasonable place to
/// keep a Sign Out affordance now that this view is no longer reached
/// via a menu item that already implied "you're managing your account".
struct MacDeviceSettingsView: View {
    let session: UserSession
    /// Sign-out action. Optional so previews / tests can omit it and
    /// render the view without a destructive action wired up.
    var onSignOut: (() -> Void)? = nil

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
            Section("Appearance") {
                // Writes MatronAppearance.storageKey; MatronMacApp's root
                // @AppStorage observes the same key and applies it via
                // NSApp.appearance, so the switch is live app-wide.
                AppearancePicker()
            }
            if let onSignOut {
                Section {
                    Button("Sign Out", role: .destructive, action: onSignOut)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .navigationTitle("Device")
    }
}
#endif
