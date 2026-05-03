import AppKit
import MatronViewModels

/// Read-only abstraction over `NSPasteboard` so paste detection can be
/// unit-tested against an in-memory fake without touching the system
/// pasteboard. Named `Matron…` (rather than the bare `NSPasteboardReading`)
/// to avoid colliding with AppKit's same-named protocol on `NSPasteboard`
/// itself.
protocol MatronPasteboardReading {
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

/// Production adapter — forwards to `NSPasteboard.general`.
struct LiveNSPasteboard: MatronPasteboardReading {
    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        NSPasteboard.general.string(forType: type)
    }
}

/// Bridges clipboard contents into `RecoveryKeyViewModel.reenteredKey` and
/// auto-advances to `.confirmed` when the value matches the displayed
/// recovery key. Mac users will likely paste the key from a password
/// manager (or from clipboard having copied it on iOS), so this saves them
/// the explicit "Confirm" tap.
///
/// Defensively no-op outside `.generate / .reenter` so a stray "Paste"
/// button press in another phase is a safe affordance.
@MainActor
final class PasteDetector {
    private let pasteboard: MatronPasteboardReading
    private let viewModel: RecoveryKeyViewModel

    init(pasteboard: MatronPasteboardReading, viewModel: RecoveryKeyViewModel) {
        self.pasteboard = pasteboard
        self.viewModel = viewModel
    }

    /// Reads the current clipboard string and, if non-empty and we're in
    /// the right phase, copies it into the view-model's `reenteredKey`. If
    /// that triggers `canFinish`, advance to `.confirmed` so the view can
    /// run its success animation.
    func checkClipboardAndApply() {
        guard viewModel.mode == .generate, viewModel.generatePhase == .reenter else { return }
        guard let candidate = pasteboard.string(forType: .string), !candidate.isEmpty else { return }
        viewModel.reenteredKey = candidate
        if viewModel.canFinish {
            viewModel.generatePhase = .confirmed
        }
    }
}
