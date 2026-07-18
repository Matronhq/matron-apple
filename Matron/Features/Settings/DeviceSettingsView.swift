import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → Device surface. Task 11 strips the verification / recovery-key
/// sections (Matrix-SDK-only concepts the journal stack has no equivalent
/// for yet) down to a read-only account summary: userID, deviceID, and
/// homeserver host. The Devices row (journal PR #19) pushes the roster +
/// pairing screen; both dependencies are optional so previews / tests keep
/// rendering the summary without a live API.
struct DeviceSettingsView: View {
    let session: UserSession
    var devicesAPI: (any DevicesProviding)? = nil
    var linkAPI: (any DeviceLinking)? = nil
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
                            DeviceLinkView(api: linkAPI, serverURL: session.homeserverURL)
                        } label: {
                            Label("Link a Device", systemImage: "qrcode")
                        }
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
