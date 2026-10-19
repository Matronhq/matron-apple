#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Mac twin of `TwoFactorSettingsSection`: Settings → Security, whether
/// two-factor sign-in is on. Read-only; managed in Matron Web.
struct MacTwoFactorSettingsSection: View {
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
                        case .loading: ProgressView().controlSize(.small)
                        case .failed: Text("Unknown").foregroundStyle(.secondary)
                        default: Text(model.statusText ?? "")
                        }
                    }
                    .accessibilityIdentifier("settings.twoFactor.status")
                    Link(TwoFactorSettingsModel.webLinkTitle, destination: webURL)
                } header: {
                    Text("Security")
                } footer: {
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
        .task { await model.refresh() }
    }
}
#endif
