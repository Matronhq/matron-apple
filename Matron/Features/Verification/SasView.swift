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
            }
        }
        .padding()
        .navigationTitle(title)
        // `.task(id:)` so re-presentation with the same request ID doesn't
        // re-fire; pairs with the `isObserving` guard inside the view-model.
        .task(id: viewModel.requestID) { await viewModel.observe() }
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
            Spacer()
            Button("They match") {
                Task { await viewModel.confirm() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
