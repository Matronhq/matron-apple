import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Security: the Email address row (where a password-reset
/// link goes), the Password row (change password), then whether
/// two-factor sign-in is on for this account, with Set Up…, New Recovery
/// Codes…, Change App… and Turn Off…, each in its own sheet. The
/// two-factor rows hide on a journal without two-factor; the Password row
/// keeps the section up.
struct TwoFactorSettingsSection: View {
    @State private var model: TwoFactorSettingsModel
    @State private var sheet: TwoFactorSettingsModel.Action?
    /// `POST /password`; nil leaves the Password row out.
    let passwordAPI: (any PasswordChanging)?
    /// `GET`/`PUT /account/email`; nil leaves the Email address row out.
    let emailAPI: (any AccountEmailProviding)?

    init(api: any TwoFactorSettingsProviding, passwordAPI: (any PasswordChanging)? = nil,
         emailAPI: (any AccountEmailProviding)? = nil) {
        _model = State(initialValue: TwoFactorSettingsModel(api: api))
        self.passwordAPI = passwordAPI
        self.emailAPI = emailAPI
    }

    var body: some View {
        Group {
            if model.isShown || passwordAPI != nil || emailAPI != nil {
                Section {
                    if let emailAPI {
                        AccountEmailRow(api: emailAPI)
                    }
                    if let passwordAPI {
                        ChangePasswordRow(api: passwordAPI)
                    }
                    if model.isShown {
                        twoFactorRows
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if model.isShown, let footer = model.footerText { Text(footer) }
                }
            }
        }
        .task { await model.refresh() }
        .sheet(item: $sheet, onDismiss: { Task { await model.refresh() } }) { action in
            TwoFactorSecuritySheet(flow: TwoFactorSecurityFlowModel(action: action, api: model.api))
        }
    }

    @ViewBuilder private var twoFactorRows: some View {
        LabeledContent {
            switch model.phase {
            case .loading: ProgressView()
            case .failed: Text("Unknown").foregroundStyle(.secondary)
            default: Text(model.statusText ?? "")
            }
        } label: {
            Text(TwoFactorSettingsModel.title)
            if let detail = model.detailText {
                Text(detail)
            }
        }
        .accessibilityIdentifier("settings.twoFactor.status")
        if model.showsLowRecoveryCodesWarning {
            Label(TwoFactorSettingsModel.lowRecoveryCodesWarning, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.twoFactor.lowCodes")
        }
        ForEach(model.actions) { action in
            Button(TwoFactorSettingsModel.title(for: action), role: action == .turnOff ? .destructive : nil) {
                sheet = action
            }
            .accessibilityIdentifier("settings.twoFactor.\(action.rawValue)")
        }
    }
}

/// One Settings → Security sheet: `TwoFactorSecurityFlowModel` as a form.
struct TwoFactorSecuritySheet: View {
    @State var flow: TwoFactorSecurityFlowModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field { case password, currentCode, newCode }

    var body: some View {
        NavigationStack {
            Form {
                switch flow.step {
                case .confirm: confirm
                case .scan(let setup): scan(setup)
                case .recoveryCodes(let codes): recoveryCodes(codes)
                case .finished: EmptyView()
                }
            }
            .navigationTitle(flow.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .recoveryCodes = flow.step {} else {
                    ToolbarItem(placement: .cancellationAction) {
                        // Leaving mid-request could let the server issue
                        // recovery codes this sheet never shows.
                        Button("Cancel") { dismiss() }
                            .disabled(flow.isBusy)
                            .accessibilityIdentifier("twoFactor.cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.blocksDismissal || flow.isBusy)
        .onChange(of: flow.step) { _, step in
            if step == .finished { dismiss() }
        }
    }

    // MARK: Steps

    @ViewBuilder private var confirm: some View {
        Section {
            Text(flow.intro)
        }
        Section {
            SecureField("Password", text: $flow.password)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .submitLabel(.continue)
                .onSubmit { submit() }
                .accessibilityIdentifier("twoFactor.password")
            if let label = flow.currentCodeLabel {
                TextField(label, text: $flow.currentCode)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .currentCode)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("twoFactor.currentCode")
            }
        }
        .onAppear { focused = .password }
        errorAndSubmit
    }

    @ViewBuilder private func scan(_ setup: TwoFactorSetup) -> some View {
        TwoFactorSetupKeySection(
            setup: setup,
            footer: "Scan this with your authenticator app, or type in the key. It shows up as \(setup.issuer) (\(setup.account)).")
        Section {
            TextField("123456", text: $flow.newCode)
                .font(.system(.title2, design: .monospaced))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused, equals: .newCode)
                .onChange(of: flow.newCode) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { flow.newCode = digits }
                }
                .accessibilityIdentifier("twoFactor.newCode")
            if flow.action == .setUp {
                Toggle(TwoFactorSecurityFlowModel.signOutOthersLabel, isOn: $flow.signOutOthers)
                    .accessibilityIdentifier("twoFactor.signOutOthers")
            }
        } header: {
            Text(TwoFactorSecurityFlowModel.newCodeLabel)
        }
        errorAndSubmit
    }

    @ViewBuilder private func recoveryCodes(_ codes: [String]) -> some View {
        Section {
            if let success = flow.successText {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("twoFactor.success")
            }
            Text(TwoFactorSecurityFlowModel.recoveryCodesNote)
        } header: {
            Text("Recovery codes")
        }
        TwoFactorRecoveryCodesSection(codes: codes)
        Section {
            Toggle(TwoFactorSecurityFlowModel.savedCodesLabel, isOn: $flow.savedCodes)
                .accessibilityIdentifier("twoFactor.saved")
            Button("Done") { submit() }
                .disabled(!flow.canSubmit)
                .accessibilityIdentifier("twoFactor.done")
        }
    }

    @ViewBuilder private var errorAndSubmit: some View {
        Section {
            if let error = flow.error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("twoFactor.error")
            }
            Button(role: flow.isDestructive ? .destructive : nil) {
                submit()
            } label: {
                if flow.isBusy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(flow.submitTitle).frame(maxWidth: .infinity)
                }
            }
            .disabled(!flow.canSubmit)
            .accessibilityIdentifier("twoFactor.submit")
        }
    }

    private func submit() {
        Task { await flow.submit() }
    }
}
