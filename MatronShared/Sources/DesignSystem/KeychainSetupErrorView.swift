import SwiftUI

/// Hard-gate UI surfaced when the setup-time `KeychainProbe.run(...)` fails
/// during app bootstrap (Phase 3 / Task 13 on Mac, Phase 3 / Wave 3 / M1
/// extends to iOS). The recovery-key flow can't function without working
/// Keychain access, so the host app deliberately replaces the normal
/// onboarding chrome with this view rather than rendering a dismissable
/// banner — the user must see the error before they can sign in.
///
/// Cross-platform so both `MatronApp` (iOS) and `MatronMacApp` can mount it
/// from their respective bootstrap paths. Mac fixes the size to 480×360 to
/// match the visual weight of `MacPostLoginVerificationView`; iOS lets the
/// view expand to fill the window so the error is unmissable on a phone.
public struct KeychainSetupErrorView: View {
    private let message: String
    /// Path to the platform-specific setup doc that explains how to fix
    /// the entitlement. Surfaced to the user as plain text since opening a
    /// link from inside the app is not a reachable action when the user
    /// hasn't even signed in yet.
    private let docPath: String

    /// - Parameters:
    ///   - message: Underlying probe error string (e.g.
    ///     "Keychain probe set failed: errSecMissingEntitlement (-34018)").
    ///     Surfaced verbatim in monospace so a developer / support engineer
    ///     can interpret the OSStatus.
    ///   - docPath: Repo-relative path to the setup doc, e.g.
    ///     `docs/setup-mac.md`. Defaults to platform-appropriate value.
    public init(message: String, docPath: String? = nil) {
        self.message = message
        if let docPath {
            self.docPath = docPath
        } else {
            #if os(macOS)
            self.docPath = "docs/setup-mac.md"
            #else
            self.docPath = "docs/setup-ios.md"
            #endif
        }
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            Text("Keychain access not configured")
                .font(.title2)
                .bold()
            Text("Matron cannot persist your recovery key without Keychain access. See `\(docPath)` to fix the entitlement, then relaunch.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(32)
        #if os(macOS)
        // Match the visual weight of `MacPostLoginVerificationView` so the
        // error reads as part of the onboarding flow rather than a runtime
        // crash dialog.
        .frame(width: 480, height: 360)
        #else
        // On iOS the view fills the WindowGroup so the user can't miss it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
