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

    /// What another gesture recognizer on the same touch is doing, as far
    /// as the composer's pull-down cares.
    struct OtherGesture: Equatable {
        /// It belongs to a text view (the field, or a selection handle
        /// or loupe drawn inside it).
        var isOnText: Bool
        /// It is a scroll view's own pan: a tall draft scrolling, which
        /// is not editing.
        var isScrollPan: Bool
        /// It has recognized (began or changed).
        var isActive: Bool
    }

    /// Whether the text has taken the touch for itself: one of the text
    /// view's own gestures, other than plain scrolling, is running. That
    /// is a selection handle being dragged, the caret being moved with
    /// the loupe, or a long-press selection being extended. A plain swipe
    /// down on the text starts none of those, so it still hides the
    /// keyboard, as in Messages.
    static func textIsEditing(_ others: [OtherGesture]) -> Bool {
        others.contains { $0.isOnText && $0.isActive && !$0.isScrollPan }
    }
}

public extension View {
    /// Dragging this view downward hides the keyboard (iOS only; the
    /// modifier is inert on the Mac), wherever the drag starts on it,
    /// the text field included. A drag the text takes for itself
    /// (dragging a selection handle, moving the caret, extending a
    /// selection) never does: once the text's own gesture starts, the
    /// pull-down stands aside until the finger lifts. The recognizer
    /// watches alongside the field's own touches and never cancels or
    /// delays them.
    func dragDownDismissesKeyboard() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return background {
            RowSwipeDownDismisser().accessibilityHidden(true)
        }
        #else
        return self
        #endif
    }
}

#if canImport(UIKit) && !os(macOS)
/// A zero-content view the size of the composer row. It puts a pan
/// recognizer on the window (touches on the text field never reach a
/// view behind it) and only takes touches that land inside its own
/// frame.
private struct RowSwipeDownDismisser: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()
        private weak var host: UIWindow?
        /// The finger this pan is following.
        private weak var touch: UITouch?
        /// Set once the text takes the touch; holds until the finger lifts.
        private var standingAside = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        /// A drag on a selection handle never gets here: the handle's own
        /// recognizer holds this pan off for the whole drag. Moving the
        /// caret with the loupe does, and stands aside below.
        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed:
                if !standingAside, let touch, KeyboardDismiss.textIsEditing(others(on: touch)) {
                    standingAside = true
                }
                guard !standingAside, pan.state == .changed else { return }
                let t = pan.translation(in: pan.view)
                if KeyboardDismiss.shouldDismiss(translation: CGSize(width: t.x, height: t.y)) {
                    KeyboardDismiss.resign()
                }
            default:
                standingAside = false
            }
        }

        private func others(on touch: UITouch) -> [KeyboardDismiss.OtherGesture] {
            (touch.gestureRecognizers ?? []).compactMap { other in
                guard other !== pan else { return nil }
                return KeyboardDismiss.OtherGesture(
                    isOnText: Self.isOnText(other.view),
                    isScrollPan: (other.view as? UIScrollView)?.panGestureRecognizer === other,
                    isActive: other.state == .began || other.state == .changed)
            }
        }

        /// A view inside a text view or field: the text itself, or the
        /// selection handles and loupe it draws.
        private static func isOnText(_ view: UIView?) -> Bool {
            var view = view
            while let current = view {
                if current is UITextInput { return true }
                view = current.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard window != nil, bounds.contains(touch.location(in: self)) else { return false }
            self.touch = touch
            standingAside = false
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

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

        /// A drag on a selection handle never gets here: the handle's own
        /// recognizer holds this pan off for the whole drag. Moving the
        /// caret with the loupe does, and stands aside below.
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
