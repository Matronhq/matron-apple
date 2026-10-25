import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Hiding the iOS keyboard from a composer row. Two gestures reach the
/// same intent — dragging the timeline down through the keyboard
/// (`ScrollView.scrollDismissesKeyboard(.interactively)`, applied at each
/// timeline) and dragging the composer row itself downward, which is the
/// gesture people actually reach for when they want the screen back to
/// read. The latter has no SwiftUI equivalent, so it lives here.
public enum KeyboardDismiss {
    /// Drops the keyboard by resigning whatever is first responder. The
    /// composers are plain `TextField`s with no `@FocusState` seam of
    /// their own (same reason `ChatPagerModel` resigns this way), so the
    /// responder chain is the only handle. A no-op on the Mac.
    public static func resign() {
        #if canImport(UIKit) && !os(macOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Whether a drag on the composer row has become a "hide the
    /// keyboard" gesture: mostly vertical and downward by at least
    /// `minimumDrop` points. Upward and sideways drags (text selection,
    /// a slip while reaching for the send button) never count.
    static func shouldDismiss(translation: CGSize, minimumDrop: CGFloat = 24) -> Bool {
        translation.height >= minimumDrop && translation.height > abs(translation.width)
    }
}

public extension View {
    /// Dragging this view downward hides the keyboard (iOS only; the
    /// modifier is inert on the Mac). Attached as a *simultaneous*
    /// gesture so the field's own touches — caret placement, selection,
    /// scrolling a tall draft — keep working; the dismissal simply fires
    /// alongside them once the drag reads as a deliberate pull-down.
    func dragDownDismissesKeyboard() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    if KeyboardDismiss.shouldDismiss(translation: value.translation) {
                        KeyboardDismiss.resign()
                    }
                }
        )
        #else
        return self
        #endif
    }
}

public extension View {
    /// A swipe down anywhere in this view's window hides the keyboard
    /// while the view is on screen. That includes system chrome the view
    /// can't attach a gesture to, like a search tab's field, which sits
    /// in the tab bar right on top of the keyboard. The recognizer
    /// watches alongside every other touch handler and never cancels or
    /// delays their touches. The keyboard itself is a separate window
    /// whose touches nothing in the app sees. A no-op on the Mac.
    ///
    /// A hidden tab or a covered stack root can stay in the window, so
    /// pass `isActive` false whenever this view isn't the one showing;
    /// the recognizer comes off the window then.
    func swipeDownInWindowDismissesKeyboard(isActive: Bool = true) -> some View {
        #if canImport(UIKit) && !os(macOS)
        return background {
            if isActive {
                WindowSwipeDownDismisser().frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        #else
        return self
        #endif
    }
}

#if canImport(UIKit) && !os(macOS)
private struct WindowSwipeDownDismisser: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.detach() }

    /// Adds the pan recognizer to whichever window it lands in, and takes
    /// it off again when it leaves.
    final class Probe: UIView, UIGestureRecognizerDelegate {
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            return pan
        }()
        private weak var host: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== host else { return }
            detach()
            if let window {
                window.addGestureRecognizer(pan)
                host = window
            }
        }

        func detach() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .changed else { return }
            let t = pan.translation(in: pan.view)
            if KeyboardDismiss.shouldDismiss(translation: CGSize(width: t.x, height: t.y)) {
                KeyboardDismiss.resign()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
