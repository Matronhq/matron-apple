import SwiftUI
import MatronVerification

/// Top-of-`ChatListView` banner that surfaces a single pending
/// `VerificationRequestSummary` (spec §7.1, §5.9). One banner is rendered
/// per `VerificationCenter.pending` entry; tapping "Verify" hands the
/// summary up to the host so it can present `SasView` as a sheet, and
/// tapping the dismiss "X" hands it up so the host can call
/// `VerificationCenter.dismiss(_:)` (cancel-then-remove ordering — see
/// `VerificationCenter` for the rationale).
///
/// Callbacks (not direct service references) keep this view trivially
/// previewable / testable without standing up a fake service. The host
/// (Matron's `ChatListView`) owns the `VerificationCenter` and routes the
/// callbacks into it.
struct VerificationBanner: View {
    let summary: VerificationRequestSummary
    let onAccept: (VerificationRequestSummary) -> Void
    let onDismiss: (VerificationRequestSummary) -> Void

    var body: some View {
        HStack {
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss(summary)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
