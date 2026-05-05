#if os(macOS)
import SwiftUI

/// Top-of-sidebar banner shown when this device's signing keys haven't been
/// cross-signed yet (Wave 6 / live-test #3). Pre-Phase-3 users skipped the
/// onboarding `MacPostLoginVerificationView` gate (their `verifyDone` flag
/// was never set, but their session predates the gate), so they have no
/// in-app prompt to verify — the only surface was Help → Verify This
/// Device, which is a wrong-shape ask. This banner sits above the chat
/// list / verification-request banners and lets the user trigger the same
/// SAS flow without leaving the chat list.
///
/// Tap "Verify" → host invokes the same `onVerifyDevice` closure that
/// Help → Verify This Device fires (single source of truth — both surface
/// route through `MatronMacApp.showVerifyDeviceSheet`). No dismiss button:
/// the banner naturally goes away once verification completes (the
/// post-tick `verificationService.isThisDeviceVerified()` re-poll resolves
/// to `true`).
///
/// `#if os(macOS)`-guarded so an iOS-leaked source path can't trip on
/// `NSColor`. Mirrors the guard pattern used by `MacVerificationBanner` /
/// `MacRecoveryKeyView` / `MacSasView`.
struct MacUnverifiedDeviceBanner: View {
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 10) {
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
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This device hasn't been verified. Verify.")
    }
}
#endif
