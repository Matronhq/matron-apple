#if os(macOS)
import SwiftUI
import MatronVerification
import MatronViewModels

/// Mac analogue of `SasView` (spec §7.1) — same shared `SasViewModel`
/// state machine, native Mac sheet chrome. Differences from iOS:
///
/// - Fixed-size sheet (480×400) — Mac sheets are always centred and
///   modal-to-window; we don't get half-sheet detents like iOS.
/// - 4+3 grid via `LazyVGrid` instead of an `HStack` row, to keep the
///   7-emoji set visually balanced inside the narrow sheet width.
/// - Keyboard shortcuts on the action buttons:
///     * "They match"        → `.return`
///     * "They don't match"  → `.escape`
///   Returns the sheet to a dialog feel without forcing a mouse trip.
///
/// Background uses `Color(NSColor.controlBackgroundColor)` (mirrors the
/// internal `MatronCodeBg` alias used by the design-system on macOS) —
/// stays muted in both light and dark appearance and matches the chrome
/// of `MacRecoveryKeyView`.
///
/// Emoji ordering: same invariant as iOS — the SDK's stream-delivery
/// order IS the SAS order. `ForEach(Array(emojis.enumerated()), id: \.offset)`
/// preserves that order without coupling `ForEach` identity to the
/// emoji value (duplicates across slots are valid SAS output).
struct MacSasView: View {
    @State var viewModel: SasViewModel
    let title: String
    /// Fired once when the flow reaches `.verified`. Mirrors
    /// `MacRecoveryKeyView.onFinished` so the onboarding gate's `verifyDone`
    /// flag flips. Bugbot caught: the user previously saw the green
    /// checkmark and was permanently stuck because the parent never learned
    /// the flow had completed.
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle, .requested:
                ProgressView("Starting verification…")
            case .readyForEmoji(let emojis):
                emojiGrid(emojis)
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
        .padding(24)
        .frame(width: 480, height: 400)        // fixed-size Mac sheet
        .navigationTitle(title)
        // Pairs with `SasViewModel.isObserving` — re-presenting the sheet
        // with the same requestID is a no-op, not a re-iteration.
        .task(id: viewModel.requestID) { await viewModel.observe() }
        .onChange(of: viewModel.state) { _, new in
            if case .verified = new { onFinished() }
        }
    }

    @ViewBuilder
    private func emojiGrid(_ emojis: [SasEmoji]) -> some View {
        VStack(spacing: 12) {
            Text("Compare these emojis with the other device.")
                .font(.callout)
                .multilineTextAlignment(.center)
            // 7-emoji grid: top row of 4, bottom row of 3 — keeps the
            // sheet visually balanced at 480pt wide.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    VStack(spacing: 4) {
                        Text(e.symbol)
                            .font(.system(size: 40))
                        Text(e.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("They don't match", role: .destructive) {
                Task { await viewModel.cancel() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("sas.dontMatch")
            Spacer()
            Button("They match") {
                Task { await viewModel.confirm() }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sas.match")
        }
    }
}
#endif
