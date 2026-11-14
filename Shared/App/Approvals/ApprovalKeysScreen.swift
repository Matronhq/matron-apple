import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronViewModels

/// Settings ▸ Approval keys, on both platforms: this device's key and its
/// fingerprint, requests from other devices waiting to be approved, and
/// every key of the account.
struct ApprovalKeysScreen: View {
    @Bindable var model: ApprovalKeysScreenModel
    @State private var removing: ApprovalKeysScreenModel.KeyRow?

    var body: some View {
        Form {
            MatronGroupedRows {
                thisDevice
                if !model.requests.isEmpty { requests }
                if !model.rows.isEmpty { keys }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(ApprovalKeysScreenModel.title)
        .task { await model.load() }
        .task(id: model.center.status == .waitingForApproval) {
            // While this device waits to be approved elsewhere, look again
            // every few seconds: nothing pushes the answer.
            guard model.center.status == .waitingForApproval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.load()
                if model.center.status != .waitingForApproval { return }
            }
        }
        .sheet(item: $model.form) { form in
            ApprovalKeyPasswordForm(model: model, form: form)
        }
        .confirmationDialog(
            removing.map { "Remove the approval key \($0.key.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let row = removing else { return }
                removing = nil
                Task { await model.remove(row.key) }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It will no longer approve anything, and can't be added back. Boxes that pin it keep trusting it until their key file is changed.")
        }
    }

    // MARK: This device

    private var thisDevice: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.statusSymbol)
                    .font(.title2)
                    .foregroundStyle(model.center.status == .ready ? Color.green : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusTitle).font(.headline)
                    if !model.statusDetail.isEmpty {
                        Text(model.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("approvalKeys.status")

            if let fingerprint = model.fingerprint {
                LabeledContent("Fingerprint") {
                    FingerprintText(fingerprint)
                }
                .accessibilityIdentifier("approvalKeys.fingerprint")
            }
            if model.canAttach {
                Button("Re-attach This Device's Key") { Task { await model.attach() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("approvalKeys.attach")
            }
            if model.canSetUp {
                Button(model.center.status == .waitingForApproval ? "Use Password and Code Instead" : "Set Up with Password and Code") {
                    model.beginSetUp()
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("approvalKeys.setUp")
            }
            if model.canAskAnotherDevice {
                Button("Ask a Device That Has a Key") { Task { await model.askAnotherDevice() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("approvalKeys.ask")
            }
            if model.form == nil, let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approvalKeys.error")
            }
        } header: {
            Text("This device")
        } footer: {
            Text(ApprovalKeysScreenModel.intro)
        }
    }

    // MARK: Requests

    private var requests: some View {
        Section {
            ForEach(model.requests) { request in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.name).font(.body)
                        FingerprintText(request.fingerprint)
                    }
                    Spacer()
                    Button("Approve…") { Task { await model.approve(request) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || !model.center.canSign)
                        .accessibilityIdentifier("approvalKeys.approve")
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Waiting to be added")
        } footer: {
            Text(model.center.canSign
                 ? "Approve only when the other device shows the same fingerprint."
                 : "Only a device that has a key can approve these.")
        }
    }

    // MARK: Keys

    private var keys: some View {
        Section {
            ForEach(model.rows) { row in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.key.name)
                                .font(.body)
                                .strikethrough(!row.isLive)
                                .foregroundStyle(row.isLive ? .primary : .secondary)
                            if row.isThisDevice {
                                Text("This device")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                        FingerprintText(row.key.fingerprint)
                        Text(row.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let state = row.state {
                            Text(state)
                                .font(.footnote)
                                .foregroundStyle(row.isLive ? Color.orange : Color.secondary)
                        }
                    }
                    Spacer()
                    if row.isLive {
                        Button("Remove", role: .destructive) { removing = row }
                            .buttonStyle(.borderless)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("approvalKeys.remove")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Keys on this account")
        } footer: {
            Text(ApprovalKeysScreenModel.pinningNote)
        }
    }
}

/// A key's short fingerprint, set in monospace and split in two so two
/// devices' are easy to compare by eye.
struct FingerprintText: View {
    let fingerprint: String

    init(_ fingerprint: String) { self.fingerprint = fingerprint }

    var body: some View {
        Text(verbatim: Self.grouped(fingerprint))
            .font(.callout.monospaced().weight(.medium))
            .textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: fingerprint.map(String.init).joined(separator: " ")))
    }

    /// "7734f909" → "7734 f909".
    static func grouped(_ fingerprint: String) -> String {
        guard fingerprint.count == 8 else { return fingerprint }
        return fingerprint.prefix(4) + " " + fingerprint.suffix(4)
    }
}

/// The password-and-code form: setting this device's key up, or removing a
/// key this device cannot sign for.
struct ApprovalKeyPasswordForm: View {
    @Bindable var model: ApprovalKeysScreenModel
    let form: ApprovalKeysScreenModel.Form

    private var title: String {
        switch form {
        case .setUp: return "Set Up a Key"
        case .remove: return "Remove Key"
        }
    }

    private var explanation: String {
        let method = model.center.method ?? "Face ID or Touch ID"
        switch form {
        case .setUp:
            return "A new key is made in this device's secure hardware and added to your account. Afterwards, dangerous actions need \(method) on a device that holds a key. A recovery code can't be used here."
        case .remove(let key):
            return "Removes \(key.name) (\(FingerprintText.grouped(key.fingerprint))) with your password and a code, because this device has no key to sign with."
        }
    }

    private var buttonTitle: String {
        switch form {
        case .setUp: return "Set Up"
        case .remove: return "Remove Key"
        }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            fields
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.closeForm() }.disabled(model.isBusy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(buttonTitle) { Task { await model.submitForm() } }
                            .disabled(!model.canSubmitForm)
                            .accessibilityIdentifier("approvalKeyForm.submit")
                    }
                }
        }
        .interactiveDismissDisabled(model.isBusy)
        #else
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding([.top, .horizontal], 20)
            fields
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.closeForm() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button(buttonTitle) { Task { await model.submitForm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmitForm)
                    .accessibilityIdentifier("approvalKeyForm.submit")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        #endif
    }

    private var fields: some View {
        Form {
            MatronGroupedRows {
                Section {
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("approvalKeyForm.password")
                    TextField("Code from your authenticator app", text: $model.code)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("approvalKeyForm.code")
                } footer: {
                    Text(explanation)
                }
                .disabled(model.isBusy)
                if let error = model.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approvalKeyForm.error")
                    }
                }
                if model.isBusy {
                    Section { ProgressView() }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// The Settings row that opens the keys screen, with where this device
/// stands under it.
struct ApprovalKeysRowLabel: View {
    let model: ApprovalKeysScreenModel

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ApprovalKeysScreenModel.title)
                    if !model.summary.isEmpty {
                        Text(model.summary)
                            .font(.footnote)
                            .foregroundStyle(model.needsAttention ? Color.orange : Color.secondary)
                    }
                }
                if model.needsAttention {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
        } icon: {
            Image(systemName: "lock.shield")
        }
    }
}
