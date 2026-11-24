import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels
import MatronDesignSystem

struct SignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    @State var rendezvousViewModel: RendezvousSignInViewModel
    var onSignedIn: (UserSession) -> Void

    enum Method: Hashable { case login, device }
    enum QRTab: String, CaseIterable { case scan = "Scan", show = "Show", code = "Code" }
    @State private var path: [Method] = []
    @State private var showingScanner = false
    @State private var qrTab: QRTab = .scan
    @State private var rendezvousAttempt = 0

    private var showingRendezvous: Bool { path.last == .device && qrTab == .show }
    private var rendezvousTaskID: Int? { showingRendezvous ? rendezvousAttempt : nil }
    private var linkMethodSelection: Binding<QRTab> {
        Binding(get: { qrTab }, set: { next in
            guard next != qrTab else { return }
            // Invalidate the old method before a new Show task can start.
            rendezvousViewModel.stop()
            linkViewModel.cancel()
            qrTab = next
        })
    }

    var body: some View {
        NavigationStack(path: $path) {
            methodPicker
                .navigationTitle("Sign in to Matron")
                .navigationDestination(for: Method.self) { method in
                    switch method {
                    case .login: passwordSignIn
                    case .device: deviceSignIn
                    }
                }
        }
        .sheet(isPresented: $viewModel.isShowingForgotPassword,
               onDismiss: { viewModel.closeForgotPassword() }) {
            ForgotPasswordSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.state) { _, new in
            if case .signedIn(let session) = new { onSignedIn(session) }
        }
        .onChange(of: linkViewModel.phase) { _, new in
            if case .signedIn(let session) = new { onSignedIn(session) }
        }
        .onChange(of: path) { old, new in
            if old.last == .device, new.last != .device {
                rendezvousViewModel.stop()
                linkViewModel.cancel()
                qrTab = .scan
            }
        }
        .task(id: rendezvousTaskID) {
            guard showingRendezvous, !Task.isCancelled else { return }
            await rendezvousViewModel.start()
        }
        .onDisappear {
            rendezvousViewModel.stop()
            linkViewModel.cancel()
        }
        .fullScreenCover(isPresented: $showingScanner) {
            QRScannerView { payload in
                Task { await linkViewModel.handleScanned(payload) }
            }
        }
    }

    private var methodPicker: some View {
        Form {
            MatronGroupedRows {
                Section {
                    Image("app-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                .listRowBackground(Color.clear)
                signOutNotice
                Section {
                    NavigationLink(value: Method.login) {
                        methodLabel("Sign in with a login", detail: "Use your server, username and password.", icon: "person.crop.circle")
                    }
                    .accessibilityIdentifier("signin.chooseLogin")
                    NavigationLink(value: Method.device) {
                        methodLabel("Sign in from another device", detail: "Use a QR code or a link code.", icon: "qrcode")
                    }
                    .accessibilityIdentifier("signin.chooseDevice")
                }
            }
        }
    }

    private func methodLabel(_ title: String, detail: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: icon)
        }
    }

    @ViewBuilder private var signOutNotice: some View {
        if let notice = viewModel.notice, viewModel.step == .password {
            Section {
                Label(notice, systemImage: "exclamationmark.circle")
                    .accessibilityIdentifier("signin.notice")
            }
        }
    }

    private var passwordSignIn: some View {
        Form {
            MatronGroupedRows {
                if viewModel.step != .password {
                    TwoFactorSignInSections(viewModel: viewModel)
                } else {
                    signOutNotice
                    serverField
                    Section("Credentials") {
                        TextField("Username", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin.username")
                        SecureField("Password", text: $viewModel.password)
                            .accessibilityIdentifier("signin.password")
                        if viewModel.forgotPasswordAvailable {
                            Button(SignInViewModel.forgotLinkTitle) { viewModel.openForgotPassword() }
                                .accessibilityIdentifier("signin.forgotPassword")
                        }
                    }
                    if case .error(let message) = viewModel.state {
                        Section { Text(message).foregroundStyle(.red) }
                    }
                    Section {
                        Button {
                            Task { await viewModel.submit() }
                        } label: {
                            if case .busy = viewModel.state { ProgressView() }
                            else { Text("Sign in") }
                        }
                        .disabled(viewModel.state == .busy || viewModel.serverURL.isEmpty
                                  || viewModel.username.isEmpty || viewModel.password.isEmpty)
                        .accessibilityIdentifier("signin.submit")
                    }
                }
            }
        }
        .navigationTitle("Sign in with a login")
        .navigationBarTitleDisplayMode(.inline)
        // Keep an in-flight password response on its own screen. Two-factor
        // screens already provide their own safe return to the password step.
        .navigationBarBackButtonHidden(viewModel.state == .busy || viewModel.step != .password)
        .scrollDismissesKeyboard(.interactively)
        .task(id: viewModel.serverURL) {
            guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
            await viewModel.checkPasswordReset()
        }
    }

    private var serverField: some View {
        Section("Server") {
            // URL-shaped placeholders are styled as links by iOS Forms.
            TextField("Server URL", text: $viewModel.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("signin.server")
        }
    }

    private var deviceSignIn: some View {
        Form {
            MatronGroupedRows {
                if case .waitingForApproval = linkViewModel.phase {
                    linkWaiting
                } else {
                    Section {
                        Picker("Link method", selection: linkMethodSelection) {
                            ForEach(QRTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("signin.qrtab")
                        .disabled(linkViewModel.phase == .claiming)
                    }
                    linkSignIn
                }
            }
        }
        .navigationTitle("From another device")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var linkSignIn: some View {
        if qrTab == .code, !linkViewModel.codeInputIsFullLink {
            serverField
        }
        Section {
            switch qrTab {
            case .scan:
                Button { showingScanner = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("signin.scan")
                .disabled(linkViewModel.phase == .claiming)
            case .show:
                rendezvousShow
            case .code:
                TextField("XXXX-XXXX or matron:// link", text: $linkViewModel.codeInput)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("signin.linkcode")
                Button {
                    linkViewModel.serverURL = viewModel.serverURL
                    Task { await linkViewModel.submitManual() }
                } label: {
                    if case .claiming = linkViewModel.phase { ProgressView() }
                    else { Text("Sign in with code") }
                }
                .disabled(linkViewModel.phase == .claiming || (!linkViewModel.codeInputIsFullLink
                          && (viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9)))
                .accessibilityIdentifier("signin.linkSubmit")
            }
        } footer: {
            if case .error(let message) = linkViewModel.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).foregroundStyle(.red)
                    if qrTab == .show {
                        Button("Show a new code") {
                            linkViewModel.cancel()
                            rendezvousAttempt += 1
                        }
                    }
                }
            } else if qrTab == .code {
                Text("In your signed-in browser or app, open Settings → Devices → Link a Device. Enter its server URL and link code here, or paste the full sign-in link.")
            } else if qrTab == .scan {
                Text("On your signed-in device, open Settings → Devices → Link a Device, then scan its QR code here.")
            }
        }
    }

    @ViewBuilder private var rendezvousShow: some View {
        // The rendezvous VM checks linkViewModel's phase once, synchronously
        // after submitManual(), and then parks in .connecting — it never
        // reacts to linkViewModel reaching .error later on its own
        // claim/poll loop (denial, expiry, persist failure). Once that
        // happens, render nothing here: the footer's link-error text +
        // "Show a new code" button (below) is the single error surface and
        // recovery path, so a stale "Connecting to <host>…" (or a second,
        // redundant rendezvous-error/Retry in the synchronous-failure case)
        // never renders alongside it.
        if case .error = linkViewModel.phase {
            EmptyView()
        } else {
            switch rendezvousViewModel.phase {
            case .idle, .loading:
                ProgressView()
            case .showing(let payload):
                VStack(spacing: 12) {
                    QRCodeView(string: payload)
                        .frame(width: 220, height: 220)
                    Text("Scan this with a phone that's signed in to Matron")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .connecting(let host):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(host)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { rendezvousAttempt += 1 }
                }
            }
        }
    }

    @ViewBuilder private var linkWaiting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for approval on your other device…")
                    // Spec §4 (compromised-relay mitigation): when this wait
                    // came from the rendezvous handoff, keep the offered
                    // server host visible for the ENTIRE approval wait, not
                    // just the sub-second claim — a scan/manual claimant
                    // flow (rendezvousViewModel not .connecting) keeps the
                    // plain copy above unchanged.
                    if case .connecting(let host) = rendezvousViewModel.phase {
                        Text("Signing in to \(host) — approve the request on your signed-in device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                linkViewModel.cancel()
                // The rendezvous VM parks in .connecting once it hands off
                // to linkViewModel (RendezvousSignInViewModel.startPolling);
                // cancel() above only resets linkViewModel, so without this
                // the Show tab re-renders a permanently-spinning "Connecting
                // to <host>…" with no recovery. Only reset+restart when the
                // rendezvous VM is actually stuck there (never true for a
                // Scan-tab camera cancel — switching off the Show tab already
                // stops it via the qrTab onChange below — nor for a manual-
                // code cancel that leaves an unrelated live Show-tab QR
                // alone), and only restart it if Show is still the active
                // tab, so a Scan-tab cancel never spuriously starts polling.
                if case .connecting = rendezvousViewModel.phase {
                    rendezvousViewModel.stop()
                    if qrTab == .show { rendezvousAttempt += 1 }
                }
            }
        } footer: {
            Text("Approve the request on your signed-in device to finish.")
        }
    }
}
