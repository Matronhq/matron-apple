import SwiftUI

public extension View {
    /// Distinguishes *user-initiated* scrolling from programmatic scrolls
    /// and layout drift, via `onScrollPhaseChange` (iOS 18 / macOS 15).
    ///
    /// This distinction is what makes a sticky "following the tail" mode
    /// possible in the chat timeline: a `.scrollPosition(id:)` binding
    /// alone can't tell a finger-drag from LazyVStack height-estimation
    /// churn (a streaming reply growing its row drags the viewport up —
    /// the 2026-07-13 "chat disappeared for a moment" traces), so any
    /// at-tail heuristic derived from the binding is disabled by the very
    /// drift it's meant to heal. Gesture phases are unambiguous: only a
    /// real drag reports `.interacting`/`.tracking`.
    ///
    /// On older OS versions this is a no-op and callers fall back to the
    /// binding heuristic.
    ///
    /// - Parameters:
    ///   - begin: the user put their finger down and started dragging.
    ///   - settle: scrolling came to rest (any cause — drag, fling,
    ///     programmatic scroll, drift correction).
    @ViewBuilder
    func onUserScrollGesture(
        begin: @escaping () -> Void,
        settle: @escaping () -> Void
    ) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.onScrollPhaseChange { oldPhase, newPhase in
                switch newPhase {
                case .tracking, .interacting:
                    begin()
                case .idle where oldPhase != .idle:
                    settle()
                default:
                    break
                }
            }
        } else {
            self
        }
    }
}
