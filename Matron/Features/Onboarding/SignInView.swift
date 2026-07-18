import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct SignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    var onSignedIn: (UserSession) -> Void

    @State private var showingScanner = false
    @State private var showingManualCode = false

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
                if case .waitingForApproval = linkViewModel.phase {
                    linkWaiting
                } else {
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
                    linkSignIn
                }
            }
            .navigationTitle("Sign in to Matron")
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
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView { payload in
                    Task { await linkViewModel.handleScanned(payload) }
                }
            }
        }
    }

    /// "Or sign in from another device": camera scan + manual code entry.
    @ViewBuilder private var linkSignIn: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("signin.scan")
            Button(showingManualCode ? "Hide link code" : "Have a link code?") {
                showingManualCode.toggle()
            }
            .font(.callout)
            if showingManualCode {
                TextField("XXXX-XXXX", text: $linkViewModel.codeInput)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("signin.linkcode")
                Button("Sign in with code") {
                    // The manual path shares the form's server field.
                    linkViewModel.serverURL = viewModel.serverURL
                    Task { await linkViewModel.submitManual() }
                }
                .disabled(viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9)
            }
        } header: {
            Text("From another device")
        } footer: {
            if case .error(let message) = linkViewModel.phase {
                Text(message).foregroundStyle(.red)
            } else if showingManualCode {
                Text("On your signed-in device: Settings → Link a Device. Enter the server URL above and the code shown under the QR.")
            } else {
                Text("Signed in on another device? Show its QR under Settings → Link a Device and scan it here.")
            }
        }
    }

    @ViewBuilder private var linkWaiting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for approval on your other device…")
            }
            Button("Cancel", role: .cancel) { linkViewModel.cancel() }
        } footer: {
            Text("Approve the request on your signed-in device to finish.")
        }
    }
}
