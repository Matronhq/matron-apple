#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Mac twin of `TwoFactorSettingsSection`: Settings → Security, the Email
/// address row, the Password row (change password), then whether
/// two-factor sign-in is on, with Set Up…, New Recovery Codes…, Change
/// App… and Turn Off…. Every sheet these rows open is presented by
/// `macSecuritySettingsSheet(_:)` on the settings form, not from here
/// (see `SecuritySettingsModel`).
struct MacTwoFactorSettingsSection: View {
    let security: SecuritySettingsModel
    private var model: TwoFactorSettingsModel { security.twoFactor }

    var body: some View {
        if security.isShown {
            Section {
                if let email = security.email {
                    MacAccountEmailRow(model: email) { security.open(.email) }
                }
                if let password = security.password {
                    MacChangePasswordRow(model: password) { security.open(.password) }
                }
                if model.isShown {
                    twoFactorRows
                }
            } header: {
                Text("Security")
            } footer: {
                if model.isShown, let footer = model.footerText {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var twoFactorRows: some View {
        LabeledContent {
            switch model.phase {
            case .loading: ProgressView().controlSize(.small)
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
        if !model.actions.isEmpty {
            HStack {
                ForEach(model.actions) { action in
                    Button(TwoFactorSettingsModel.title(for: action)) { security.open(.twoFactor(action)) }
                        .accessibilityIdentifier("settings.twoFactor.\(action.rawValue)")
                }
            }
        }
    }
}

extension View {
    /// Mac twin of `securitySettingsSheet(_:)`: the Security section's
    /// sheets, on the settings form itself, and the first read of the
    /// email address and two-factor status.
    func macSecuritySettingsSheet(_ security: SecuritySettingsModel) -> some View {
        modifier(MacSecuritySettingsSheetModifier(security: security))
    }
}

private struct MacSecuritySettingsSheetModifier: ViewModifier {
    @Bindable var security: SecuritySettingsModel

    func body(content: Content) -> some View {
        content
            .task { await security.refresh() }
            .sheet(item: $security.sheet, onDismiss: { Task { await security.sheetClosed() } }) { sheet in
                switch sheet {
                case .email:
                    if let email = security.email {
                        MacAccountEmailSheet(model: email) { security.close() }
                    }
                case .password:
                    if let password = security.password {
                        MacChangePasswordSheet(model: password) { security.close() }
                    }
                case .twoFactor(let action):
                    MacTwoFactorSecuritySheet(flow: TwoFactorSecurityFlowModel(action: action, api: security.twoFactor.api))
                }
            }
    }
}

/// One Settings → Security sheet on the Mac: `TwoFactorSecurityFlowModel`
/// as a small form.
struct MacTwoFactorSecuritySheet: View {
    @State var flow: TwoFactorSecurityFlowModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field { case password, currentCode, newCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.title).font(.title3.weight(.semibold))
            switch flow.step {
            case .confirm: confirm
            case .scan(let setup): scan(setup)
            case .recoveryCodes(let codes): recoveryCodes(codes)
            case .finished: EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .interactiveDismissDisabled(flow.blocksDismissal || flow.isBusy)
        .onChange(of: flow.step) { _, step in
            if step == .finished { dismiss() }
        }
    }

    // MARK: Steps

    @ViewBuilder private var confirm: some View {
        Text(flow.intro)
            .fixedSize(horizontal: false, vertical: true)
        field("Password") {
            SecureField("", text: $flow.password)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .onSubmit { submit() }
                .accessibilityIdentifier("twoFactor.password")
        }
        if let label = flow.currentCodeLabel {
            field(label) {
                TextField("", text: $flow.currentCode)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .currentCode)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("twoFactor.currentCode")
            }
        }
        errorAndButtons
            .onAppear { focused = .password }
    }

    @ViewBuilder private func scan(_ setup: TwoFactorSetup) -> some View {
        Text("Scan this with your authenticator app, or type in the key. It shows up as \(setup.issuer) (\(setup.account)).")
            .fixedSize(horizontal: false, vertical: true)
        MacTwoFactorSetupKeyView(setup: setup)
        field(TwoFactorSecurityFlowModel.newCodeLabel) {
            TextField("123456", text: $flow.newCode)
                .font(.system(.title3, design: .monospaced))
                .textContentType(.oneTimeCode)
                .focused($focused, equals: .newCode)
                .onSubmit { submit() }
                .onChange(of: flow.newCode) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { flow.newCode = digits }
                }
                .accessibilityIdentifier("twoFactor.newCode")
        }
        if flow.action == .setUp {
            Toggle(TwoFactorSecurityFlowModel.signOutOthersLabel, isOn: $flow.signOutOthers)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("twoFactor.signOutOthers")
        }
        errorAndButtons
            .onAppear { focused = .newCode }
    }

    @ViewBuilder private func recoveryCodes(_ codes: [String]) -> some View {
        if let success = flow.successText {
            Label(success, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("twoFactor.success")
        }
        Text(TwoFactorSecurityFlowModel.recoveryCodesNote)
            .fixedSize(horizontal: false, vertical: true)
        MacTwoFactorRecoveryCodesView(codes: codes)
        Toggle(TwoFactorSecurityFlowModel.savedCodesLabel, isOn: $flow.savedCodes)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("twoFactor.saved")
        HStack {
            Spacer()
            Button("Done") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canSubmit)
                .accessibilityIdentifier("twoFactor.done")
        }
    }

    // MARK: Pieces

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var errorAndButtons: some View {
        if let error = flow.error {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("twoFactor.error")
        }
        HStack {
            Spacer()
            // Leaving mid-request could let the server issue recovery
            // codes this sheet never shows.
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(flow.isBusy)
                .accessibilityIdentifier("twoFactor.cancel")
            Button(role: flow.isDestructive ? .destructive : nil) {
                submit()
            } label: {
                if flow.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(flow.submitTitle)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.canSubmit)
            .accessibilityIdentifier("twoFactor.submit")
        }
    }

    private func submit() {
        Task { await flow.submit() }
    }
}
#endif
