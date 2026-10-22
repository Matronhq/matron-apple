#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Mac twin of `TwoFactorSettingsSection`: Settings → Security, whether
/// two-factor sign-in is on (read-only; managed in Matron Web) and the
/// Change password button.
struct MacTwoFactorSettingsSection: View {
    @State private var model: TwoFactorSettingsModel
    let webURL: URL
    /// `POST /password`; nil leaves the Change password button out.
    let passwordAPI: (any PasswordChanging)?

    init(api: any TwoFactorStatusProviding, webURL: URL, passwordAPI: (any PasswordChanging)? = nil) {
        _model = State(initialValue: TwoFactorSettingsModel(api: api))
        self.webURL = webURL
        self.passwordAPI = passwordAPI
    }

    var body: some View {
        Group {
            if model.isShown || passwordAPI != nil {
                Section {
                    if model.isShown {
                        LabeledContent(TwoFactorSettingsModel.title) {
                            switch model.phase {
                            case .loading: ProgressView().controlSize(.small)
                            case .failed: Text("Unknown").foregroundStyle(.secondary)
                            default: Text(model.statusText ?? "")
                            }
                        }
                        .accessibilityIdentifier("settings.twoFactor.status")
                        Link(TwoFactorSettingsModel.webLinkTitle, destination: webURL)
                    }
                    if let passwordAPI {
                        MacChangePasswordRow(api: passwordAPI)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if model.isShown {
                        Group {
                            if case .failed(let message) = model.phase {
                                Text("\(message) \(TwoFactorSettingsModel.manageNote)")
                            } else {
                                Text(model.detailText ?? TwoFactorSettingsModel.manageNote)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await model.refresh() }
    }
}
#endif
