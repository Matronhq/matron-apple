import SwiftUI
import MatronModels

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
        }
        .navigationTitle("Device")
    }
}
