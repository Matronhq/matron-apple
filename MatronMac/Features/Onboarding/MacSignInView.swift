import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct MacSignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    var onSignedIn: (UserSession) -> Void

    @State private var showingLinkCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("Sign in to Matron")
                .font(.title2.weight(.semibold))

            if case .waitingForApproval = linkViewModel.phase {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for approval on your other device…")
                    Button("Cancel") { linkViewModel.cancel() }
                }
                .frame(maxHeight: .infinity)
            } else {
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

                // Camera-less claimant path: type the code shown under the
                // QR on a signed-in device (Settings → Link a Device).
                Button(showingLinkCode ? "Hide link code" : "Have a link code?") {
                    showingLinkCode.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)

                if showingLinkCode {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledField(label: "Link code") {
                            TextField("XXXX-XXXX", text: $linkViewModel.codeInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("signin.linkcode")
                        }
                        Button("Sign in with code") {
                            linkViewModel.serverURL = viewModel.serverURL
                            Task { await linkViewModel.submitManual() }
                        }
                        .disabled(viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9)
                    }
                    if case .error(let message) = linkViewModel.phase {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 520)
        .onChange(of: viewModel.state) { _, new in
            if case .signedIn(let session) = new {
                onSignedIn(session)
            }
        }
        .onChange(of: linkViewModel.phase) { _, new in
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
