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

    @State private var showingScanner = false
    @State private var showingManualCode = false
    private enum QRTab: String, CaseIterable { case scan = "Scan", show = "Show" }
    @State private var qrTab: QRTab = .scan

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
            // Cancel any in-flight link claim/poll when this view goes away
            // (e.g. password sign-in navigated on): otherwise a later Approve
            // on the show device could persist a different session over the
            // active one. The .signedIn forwarding above runs first — the
            // phase mutation (and its onChange) happens while this view is
            // still mounted; disappearance is a downstream effect of
            // onSignedIn swapping the root, so cancel() here only ever fires
            // after the session was already forwarded. A presented scanner
            // covers (does not remove) this view, so opening it won't cancel.
            .onChange(of: qrTab) { _, tab in
                if tab == .show { Task { await rendezvousViewModel.start() } }
                else { rendezvousViewModel.stop() }
            }
            .onDisappear {
                rendezvousViewModel.stop()
                linkViewModel.cancel() // existing line — keep
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView { payload in
                    Task { await linkViewModel.handleScanned(payload) }
                }
            }
        }
    }

    /// "Or sign in from another device": camera scan / show-QR tabs + manual
    /// code entry.
    @ViewBuilder private var linkSignIn: some View {
        Section {
            Picker("QR mode", selection: $qrTab) {
                ForEach(QRTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("signin.qrtab")

            switch qrTab {
            case .scan:
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("signin.scan")
            case .show:
                rendezvousShow
            }

            Button(showingManualCode ? "Hide link code" : "Have a link code?") {
                showingManualCode.toggle()
            }
            .font(.callout)
            if showingManualCode {
                TextField("XXXX-XXXX or matron:// link", text: $linkViewModel.codeInput)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("signin.linkcode")
                Button("Sign in with code") {
                    // The manual path shares the form's server field.
                    linkViewModel.serverURL = viewModel.serverURL
                    Task { await linkViewModel.submitManual() }
                }
                // A pasted matron:// link names its own server, so it
                // doesn't need the form's server field.
                .disabled(!linkViewModel.codeInputIsFullLink
                          && (viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9))
            }
        } header: {
            Text("From another device")
        } footer: {
            if case .error(let message) = linkViewModel.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).foregroundStyle(.red)
                    // The rendezvous VM parks in .connecting once it hands
                    // off to linkViewModel; a link-side error while Show is
                    // selected still needs a way back to a fresh QR. Reset
                    // linkViewModel to .idle first: rendezvousShow suppresses
                    // itself while linkViewModel.phase is .error, so
                    // restarting the rendezvous VM alone would mint a new QR
                    // that stays hidden behind the stale error phase — a
                    // dead-end button that appears to do nothing.
                    if qrTab == .show {
                        Button("Show a new code") {
                            linkViewModel.cancel()
                            Task { await rendezvousViewModel.start() }
                        }
                    }
                }
            } else if showingManualCode {
                Text("On your signed-in device: Settings → Link a Device. Enter the server URL above and the code shown under the QR.")
            } else {
                Text("Signed in on another device? Show its QR under Settings → Link a Device and scan it here.")
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
                    Button("Retry") { Task { await rendezvousViewModel.start() } }
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
                    if qrTab == .show { Task { await rendezvousViewModel.start() } }
                }
            }
        } footer: {
            Text("Approve the request on your signed-in device to finish.")
        }
    }
}
