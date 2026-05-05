import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct MacSignInView: View {
    @State var viewModel: SignInViewModel
    var onSignedIn: (UserSession) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Matron")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "Server") {
                    TextField("https://matrix.example.com", text: $viewModel.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin.server")
                }
                LabeledField(label: "Username") {
                    TextField("alice", text: $viewModel.username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin.username")
                }
                LabeledField(label: "Password") {
                    SecureField("", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("signin.password")
                }
            }

            if case .error(let message) = viewModel.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button {
                Task { await viewModel.submit() }
            } label: {
                if case .busy = viewModel.state {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Sign in")
                        .frame(maxWidth: .infinity)
                }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("signin.submit")
            .disabled({
                if case .busy = viewModel.state { return true }
                return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
            }())
        }
        .padding(32)
        .frame(width: 480, height: 360)
        .onChange(of: viewModel.state) { _, new in
            if case .signedIn(let session) = new {
                onSignedIn(session)
            }
        }
    }
}

private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field
        }
    }
}
