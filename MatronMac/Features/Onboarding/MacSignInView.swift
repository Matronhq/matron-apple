import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels
import MatronDesignSystem

struct MacSignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    @State var rendezvousViewModel: RendezvousSignInViewModel
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
                    // Spec §4 (compromised-relay mitigation): when this wait
                    // came from the rendezvous handoff, keep the offered
                    // server host visible for the ENTIRE approval wait, not
                    // just the sub-second claim — a manual-code claimant
                    // flow (rendezvousViewModel not .connecting) keeps the
                    // plain copy above unchanged.
                    if case .connecting(let host) = rendezvousViewModel.phase {
                        Text("Signing in to \(host) — approve the request on your signed-in device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        linkViewModel.cancel()
                        // The rendezvous VM parks in .connecting once it
                        // hands off to linkViewModel
                        // (RendezvousSignInViewModel.startPolling); cancel()
                        // above only resets linkViewModel, so without this
                        // the show area re-renders a permanently-spinning
                        // "Connecting to <host>…" with no recovery. Mac has
                        // no Scan tab (no camera), so — unlike iOS's
                        // qrTab-guarded version of this same fix — Show is
                        // always the active mode and restarting is
                        // unconditional once .connecting is confirmed stuck.
                        if case .connecting = rendezvousViewModel.phase {
                            rendezvousViewModel.stop()
                            Task { await rendezvousViewModel.start() }
                        }
                    }
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

                // Mac cannot scan, so there is no Scan/Show tab picker — the
                // rendezvous QR is the default and only tab on Mac (spec §2).
                rendezvousShow

                // The rendezvous VM parks in .connecting once it hands off to
                // linkViewModel; a link-side error (denial, expiry, persist
                // failure) can arrive later on linkViewModel's own claim/poll
                // loop, well after rendezvousShow above has stopped rendering
                // (see its guard). This is the single error surface + restart
                // path for that — unconditional on showingLinkCode, since Mac
                // has no Scan tab and the rendezvous flow is always live.
                if case .error(let message) = linkViewModel.phase {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                        // Reset linkViewModel to .idle before restarting the
                        // rendezvous VM: rendezvousShow suppresses itself
                        // while linkViewModel.phase is .error, so a fresh QR
                        // minted without this reset would stay hidden behind
                        // the stale error phase — a dead-end button.
                        Button("Show a new code") {
                            linkViewModel.cancel()
                            Task { await rendezvousViewModel.start() }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }

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
                            TextField("XXXX-XXXX or matron:// link", text: $linkViewModel.codeInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("signin.linkcode")
                        }
                        Button("Sign in with code") {
                            linkViewModel.serverURL = viewModel.serverURL
                            Task { await linkViewModel.submitManual() }
                        }
                        // A pasted matron:// link names its own server, so it
                        // doesn't need the form's server field.
                        .disabled(!linkViewModel.codeInputIsFullLink
                                  && (viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9))
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 640)
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
        .task { await rendezvousViewModel.start() }
        // Same gap as SignInView: cancel any in-flight link claim/poll when
        // this view goes away (e.g. password sign-in navigated on) so a later
        // Approve on the show device can't persist a session over the active
        // one. The .signedIn forwarding above runs first (the phase mutation
        // happens while this view is still mounted); disappearance is a
        // downstream effect of onSignedIn.
        .onDisappear {
            rendezvousViewModel.stop()
            linkViewModel.cancel() // existing line — keep
        }
    }

    /// Show-only rendezvous QR: Mac has no camera, so this is the sign-in
    /// screen's default and only "from another device" surface (mirrors
    /// iOS SignInView's `.show` tab — spec §2).
    @ViewBuilder private var rendezvousShow: some View {
        // The rendezvous VM checks linkViewModel's phase once, synchronously
        // after submitManual(), and then parks in .connecting — it never
        // reacts to linkViewModel reaching .error later on its own
        // claim/poll loop (denial, expiry, persist failure). Once that
        // happens, render nothing here: the link-error text + "Show a new
        // code" button (below) is the single error surface and recovery
        // path, so a stale "Connecting to <host>…" (or a second, redundant
        // rendezvous-error/Retry in the synchronous-failure case) never
        // renders alongside it.
        if case .error = linkViewModel.phase {
            EmptyView()
        } else {
            switch rendezvousViewModel.phase {
            case .idle, .loading:
                ProgressView()
            case .showing(let payload):
                VStack(spacing: 12) {
                    QRCodeView(string: payload)
                        .frame(width: 200, height: 200)
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
