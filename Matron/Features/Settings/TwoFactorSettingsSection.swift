import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Security: the Email address row (where a password-reset
/// link goes), the Password row (change password), then whether
/// two-factor sign-in is on for this account. Two-factor is read-only
/// here: turning it on or off and making new recovery codes happen in
/// Matron Web, which the row links to. The two-factor rows hide on a
/// journal without two-factor; the Password row keeps the section up.
struct TwoFactorSettingsSection: View {
    @State private var model: TwoFactorSettingsModel
    let webURL: URL
    /// `POST /password`; nil leaves the Password row out.
    let passwordAPI: (any PasswordChanging)?
    /// `GET`/`PUT /account/email`; nil leaves the Email address row out.
    let emailAPI: (any AccountEmailProviding)?

    init(api: any TwoFactorStatusProviding, webURL: URL, passwordAPI: (any PasswordChanging)? = nil,
         emailAPI: (any AccountEmailProviding)? = nil) {
        _model = State(initialValue: TwoFactorSettingsModel(api: api))
        self.webURL = webURL
        self.passwordAPI = passwordAPI
        self.emailAPI = emailAPI
    }

    var body: some View {
        Group {
            if model.isShown || passwordAPI != nil || emailAPI != nil {
                Section {
                    if let emailAPI {
                        AccountEmailRow(api: emailAPI)
                    }
                    if let passwordAPI {
                        ChangePasswordRow(api: passwordAPI)
                    }
                    if model.isShown {
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
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if model.isShown {
                        if case .failed(let message) = model.phase {
                            Text("\(message) \(TwoFactorSettingsModel.manageNote)")
                        } else {
                            Text(model.detailText ?? TwoFactorSettingsModel.manageNote)
                        }
                    }
                }
            }
        }
        .task { await model.refresh() }
    }
}
