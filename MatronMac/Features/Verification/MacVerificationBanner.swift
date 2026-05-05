#if os(macOS)
import SwiftUI
import MatronVerification

/// Mac analogue of `VerificationBanner` (Task 9). Renders as a top-of-window
/// banner above the chat-list sidebar (within the leading column of
/// `NavigationSplitView`) when `VerificationCenter.pending` is non-empty.
/// Click "Verify" → host presents `MacSasView` as a fixed-size sheet
/// (Task 7c). X dismiss → host calls `VerificationCenter.dismiss(_:)`
/// (cancel-then-remove). Same shared `VerificationCenter` from Task 8 —
/// the orchestrator is cross-platform.
///
/// Native Mac chrome: muted `windowBackgroundColor.opacity(0.9)` fill +
/// 0.5pt secondary stroke for the standard "translucent panel above
/// content" look. Compact spacing because the sidebar is narrow.
///
/// `#if os(macOS)`-guarded so an iOS-leaked source path can't trip on
/// `NSColor`. Mirrors the guard pattern used by `MacRecoveryKeyView` /
/// `MacSasView`.
struct MacVerificationBanner: View {
    let summary: VerificationRequestSummary
    let onAccept: (VerificationRequestSummary) -> Void
    let onDismiss: (VerificationRequestSummary) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.otherUserID) wants to verify")
                    .font(.callout)
                    .bold()
                if let device = summary.otherDeviceID {
                    Text(device)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Verify") { onAccept(summary) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("verifybanner.accept")
            Button {
                onDismiss(summary)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
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
    }
}
#endif
