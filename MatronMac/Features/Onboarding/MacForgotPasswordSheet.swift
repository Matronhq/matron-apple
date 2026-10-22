#if os(macOS)
import SwiftUI
import AppKit
import MatronViewModels

/// Mac twin of `ForgotPasswordSheet`: asks the journal to mail a reset
/// link to a username or email address, then always says the same thing,
/// so it never reveals whether an account exists. The link itself is
/// finished in Matron Web.
struct MacForgotPasswordSheet: View {
    @Bindable var viewModel: SignInViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SignInViewModel.forgotLinkTitle)
                .font(.system(size: 17, weight: .semibold))
            if viewModel.forgotState == .sent {
                Text(SignInViewModel.forgotPasswordSent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("forgotPassword.sent")
                HStack {
                    Spacer(minLength: 0)
                    Button(SignInViewModel.forgotBackTitle) { viewModel.closeForgotPassword() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("forgotPassword.back")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SignInViewModel.forgotIdentifierLabel).font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $viewModel.forgotIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .disabled(viewModel.forgotState == .sending)
                        .accessibilityLabel(SignInViewModel.forgotIdentifierLabel)
                        .accessibilityIdentifier("forgotPassword.identifier")
                }
                if case .error(let message) = viewModel.forgotState {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if viewModel.forgotState == .sending { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button(SignInViewModel.forgotBackTitle, role: .cancel) { viewModel.closeForgotPassword() }
                        .keyboardShortcut(.cancelAction)
                    Button(SignInViewModel.forgotSubmitTitle) {
                        Task { await viewModel.submitForgotPassword() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canSendForgotPassword)
                    .accessibilityIdentifier("forgotPassword.submit")
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
#endif
