#if os(macOS)
import SwiftUI
import AppKit
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// The parts of setting up two-factor that sign-in and Settings → Security
/// share on the Mac: the new authenticator secret, and the recovery codes
/// shown once. Mirrors iOS `TwoFactorSetupSections`.
enum MacTwoFactorSetupViews {
    /// Copies a setup key or recovery codes. The concealed marker asks
    /// clipboard managers not to keep it (nspasteboard.org), and the copy
    /// is cleared after two minutes unless something else was copied since.
    static func copySecret(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        }
    }
}

/// The QR code beside "Open in authenticator" and the key to type in by hand.
struct MacTwoFactorSetupKeyView: View {
    let setup: TwoFactorSetup
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            QRCodeView(string: setup.otpauthURI)
                .frame(width: 140, height: 140)
                .accessibilityLabel("QR code for your authenticator app")
            VStack(alignment: .leading, spacing: 8) {
                if let url = URL(string: setup.otpauthURI) {
                    Link(destination: url) {
                        Label("Open in authenticator", systemImage: "arrow.up.forward.app")
                    }
                    .accessibilityIdentifier("signin.2fa.openAuthenticator")
                }
                Button {
                    MacTwoFactorSetupViews.copySecret(setup.secret)
                    copied = true
                } label: {
                    Label(copied ? "Setup key copied" : "Copy setup key",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("signin.2fa.copyKey")
                Text(TwoFactorSecretFormat.grouped(setup.secret))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("twoFactor.setupKey")
                Text(setup.account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The recovery codes in two columns, with Copy and Share.
struct MacTwoFactorRecoveryCodesView: View {
    let codes: [String]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(codes, id: \.self) { code in
                    Text(code).font(.system(.body, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button {
                    MacTwoFactorSetupViews.copySecret(SignInViewModel.recoveryCodesText(codes))
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
}
#endif
