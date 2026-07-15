import SwiftUI
import MatronModels
import MatronDesignSystem

/// Settings → Device surface. Task 11 strips the verification / recovery-key
/// sections (Matrix-SDK-only concepts the journal stack has no equivalent
/// for yet) down to a read-only account summary: userID, deviceID, and
/// homeserver host.
struct DeviceSettingsView: View {
    let session: UserSession

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
                // Writes MatronAppearance.storageKey; MatronApp's root
                // @AppStorage observes the same key and applies it via
                // .preferredColorScheme, so the switch is live.
                AppearancePicker()
            }
        }
        .navigationTitle("Device")
    }
}
