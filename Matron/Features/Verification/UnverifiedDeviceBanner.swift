import SwiftUI

/// Top-of-`ChatListView` banner shown when this device's signing keys
/// haven't been cross-signed yet (Wave 6 / live-test #3). Pre-Phase-3
/// users skipped the onboarding `PostLoginVerificationView` gate (their
/// `verifyDone` flag was never set, but their session predates the gate),
/// so they have no in-app prompt to verify.
///
/// Tap "Verify" → host invokes the `onVerify` closure. The host owns the
/// SAS-sheet presentation; the banner is a pure trigger. No dismiss
/// button: the banner naturally goes away once verification completes
/// and the post-tick `verificationService.isThisDeviceVerified()` re-poll
/// resolves to `true`.
///
/// Mirrors `VerificationBanner`'s shape (incoming-request banner) so the
/// two banners stack consistently when both are visible.
struct UnverifiedDeviceBanner: View {
    let onVerify: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This device hasn't been verified")
                    .font(.callout)
                    .bold()
                Text("Verify now to keep your messages decryptable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Verify") { onVerify() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This device hasn't been verified. Verify.")
    }
}
