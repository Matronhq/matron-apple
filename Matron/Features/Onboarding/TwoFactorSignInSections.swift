import SwiftUI
import MatronAuth
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// The two-factor steps of `SignInView`, as `Form` sections in place of
/// the password form: the code step, setting up an authenticator when
/// the server requires one, and the recovery codes.
struct TwoFactorSignInSections: View {
    @Bindable var viewModel: SignInViewModel
    @FocusState private var codeFocused: Bool

    var body: some View {
        switch viewModel.step {
        case .password:
            EmptyView()
        case .code(let challenge):
            Section {
                Text("Enter the 6-digit code from your authenticator app for \(challenge.username).")
            } header: {
                Text("Two-factor code")
            }
            codeEntry(submitTitle: "Verify", allowsRecoveryCode: true)
            backToPassword
        case .enrol(_, let setup):
            enrolment(setup)
        case .recoveryCodes(_, let codes):
            recoveryCodes(codes)
        case .usedRecoveryCode(_, let left):
            Section {
                Label(SignInViewModel.recoveryCodeWarning(left: left), systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("signin.2fa.recoveryWarning")
            } header: {
                Text("Recovery code used")
            }
            Section {
                Button("Continue") { viewModel.continueSignedIn() }
                    .accessibilityIdentifier("signin.2fa.continue")
            }
        }
    }

    // MARK: Code entry

    @ViewBuilder private func codeEntry(submitTitle: String, allowsRecoveryCode: Bool) -> some View {
        Section {
            if viewModel.usesRecoveryCode {
                TextField("xxxx-xxxx-xxxx-xxxx", text: $viewModel.code)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await viewModel.submitCode() } }
                    .accessibilityIdentifier("signin.2fa.code")
            } else {
                TextField("123456", text: $viewModel.code)
                    .font(.system(.title2, design: .monospaced))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .onChange(of: viewModel.code) { _, new in
                        // Digits only, at most six: an autofilled or pasted
                        // code may carry a space in the middle.
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { viewModel.code = digits }
                        if digits.count == 6 { Task { await viewModel.submitCode() } }
                    }
                    .accessibilityIdentifier("signin.2fa.code")
            }
            if case .error(let message) = viewModel.state {
                Text(message).foregroundStyle(.red)
                    .accessibilityIdentifier("signin.2fa.error")
            }
            Button {
                Task { await viewModel.submitCode() }
            } label: {
                if case .busy = viewModel.state {
                    ProgressView()
                } else {
                    Text(submitTitle)
                }
            }
            .disabled({
                if case .busy = viewModel.state { return true }
                return !viewModel.codeIsComplete
            }())
            .accessibilityIdentifier("signin.2fa.submit")
        } footer: {
            if allowsRecoveryCode {
                Button(viewModel.usesRecoveryCode ? "Use an authenticator code" : "Use a recovery code instead") {
                    viewModel.usesRecoveryCode.toggle()
                    viewModel.code = ""
                    codeFocused = true
                }
                .font(.callout)
                .accessibilityIdentifier("signin.2fa.toggleRecovery")
            }
        }
        .onAppear { codeFocused = true }
    }

    private var backToPassword: some View {
        Section {
            Button("Back to sign in", role: .cancel) { viewModel.cancelTwoFactor() }
                .accessibilityIdentifier("signin.2fa.back")
        }
    }

    // MARK: Enrolment

    @ViewBuilder private func enrolment(_ setup: TwoFactorSetup?) -> some View {
        Section {
            Text("This server requires two-factor sign-in. Add Matron to an authenticator app such as Google Authenticator or 1Password, then enter the code it shows.")
        } header: {
            Text("Set up two-factor")
        }
        if let setup {
            TwoFactorSetupKeySection(setup: setup)
            codeEntry(submitTitle: "Turn on and sign in", allowsRecoveryCode: false)
        } else if case .error(let message) = viewModel.state {
            Section {
                Text(message).foregroundStyle(.red)
                Button("Try again") { Task { await viewModel.retryEnrolment() } }
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
        backToPassword
    }

    // MARK: Recovery codes

    @ViewBuilder private func recoveryCodes(_ codes: [String]) -> some View {
        Section {
            Text("Two-factor is on. Save these recovery codes somewhere safe. Each one signs you in once if you lose your authenticator. They won't be shown again.")
        } header: {
            Text("Recovery codes")
        }
        TwoFactorRecoveryCodesSection(codes: codes)
        Section {
            Button("I've saved these") { viewModel.continueSignedIn() }
                .accessibilityIdentifier("signin.2fa.saved")
        }
    }
}
