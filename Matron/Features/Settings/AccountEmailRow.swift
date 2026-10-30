import SwiftUI
import UIKit
import MatronJournal
import MatronViewModels

/// Settings → Security: the Email address row (the address a password-reset
/// link goes to) and its Edit button. Hidden on a journal without account
/// email. `onEdit` opens the sheet, which the settings form presents.
struct AccountEmailRow: View {
    let model: AccountEmailModel
    let onEdit: () -> Void

    var body: some View {
        if model.isShown {
            LabeledContent {
                HStack(spacing: 12) {
                    switch model.phase {
                    case .loading: ProgressView()
                    case .failed: Text("Unknown").foregroundStyle(.secondary)
                    default:
                        Text(model.valueText ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("settings.accountEmail.value")
                    }
                    if model.canEdit {
                        Button(AccountEmailModel.editTitle, action: onEdit)
                        .buttonStyle(.borderless)
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
struct AccountEmailSheet: View {
    @Bindable var model: AccountEmailModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AccountEmailModel.fieldLabel, text: $model.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("accountEmail.email")
                    SecureField(AccountEmailModel.passwordLabel, text: $model.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("accountEmail.password")
                } footer: {
                    Text(AccountEmailModel.help)
                }
                .disabled(model.isSaving)
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { if await model.save() { close() } }
                    } label: {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text(AccountEmailModel.saveTitle)
                        }
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("accountEmail.save")
                    if model.hasEmail {
                        Button(AccountEmailModel.removeTitle, role: .destructive) {
                            Task { if await model.remove() { close() } }
                        }
                        .disabled(!model.canRemove)
                        .accessibilityIdentifier("accountEmail.remove")
                    }
                }
            }
            .navigationTitle(AccountEmailModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: close)
                        .disabled(model.isSaving)
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}
