import SwiftUI
import AppKit
import MatronViewModels

/// Mac analogue of `RecoveryKeyView` (iOS Task 5). Same shared
/// `RecoveryKeyViewModel` from `MatronShared/Sources/ViewModels/`,
/// view-only differences:
///   - Fixed-size sheet (480×400), not a half-sheet — Mac sheets host
///     inside their parent window rather than partially covering it.
///   - `.textSelection(.enabled)` on the displayed key so the user can
///     drag-select + ⌘C in addition to the explicit Copy button.
///   - `NSPasteboard`-based paste detection (`PasteDetector`) populates
///     `reenteredKey` from the clipboard so users pasting from a password
///     manager don't have to type. Like iOS, advancing to `.confirmed`
///     still requires an explicit Confirm tap — no auto-advance.
///   - Success state (`.generate / .confirmed`) renders a checkmark
///     briefly while the parent host responds to `onFinished()` and tears
///     the sheet down. Same dismissal trigger as iOS — the Confirm tap
///     fires `onFinished()` directly.
///
/// > iCloud Keychain auto-restore: spec §7.1 notes that a Mac install can
/// > read the recovery key written by the iOS install (Task 3 wired
/// > `kSecAttrSynchronizable=true` into `KeychainStore`). Wiring the
/// > prefill into `.restore` mode lives in the integration layer that
/// > constructs this view — out of scope for the view itself.
struct MacRecoveryKeyView: View {
    @State var viewModel: RecoveryKeyViewModel
    let onFinished: () -> Void
    @State private var detector: PasteDetector?

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.mode {
            case .generate: generateBody
            case .restore:  restoreBody
            }
            Spacer()
            primaryActionButton
        }
        .padding(24)
        .frame(width: 480, height: 400)
        .navigationTitle("Recovery key")
        .onAppear {
            detector = PasteDetector(pasteboard: LiveNSPasteboard(), viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var generateBody: some View {
        switch viewModel.generatePhase {
        case .notStarted, .show:
            Text("This is your recovery key. Save it somewhere safe — it's the only way to recover your encrypted history.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let key = viewModel.generatedKey {
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                    .accessibilityIdentifier("recoverykey.copy")
                }
                Toggle("I've saved this key somewhere safe", isOn: $viewModel.userAcknowledgedSaved)
                    .accessibilityIdentifier("recoverykey.acknowledgeSaved")
            } else {
                Button("Generate recovery key") {
                    Task { await viewModel.generate() }
                }
                .disabled(viewModel.phase == .busy)
                .accessibilityIdentifier("recoverykey.generate")
            }
        case .reenter:
            Text("Re-enter your recovery key, or paste it from the clipboard.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                TextField("Re-enter recovery key", text: $viewModel.reenteredKey)
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Paste") { detector?.checkClipboardAndApply() }
                    .accessibilityIdentifier("recoverykey.paste")
            }
            // No auto-advance on `reenteredKey` change — match iOS, which
            // requires an explicit Confirm tap. Auto-advancing on paste /
            // fast-typing would skip the deliberate confirmation gesture.
            if !viewModel.reenteredKey.isEmpty && !viewModel.canFinish {
                Text("Doesn't match the key above.")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        case .confirmed:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("Recovery key confirmed")
                    .font(.title2).bold()
            }
            // No `.task` auto-dismiss here. The Confirm button (in
            // `primaryActionButton` below) sets `generatePhase = .confirmed`
            // AND calls `onFinished()` in the same tap — single source of
            // truth. The success view is briefly visible between the
            // assignment and the parent host's response to `onFinished()`.
            // Previously a 600ms `.task` dismissal raced with the button's
            // own `onFinished()` and double-fired the parent callback.
        }
        if case .error(let message) = viewModel.phase {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var restoreBody: some View {
        Text("Enter your recovery key to unlock encrypted history on this Mac.")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
            TextField("Enter recovery key", text: $viewModel.enteredKey)
                .font(.system(.title3, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Button("Paste") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    viewModel.enteredKey = s
                }
            }
            .accessibilityIdentifier("recoverykey.restorePaste")
        }
        // The standalone "Restore" button used to live here for retry-
        // after-error UX, paired with a "Done" button at the bottom that
        // ALSO ran restore + dismissed. Two buttons doing approximately
        // the same thing was confusing — pressing Restore showed no
        // visible feedback, so users pressed Done after, which (because
        // phase wasn't `.done` yet) ran restore a second time. The
        // primary action button below is now the single
        // "Restore"-and-dismiss action with a `.busy` ProgressView while
        // the SDK round-trips. Errors render here.
        if case .error(let message) = viewModel.phase {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// Bottom-bar primary action — varies by mode + phase. The
    /// `.confirmed` branch returns `EmptyView`; the Confirm button on
    /// `.reenter` already fired `onFinished()`, so the success view only
    /// renders momentarily before the parent host tears the sheet down.
    @ViewBuilder
    private var primaryActionButton: some View {
        switch (viewModel.mode, viewModel.generatePhase) {
        case (.generate, .show):
            Button("Continue") { viewModel.advanceFromShow() }
                .keyboardShortcut(.return)
                .disabled(!viewModel.userAcknowledgedSaved)
                .accessibilityIdentifier("recoverykey.continue")
        case (.generate, .reenter):
            // Single source of truth for "user explicitly confirmed": the
            // Confirm button flips to `.confirmed` AND fires `onFinished()`
            // in the same tap. No auto-advance on `reenteredKey` change,
            // and no `.task` auto-dismiss in `.confirmed` — both used to
            // exist and double-fired this callback (PR review issues #1
            // and #14). Matches iOS `RecoveryKeyView`.
            Button("Confirm") {
                viewModel.generatePhase = .confirmed
                onFinished()
            }
            .keyboardShortcut(.return)
            .disabled(!viewModel.canFinish)
            .accessibilityIdentifier("recoverykey.confirm")
        case (.generate, .confirmed):
            EmptyView()        // Confirm button already fired onFinished()
        case (.restore, _):
            // Single Restore-and-dismiss action — runs the SDK
            // restore, swaps to a ProgressView while busy, fires
            // `onFinished` once the VM lands at `.done`. Wave 4
            // expert-QA #2's skip-when-already-done guard stays so a
            // double-tap doesn't re-fire `recover()` after success.
            Button {
                Task {
                    if viewModel.phase != .done {
                        await viewModel.attemptRestore()
                    }
                    if viewModel.phase == .done { onFinished() }
                }
            } label: {
                if viewModel.phase == .busy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restoring…")
                    }
                } else {
                    Text("Restore")
                }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.enteredKey.isEmpty || viewModel.phase == .busy)
            .accessibilityIdentifier("recoverykey.restore")
        default:
            EmptyView()
        }
    }
}
