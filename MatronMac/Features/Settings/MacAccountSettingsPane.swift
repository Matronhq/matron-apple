#if os(macOS)
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → Account: who this Mac is signed in as, the sign-in security
/// settings, the app lock and Sign Out. Same section names as iOS
/// `DeviceSettingsView` (Account, Security, Privacy).
struct MacAccountSettingsPane: View {
    let session: UserSession
    let deps: AppDependencies
    let onSignOut: () -> Void
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
            MacTwoFactorSettingsSection(api: deps.twoFactorSettingsService(for: session),
                                        passwordAPI: deps.passwordService(for: session),
                                        emailAPI: deps.accountEmailService(for: session))
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
            Section {
                Button("Sign Out", role: .destructive, action: onSignOut)
            }
        }
        .formStyle(.grouped)
        // Tall enough for the Security section with Email address, Change
        // password and its confirmation, and the Privacy section with its
        // Lock picker.
        .frame(width: 480, height: 640)
    }
}
#endif
