import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// iOS recovery-key surface (spec §7.2 Scenario A). Wraps `RecoveryKeyViewModel`
/// and renders one of two flows:
///
/// - `.generate` mode is the **first-device** path. Three sub-phases:
///     * `.show`    — display the freshly-generated key once, with a copy button
///       and a mandatory "I've saved this" toggle.
///     * `.reenter` — the user types the key back to confirm save; the
///       primary action only enables once `vm.canFinish` is true.
///     * `.confirmed` — terminal; iOS dismisses straight from `.reenter`
///       so this branch renders an empty view (the Mac variant uses it
///       for a success animation before auto-dismissing).
///
/// - `.restore` mode is the **additional-device** path. Single phase:
///   user enters a known recovery key, taps "Restore," done.
///
/// The view itself owns no SDK state — `RecoveryKeyManager` plumbing is
/// passed in via the view-model's closures at construction time.
struct RecoveryKeyView: View {
    @State var viewModel: RecoveryKeyViewModel
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch viewModel.mode {
                case .generate: generateBody
                case .restore:  restoreBody
                }
                Spacer()
                primaryActionButton
            }
            .padding()
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Continue / Confirm / Restore — label + action vary by mode + phase.
    /// In `.generate / .show`, advances to re-entry once the user has
    /// acknowledged. In `.generate / .reenter`, finishes once the
    /// re-entered key matches. In `.restore`, the action runs the restore
    /// + dismisses.
    @ViewBuilder
    private var primaryActionButton: some View {
        switch (viewModel.mode, viewModel.generatePhase) {
        case (.generate, .show):
            Button("Continue") { viewModel.advanceFromShow() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.userAcknowledgedSaved)
        case (.generate, .reenter):
            Button("Confirm") {
                viewModel.generatePhase = .confirmed
                onFinished()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canFinish)
        case (.restore, _):
            // Single Restore-and-dismiss action — runs the SDK
            // restore, swaps to a ProgressView while busy, fires
            // `onFinished` once the VM lands at `.done`. The prior
            // shape had a separate inline "Restore" button + this
            // bottom "Done" button, which was confusing: pressing
            // Restore showed no visible feedback, so users pressed
            // Done after, which (because phase wasn't `.done` yet)
            // ran restore a second time. Now there's just one
            // button. Wave 4 expert-QA #2's skip-when-already-done
            // guard stays so a double-tap doesn't re-fire
            // `recover()` after success.
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
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.enteredKey.isEmpty || viewModel.phase == .busy)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var generateBody: some View {
        switch viewModel.generatePhase {
        case .notStarted, .show:
            Text("This is your recovery key. Save it somewhere safe — it's the only way to recover your encrypted history.")
                .font(.callout)
                .multilineTextAlignment(.leading)
            if let key = viewModel.generatedKey {
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        Pasteboard.copy(key)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy recovery key")
                }
                Toggle("I've saved this key somewhere safe", isOn: $viewModel.userAcknowledgedSaved)
            } else {
                Button("Generate recovery key") {
                    Task { await viewModel.generate() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.phase == .busy)
            }
        case .reenter:
            Text("Re-enter your recovery key to confirm you've saved it correctly.")
                .font(.callout)
            TextField("Re-enter recovery key", text: $viewModel.reenteredKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !viewModel.reenteredKey.isEmpty && !viewModel.canFinish {
                Text("Doesn't match the key above.")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        case .confirmed:
            EmptyView()
        }
        if case .error(let message) = viewModel.phase {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var restoreBody: some View {
        Text("Enter your recovery key to unlock encrypted history on this device.")
            .font(.callout)
        TextField("Enter recovery key", text: $viewModel.enteredKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.title3, design: .monospaced))
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        // The standalone inline Restore button used to live here for
        // retry-after-error, paired with the bottom Done button (which
        // ALSO ran restore). Two buttons doing approximately the same
        // thing was confusing — pressing Restore showed no visible
        // feedback, so users pressed Done after, which ran restore a
        // second time. The primaryActionButton below is now the single
        // "Restore"-and-dismiss action with a `.busy` ProgressView
        // while the SDK round-trips. Errors render here.
        if case .error(let message) = viewModel.phase {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}
