import SwiftUI
import MatronVerification
import MatronViewModels

/// iOS surface for the SAS (Short Authentication String) emoji-compare
/// verification flow (spec §7.1). Shared `SasViewModel` from `MatronViewModels`
/// drives state; this view only renders the per-state chrome.
///
/// State machine rendering:
///   * `.idle` / `.requested`     — spinner + "Starting verification…"
///   * `.readyForEmoji([…])`      — 7-emoji grid + match / don't-match buttons
///   * `.awaitingConfirmation`    — spinner + "Waiting for the other device…"
///   * `.verified`                — green shield + "Verified"
///   * `.cancelled(reason)`       — red shield + reason text
///
/// Important: emoji order MUST come from the stream as the SDK delivered it.
/// Re-sorting (e.g. by symbol) would silently produce a different
/// short-auth-string and break the verify on the other device. The
/// `ForEach(Array(emojis.enumerated()), id: \.offset)` pattern preserves
/// stream order and gives `ForEach` stable identity (offset, not the emoji
/// value — duplicate symbols across slots are valid SAS output).
struct SasView: View {
    @State var viewModel: SasViewModel
    let title: String
    /// Fired once when the flow reaches `.verified`. Mirrors
    /// `RecoveryKeyView.onFinished` so the onboarding `PostLoginVerificationView`
    /// gate can flip its `verifyDone` state and let the user reach the chat
    /// list. Bugbot caught: previously `.verified` showed the green checkmark
    /// and then the user was permanently stuck because the parent never
    /// learned the flow had completed.
    var onFinished: () -> Void = {}
    /// Fired when the user taps Close on the `.cancelled` terminal
    /// state. Separate from `onFinished` because the parent's success-
    /// side reaction (e.g. `markVerifyDone(for:)` on the onboarding
    /// gate, `markCompleted(_:)` on the chat-list banner) is outcome-
    /// dependent: we don't want to flip a "device verified" flag just
    /// because a SAS got cancelled. Default is a no-op so callers that
    /// don't surface a Close button stay unbroken.
    var onCancelled: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle, .requested:
                ProgressView("Starting verification…")
            case .readyForEmoji(let emojis):
                emojiCard(emojis)
                buttons
            case .awaitingConfirmation:
                ProgressView("Waiting for the other device…")
            case .verified:
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("Verified")
                    .font(.title2)
                    .bold()
            case .cancelled(let reason):
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // Without an explicit Close, a cancelled SAS leaves the
                // user staring at a sheet they have to swipe-down to
                // dismiss AND leaves a stale banner under it. The
                // button surfaces both: callers wire `onCancelled` to
                // either pop the navigation (verify-gate path) or
                // drain the banner + close the sheet (chat-list
                // incoming-request path).
                Button("Close") { onCancelled() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sas.cancelClose")
            }
        }
        .padding()
        .navigationTitle(title)
        // `.task(id:)` so re-presentation with the same request ID doesn't
        // re-fire; pairs with the `isObserving` guard inside the view-model.
        .task(id: viewModel.requestID) { await viewModel.observe() }
        .onChange(of: viewModel.state) { _, new in
            if case .verified = new { onFinished() }
        }
    }

    @ViewBuilder
    private func emojiCard(_ emojis: [SasEmoji]) -> some View {
        VStack(spacing: 12) {
            Text("Compare these emojis with the other device.")
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    VStack(spacing: 4) {
                        Text(e.symbol)
                            .font(.system(size: 44))
                        Text(e.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("They don't match", role: .destructive) {
                Task { await viewModel.cancel() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sas.dontMatch")
            Spacer()
            Button("They match") {
                Task { await viewModel.confirm() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sas.match")
        }
    }
}
