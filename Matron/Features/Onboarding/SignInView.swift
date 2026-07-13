import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct SignInView: View {
    @State var viewModel: SignInViewModel
    var onSignedIn: (UserSession) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("app-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                .listRowBackground(Color.clear)
                Section("Server") {
                    // Placeholder kept URL-shape-free because iOS Form's
                    // data detection styles `https://…` placeholders as
                    // tappable blue link text — looks like an error /
                    // link, not a hint.
                    TextField("Homeserver URL", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("signin.server")
                }
                Section("Credentials") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin.username")
                    SecureField("Password", text: $viewModel.password)
                        .accessibilityIdentifier("signin.password")
                }
                if case .error(let message) = viewModel.state {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await viewModel.submit() }
                    } label: {
                        if case .busy = viewModel.state {
                            ProgressView()
                        } else {
                            Text("Sign in")
                        }
                    }
                    .disabled({
                        if case .busy = viewModel.state { return true }
                        return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
                    }())
                    .accessibilityIdentifier("signin.submit")
                }
            }
            .navigationTitle("Sign in to Matron")
            .onChange(of: viewModel.state) { _, new in
                if case .signedIn(let session) = new {
                    onSignedIn(session)
                }
            }
        }
    }
}
