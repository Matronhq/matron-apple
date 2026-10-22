import SwiftUI
import UIKit
import MatronViewModels

/// Sign-in → "Forgot password?": asks the journal to mail a reset link to
/// a username or email address. Once sent it always says the same thing,
/// so it never reveals whether an account exists. The link itself is
/// finished in Matron Web.
struct ForgotPasswordSheet: View {
    @Bindable var viewModel: SignInViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.forgotState == .sent {
                    Section {
                        Text(SignInViewModel.forgotPasswordSent)
                            .accessibilityIdentifier("forgotPassword.sent")
                    }
                    Section {
                        Button(SignInViewModel.forgotBackTitle) { viewModel.closeForgotPassword() }
                            .accessibilityIdentifier("forgotPassword.back")
                    }
                } else {
                    Section {
                        TextField(SignInViewModel.forgotIdentifierLabel, text: $viewModel.forgotIdentifier)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(viewModel.forgotState == .sending)
                            .accessibilityIdentifier("forgotPassword.identifier")
                    }
                    if case .error(let message) = viewModel.forgotState {
                        Section {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                    Section {
                        Button {
                            Task { await viewModel.submitForgotPassword() }
                        } label: {
                            if viewModel.forgotState == .sending {
                                ProgressView()
                            } else {
                                Text(SignInViewModel.forgotSubmitTitle)
                            }
                        }
                        .disabled(!viewModel.canSendForgotPassword)
                        .accessibilityIdentifier("forgotPassword.submit")
                    }
                }
            }
            .navigationTitle(SignInViewModel.forgotLinkTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.forgotState != .sent {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(SignInViewModel.forgotBackTitle) { viewModel.closeForgotPassword() }
                    }
                }
            }
        }
    }
}
