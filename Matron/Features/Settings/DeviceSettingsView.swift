import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels
import MatronJournal

/// Settings → Device surface. Task 11 strips the verification / recovery-key
/// sections (Matrix-SDK-only concepts the journal stack has no equivalent
/// for yet) down to a read-only account summary: userID, deviceID, and
/// homeserver host. The Devices row (journal PR #19) pushes the roster +
/// pairing screen; `devicesAPI`, `linkAPI`, and `onSignOut` are all optional
/// so previews / tests keep rendering the summary without a live API or
/// sign-out wiring.
struct DeviceSettingsView: View {
    let session: UserSession
    var devicesAPI: (any DevicesProviding)? = nil
    var linkAPI: (any DeviceLinking)? = nil
    /// Agent-chat consent surface. Optional like the others so previews and
    /// tests render the summary without a live API.
    var agentChatAPI: (any AgentChatProviding)? = nil
    var onSignOut: (() -> Void)? = nil
    /// Injected by MatronApp; nil in previews/tests hides the section.
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
            if devicesAPI != nil || linkAPI != nil {
                Section("Devices") {
                    if let devicesAPI {
                        NavigationLink {
                            DevicesView(api: devicesAPI, onSelfRevoked: { onSignOut?() })
                        } label: {
                            Label("Manage Devices", systemImage: "laptopcomputer.and.iphone")
                        }
                    }
                    if let linkAPI {
                        NavigationLink {
                            DeviceLinkView(api: linkAPI, serverURL: session.homeserverURL, relay: RelayClient())
                        } label: {
                            Label("Link a Device", systemImage: "qrcode")
                        }
                    }
                    if let agentChatAPI {
                        NavigationLink {
                            AgentChatView(api: agentChatAPI)
                        } label: {
                            Label("Agent Chats", systemImage: "person.2.wave.2")
                        }
                    }
                }
            }
            // Only offered when the device can actually authenticate —
            // a toggle that can never unlock again would lock the user
            // out of their own chats.
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
                // Writes MatronAppearance.storageKey; MatronApp's root
                // @AppStorage observes the same key and applies it via
                // .preferredColorScheme, so the switch is live.
                AppearancePicker()
            }
        }
        .navigationTitle("Device")
    }
}
