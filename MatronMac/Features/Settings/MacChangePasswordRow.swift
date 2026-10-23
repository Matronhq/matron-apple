#if os(macOS)
import SwiftUI
import AppKit
import MatronJournal
import MatronViewModels

/// Mac twin of `ChangePasswordRow`: Settings → Security, the Password row
/// with Change Password…, the sheet it opens and, once the sheet has closed
/// on a change, the confirmation in place of the row's help line.
struct MacChangePasswordRow: View {
    @State private var model: ChangePasswordModel
    @State private var showingForm = false

    init(api: any PasswordChanging) {
        _model = State(initialValue: ChangePasswordModel(api: api))
    }

    var body: some View {
        LabeledContent {
            Button("\(ChangePasswordModel.title)…") {
                model.begin()
                showingForm = true
            }
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
        .sheet(isPresented: $showingForm, onDismiss: { model.end() }) {
            MacChangePasswordSheet(model: model) { showingForm = false }
        }
    }
}

/// The form itself: current, new and confirm, the sign-out toggle, and the
/// buttons. Closes itself once the password has changed.
private struct MacChangePasswordSheet: View {
    @Bindable var model: ChangePasswordModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChangePasswordModel.title)
                .font(.system(size: 17, weight: .semibold))
            field(ChangePasswordModel.currentLabel) {
                SecureField("", text: $model.currentPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("changePassword.current")
            }
            field(ChangePasswordModel.newLabel) {
                SecureField("", text: $model.newPassword)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("changePassword.new")
            }
            field(ChangePasswordModel.confirmLabel) {
                SecureField("", text: $model.confirmPassword)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("changePassword.confirm")
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(ChangePasswordModel.signOutOthersLabel, isOn: $model.signOutOthers)
                    .accessibilityIdentifier("changePassword.signOutOthers")
                Text(ChangePasswordModel.signOutOthersHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if model.isSubmitting { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSubmitting)
                Button(ChangePasswordModel.title) {
                    Task { if await model.submit() { close() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("changePassword.submit")
            }
        }
        .padding(20)
        .frame(width: 360)
        .disabled(model.isSubmitting)
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}
#endif
