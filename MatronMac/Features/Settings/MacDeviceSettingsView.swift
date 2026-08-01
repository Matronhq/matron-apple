#if os(macOS)
import SwiftUI
import AppKit
import MatronModels
import MatronDesignSystem
import MatronViewModels

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
    /// Injected by MatronMacApp; nil in previews/tests hides the section.
    @Environment(\.appLockController) private var appLock

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
            // Only offered when the device can actually authenticate —
            // a toggle that can never unlock again would lock the user
            // out of their own chats. Mirrors iOS DeviceSettingsView.
            if let appLock, let method = appLock.methodName {
                Section("Privacy") {
                    Toggle("Require \(method)", isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { enabled in Task { await appLock.setEnabled(enabled) } }
                    ))
                    if appLock.isEnabled {
                        Picker("Lock", selection: Binding(
                            get: { appLock.timeout },
                            set: { appLock.timeout = $0 }
                        )) {
                            ForEach(AppLockTimeout.allCases) { timeout in
                                Text(timeout.title).tag(timeout)
                            }
                        }
                    }
                    if let error = appLock.unlockError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
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
        // Tall enough for the Privacy section when biometrics exist.
        .frame(width: 420, height: 440)
        .navigationTitle("Device")
    }
}
#endif
