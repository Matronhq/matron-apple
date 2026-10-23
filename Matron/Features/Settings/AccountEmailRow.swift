import SwiftUI
import UIKit
import MatronJournal
import MatronViewModels

/// Settings → Security: the Email address row (the address a password-reset
/// link goes to) and the Edit sheet that changes or removes it. Hidden on
/// a journal without account email.
struct AccountEmailRow: View {
    @State private var model: AccountEmailModel
    @State private var editing = false

    init(api: any AccountEmailProviding) {
        _model = State(initialValue: AccountEmailModel(api: api))
    }

    var body: some View {
        Group {
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
                            Button(AccountEmailModel.editTitle) {
                                model.beginEdit()
                                editing = true
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("settings.accountEmail.edit")
                        }
                    }
                } label: {
                    Text(AccountEmailModel.title)
                    Text(model.helpText)
                }
                .sheet(isPresented: $editing, onDismiss: { model.endEdit() }) {
                    AccountEmailSheet(model: model) { editing = false }
                }
            }
        }
        .task { await model.refresh() }
    }
}

/// The Edit form: the address and the current password, Save, and Remove
/// while an address is on file. Closes itself once the journal has stored it.
private struct AccountEmailSheet: View {
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
