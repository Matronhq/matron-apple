import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// The parts of setting up two-factor that sign-in and Settings → Security
/// share, as `Form` sections: the new authenticator secret, and the
/// recovery codes shown once.
enum TwoFactorSetupSections {
    /// Copies a setup key or recovery codes to this device only (never
    /// Universal Clipboard), cleared after two minutes.
    static func copySecret(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }
}

/// The QR code, "Open in authenticator", and the key to type in by hand.
struct TwoFactorSetupKeySection: View {
    let setup: TwoFactorSetup
    var footer: String?
    @State private var copied = false

    var body: some View {
        Section {
            QRCodeView(string: setup.otpauthURI)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR code for your authenticator app")
            if let url = URL(string: setup.otpauthURI) {
                Link(destination: url) {
                    Label("Open in authenticator", systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("signin.2fa.openAuthenticator")
            }
            Button {
                TwoFactorSetupSections.copySecret(setup.secret)
                copied = true
            } label: {
                Label(copied ? "Setup key copied" : "Copy setup key",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("signin.2fa.copyKey")
            Text(TwoFactorSecretFormat.grouped(setup.secret))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("twoFactor.setupKey")
        } footer: {
            Text(footer ?? "Scan the code with another device, or open it in an authenticator on this one. \(setup.account)")
        }
    }
}

/// The recovery codes, with Copy and Share.
struct TwoFactorRecoveryCodesSection: View {
    let codes: [String]
    @State private var copied = false

    var body: some View {
        Section {
            ForEach(codes, id: \.self) { code in
                Text(code).font(.system(.body, design: .monospaced))
            }
            .accessibilityIdentifier("twoFactor.recoveryCode")
            Button {
                TwoFactorSetupSections.copySecret(SignInViewModel.recoveryCodesText(codes))
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("signin.2fa.copyCodes")
            ShareLink(item: SignInViewModel.recoveryCodesText(codes)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
