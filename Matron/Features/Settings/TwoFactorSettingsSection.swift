import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Security: whether two-factor sign-in is on for this account.
/// Read-only: turning it on or off and making new recovery codes happen in
/// Matron Web, which the row links to. Hidden on a journal without
/// two-factor.
struct TwoFactorSettingsSection: View {
    @State private var model: TwoFactorSettingsModel
    let webURL: URL

    init(api: any TwoFactorStatusProviding, webURL: URL) {
        _model = State(initialValue: TwoFactorSettingsModel(api: api))
        self.webURL = webURL
    }

    var body: some View {
        Group {
            if model.isShown {
                Section {
                    LabeledContent(TwoFactorSettingsModel.title) {
                        switch model.phase {
                        case .loading: ProgressView()
                        case .failed: Text("Unknown").foregroundStyle(.secondary)
                        default: Text(model.statusText ?? "")
                        }
                    }
                    .accessibilityIdentifier("settings.twoFactor.status")
                    Link(destination: webURL) {
                        Label(TwoFactorSettingsModel.webLinkTitle, systemImage: "safari")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if case .failed(let message) = model.phase {
                        Text("\(message) \(TwoFactorSettingsModel.manageNote)")
                    } else {
                        Text(model.detailText ?? TwoFactorSettingsModel.manageNote)
                    }
                }
            }
        }
        .task { await model.refresh() }
    }
}
