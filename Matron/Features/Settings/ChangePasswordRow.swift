import SwiftUI
import UIKit
import MatronJournal
import MatronViewModels

/// Settings → Security: the "Change password" row, the sheet it opens and,
/// once the sheet has closed on a change, the confirmation under the row.
struct ChangePasswordRow: View {
    @State private var model: ChangePasswordModel
    @State private var showingForm = false

    init(api: any PasswordChanging) {
        _model = State(initialValue: ChangePasswordModel(api: api))
    }

    var body: some View {
        Group {
            Button {
                model.begin()
                showingForm = true
            } label: {
                Label(ChangePasswordModel.title, systemImage: "key")
            }
            .accessibilityIdentifier("settings.changePassword")
            if let success = model.successMessage {
                Label(success, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.changePassword.done")
            }
        }
        .sheet(isPresented: $showingForm, onDismiss: { model.end() }) {
            ChangePasswordSheet(model: model) { showingForm = false }
        }
    }
}

/// The form itself: current, new and confirm, the sign-out toggle, and the
/// button. Closes itself once the password has changed.
private struct ChangePasswordSheet: View {
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
                Section {
                    Toggle(ChangePasswordModel.signOutOthersLabel, isOn: $model.signOutOthers)
                        .accessibilityIdentifier("changePassword.signOutOthers")
                } footer: {
                    Text(ChangePasswordModel.signOutOthersHelp)
                }
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
