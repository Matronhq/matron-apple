import SwiftUI
import UIKit
import MatronJournal
import MatronViewModels

/// Settings → Security: the Password row, with Change Password and, once
/// its sheet has closed on a change, the confirmation in place of the
/// row's help line. `onChange` opens the sheet, which the settings form
/// presents.
struct ChangePasswordRow: View {
    let model: ChangePasswordModel
    let onChange: () -> Void

    var body: some View {
        LabeledContent {
            Button(ChangePasswordModel.title, action: onChange)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.changePassword")
        } label: {
            Text(ChangePasswordModel.rowTitle)
            if let success = model.successMessage {
                Text(success)
                    .accessibilityIdentifier("settings.changePassword.done")
            } else {
                Text(ChangePasswordModel.rowHelp)
            }
        }
    }
}

/// The form itself: current, new and confirm, the sign-out toggle, and the
/// button. Closes itself once the password has changed.
struct ChangePasswordSheet: View {
    @Bindable var model: ChangePasswordModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(ChangePasswordModel.currentLabel, text: $model.currentPassword)
                        .textContentType(.password)
                        .accessibilityIdentifier("changePassword.current")
                    SecureField(ChangePasswordModel.newLabel, text: $model.newPassword)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("changePassword.new")
                    SecureField(ChangePasswordModel.confirmLabel, text: $model.confirmPassword)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("changePassword.confirm")
                }
                .disabled(model.isSubmitting)
                Section {
                    Toggle(ChangePasswordModel.signOutOthersLabel, isOn: $model.signOutOthers)
                        .accessibilityIdentifier("changePassword.signOutOthers")
                } footer: {
                    Text(ChangePasswordModel.signOutOthersHelp)
                }
                .disabled(model.isSubmitting)
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { if await model.submit() { close() } }
                    } label: {
                        if model.isSubmitting {
                            ProgressView()
                        } else {
                            Text(ChangePasswordModel.title)
                        }
                    }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("changePassword.submit")
                }
            }
            .navigationTitle(ChangePasswordModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: close)
                        .disabled(model.isSubmitting)
                }
            }
            .interactiveDismissDisabled(model.isSubmitting)
        }
    }
}
