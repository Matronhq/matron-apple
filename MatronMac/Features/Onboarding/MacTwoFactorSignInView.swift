#if os(macOS)
import SwiftUI
import AppKit
import MatronAuth
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// The two-factor steps of `MacSignInView`, in place of the password form:
/// the code step, setting up an authenticator when the server requires one,
/// and the recovery codes. Mirrors iOS `TwoFactorSignInSections`.
struct MacTwoFactorSignInView: View {
    @Bindable var viewModel: SignInViewModel
    @FocusState private var codeFocused: Bool
    @State private var copiedSetupKey = false
    @State private var copiedCodes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.step {
            case .password:
                EmptyView()
            case .code(let challenge):
                heading("Two-factor code",
                        "Enter the 6-digit code from your authenticator app for \(challenge.username).")
                codeEntry(submitTitle: "Verify", allowsRecoveryCode: true)
                backToPassword
            case .enrol(_, let setup):
                enrolment(setup)
            case .recoveryCodes(_, let codes):
                recoveryCodes(codes)
            case .usedRecoveryCode(_, let left):
                heading("Recovery code used", SignInViewModel.recoveryCodeWarning(left: left))
                    .accessibilityIdentifier("signin.2fa.recoveryWarning")
                Button {
                    viewModel.continueSignedIn()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.2fa.continue")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Code entry

    @ViewBuilder private func codeEntry(submitTitle: String, allowsRecoveryCode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.usesRecoveryCode ? "Recovery code" : "Code")
                .font(.caption).foregroundStyle(.secondary)
            TextField(viewModel.usesRecoveryCode ? "xxxx-xxxx-xxxx-xxxx" : "123456", text: $viewModel.code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .onSubmit { Task { await viewModel.submitCode() } }
                .onChange(of: viewModel.code) { _, new in
                    guard !viewModel.usesRecoveryCode else { return }
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { viewModel.code = digits }
                }
                .accessibilityIdentifier("signin.2fa.code")
        }
        .onAppear { codeFocused = true }

        if case .error(let message) = viewModel.state {
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .accessibilityIdentifier("signin.2fa.error")
        }

        Button {
            Task { await viewModel.submitCode() }
        } label: {
            if case .busy = viewModel.state {
                ProgressView().controlSize(.small)
            } else {
                Text(submitTitle).frame(maxWidth: .infinity)
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled({
            if case .busy = viewModel.state { return true }
            return !viewModel.codeIsComplete
        }())
        .accessibilityIdentifier("signin.2fa.submit")

        if allowsRecoveryCode {
            Button(viewModel.usesRecoveryCode ? "Use an authenticator code" : "Use a recovery code instead") {
                viewModel.usesRecoveryCode.toggle()
                viewModel.code = ""
                codeFocused = true
            }
            .buttonStyle(.link)
            .font(.callout)
            .accessibilityIdentifier("signin.2fa.toggleRecovery")
        }
    }

    private var backToPassword: some View {
        Button("Back to sign in") { viewModel.cancelTwoFactor() }
            .buttonStyle(.link)
            .font(.callout)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("signin.2fa.back")
    }

    // MARK: Enrolment

    @ViewBuilder private func enrolment(_ setup: TwoFactorSetup?) -> some View {
        heading("Set up two-factor",
                "This server requires two-factor sign-in. Scan the code with an authenticator app such as Google Authenticator or 1Password, then enter the code it shows.")
        if let setup {
            HStack(alignment: .top, spacing: 16) {
                QRCodeView(string: setup.otpauthURI)
                    .frame(width: 140, height: 140)
                    .accessibilityLabel("QR code for your authenticator app")
                VStack(alignment: .leading, spacing: 8) {
                    if let url = URL(string: setup.otpauthURI) {
                        Link(destination: url) {
                            Label("Open in authenticator", systemImage: "arrow.up.forward.app")
                        }
                        .accessibilityIdentifier("signin.2fa.openAuthenticator")
                    }
                    Button {
                        copy(setup.secret)
                        copiedSetupKey = true
                    } label: {
                        Label(copiedSetupKey ? "Setup key copied" : "Copy setup key",
                              systemImage: copiedSetupKey ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("signin.2fa.copyKey")
                    Text(TwoFactorSecretFormat.grouped(setup.secret))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(setup.account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            codeEntry(submitTitle: "Turn on and sign in", allowsRecoveryCode: false)
        } else if case .error(let message) = viewModel.state {
            Text(message).foregroundStyle(.red).font(.callout)
            Button("Try again") { Task { await viewModel.retryEnrolment() } }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
        backToPassword
    }

    // MARK: Recovery codes

    @ViewBuilder private func recoveryCodes(_ codes: [String]) -> some View {
        heading("Recovery codes",
                "Two-factor is on. Save these recovery codes somewhere safe. Each one signs you in once if you lose your authenticator. They won't be shown again.")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(codes, id: \.self) { code in
                Text(code).font(.system(.body, design: .monospaced))
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        HStack {
            Button {
                copy(SignInViewModel.recoveryCodesText(codes))
                copiedCodes = true
            } label: {
                Label(copiedCodes ? "Copied" : "Copy", systemImage: copiedCodes ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("signin.2fa.copyCodes")
            ShareLink(item: SignInViewModel.recoveryCodesText(codes)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button {
            viewModel.continueSignedIn()
        } label: {
            Text("I've saved these").frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("signin.2fa.saved")
    }

    /// Copies a setup key or recovery codes. The concealed marker asks
    /// clipboard managers not to keep it (nspasteboard.org), and the copy
    /// is cleared after two minutes unless something else was copied since.
    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        }
    }
}
#endif
