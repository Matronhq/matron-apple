#if os(macOS)
import SwiftUI
import AppKit
import MatronJournal
import MatronViewModels

/// Mac twin of `AccountEmailRow`: Settings → Security, the Email address row
/// and its Edit… button. Hidden on a journal without account email.
/// `onEdit` opens the sheet, which the settings form presents.
struct MacAccountEmailRow: View {
    let model: AccountEmailModel
    let onEdit: () -> Void

    var body: some View {
        if model.isShown {
            LabeledContent {
                HStack(spacing: 8) {
                    switch model.phase {
                    case .loading: ProgressView().controlSize(.small)
                    case .failed: Text("Unknown").foregroundStyle(.secondary)
                    default:
                        Text(model.valueText ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("settings.accountEmail.value")
                    }
                    if model.canEdit {
                        Button("\(AccountEmailModel.editTitle)…", action: onEdit)
                            .accessibilityIdentifier("settings.accountEmail.edit")
                    }
                }
            } label: {
                Text(AccountEmailModel.title)
                Text(model.helpText)
            }
        }
    }
}

/// The Edit form: the address and the current password, Save, and Remove
/// while an address is on file. Closes itself once the journal has stored it.
struct MacAccountEmailSheet: View {
    @Bindable var model: AccountEmailModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccountEmailModel.title)
                .font(.system(size: 17, weight: .semibold))
            Text(AccountEmailModel.help)
                .font(.callout)
                .foregroundStyle(.secondary)
            field(AccountEmailModel.fieldLabel) {
                TextField("", text: $model.email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("accountEmail.email")
            }
            field(AccountEmailModel.passwordLabel) {
                SecureField("", text: $model.password)
                    .textContentType(.password)
                    .accessibilityIdentifier("accountEmail.password")
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if model.hasEmail {
                    Button(AccountEmailModel.removeTitle, role: .destructive) {
                        Task { if await model.remove() { close() } }
                    }
                    .disabled(!model.canRemove)
                    .accessibilityIdentifier("accountEmail.remove")
                }
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(AccountEmailModel.saveTitle) {
                    Task { if await model.save() { close() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("accountEmail.save")
            }
        }
        .padding(20)
        .frame(width: 380)
        .disabled(model.isSaving)
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}
#endif
