import SwiftUI
import UIKit

/// Keeps a chat's composer above the keyboard from UIKit's
/// `keyboardLayoutGuide` instead of SwiftUI's keyboard safe area.
///
/// Tracker #3141 (the composer sitting halfway up the Coordinator tab over an
/// empty band). Measured on the iPhone 17 simulator, 2026-09-25: when a chat
/// comes back on screen with its composer still focused — Back from a chat,
/// item or mission pushed on top of it, which a conversation pill now does
/// (#2954) — UIKit restores the keyboard as the chat reappears, and SwiftUI's
/// keyboard safe area misses it. A `GeometryReader` in the chat reads 83pt
/// (the tab bar alone) while the chat's own `keyboardLayoutGuide` reads the
/// real keyboard at y=539, 335pt tall, so the composer sits hidden under the
/// keyboard. It is not particular to the Coordinator tab: a chat pushed in
/// Conversations does the same. The report's picture is the other half of
/// the same fault — SwiftUI still laying the chat out around a keyboard that
/// has gone — which a keyboard that ever moves while the chat is off screen
/// leaves behind. The next keyboard show/hide seen on screen heals either.
///
/// The layout guide stays right through all of it, so the chat opts out of
/// SwiftUI's keyboard safe area and pads by the guide. It follows the
/// keyboard's own animation and tracks an interactive dismissal frame by
/// frame.
enum ChatKeyboardAvoidance {
    /// How far the keyboard reaches up into a view `viewHeight` tall whose
    /// keyboard guide's top edge is at `keyboardTop` (the view's own
    /// coordinates). Zero when the guide sits at or below the bottom edge:
    /// no keyboard, or one hidden behind the tab bar / home indicator.
    static func overlap(viewHeight: CGFloat, keyboardTop: CGFloat) -> CGFloat {
        max(0, viewHeight - keyboardTop)
    }

    /// The SwiftUI animation for a guide change reported inside a UIKit
    /// animation of `duration` (`UIView.inheritedAnimationDuration`): the
    /// keyboard's show/hide, eased like the system keyboard. `nil` outside
    /// one — an interactive dismissal moves the guide every frame, and the
    /// composer must track the finger exactly.
    static func animation(forInheritedDuration duration: TimeInterval) -> Animation? {
        guard duration > 0 else { return nil }
        return .timingCurve(0.38, 0.7, 0.125, 1, duration: duration)
    }
}

private struct ChatKeyboardAvoidanceModifier: ViewModifier {
    @State private var overlap: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, overlap)
            // Spans the full keyboard-ignoring frame, so its guide overlap
            // is exactly how much of the chat the keyboard covers.
            .background(KeyboardGuideReader(onChange: update))
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func update(_ newOverlap: CGFloat, _ animation: Animation?) {
        guard newOverlap != overlap else { return }
        withAnimation(animation) { overlap = newOverlap }
    }
}

/// An invisible UIKit view that reports its `keyboardLayoutGuide` overlap on
/// every layout pass the guide drives.
private struct KeyboardGuideReader: UIViewRepresentable {
    let onChange: (CGFloat, Animation?) -> Void

    func makeUIView(context: Context) -> KeyboardGuideView {
        let view = KeyboardGuideView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: KeyboardGuideView, context: Context) {
        view.onChange = onChange
    }
}

private final class KeyboardGuideView: UIView {
    var onChange: ((CGFloat, Animation?) -> Void)?
    /// Pinned to the guide's top so a guide move lays this view out.
    private let tracker = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The raw keyboard frame, not keyboard-or-safe-area: the chat's own
        // frame already stops at the home indicator / tab bar.
        keyboardLayoutGuide.usesBottomSafeArea = false
        tracker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tracker)
        NSLayoutConstraint.activate([
            tracker.leadingAnchor.constraint(equalTo: leadingAnchor),
            tracker.widthAnchor.constraint(equalToConstant: 0),
            tracker.heightAnchor.constraint(equalToConstant: 0),
            tracker.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let overlap = ChatKeyboardAvoidance.overlap(viewHeight: bounds.height,
                                                    keyboardTop: keyboardLayoutGuide.layoutFrame.minY)
        let animation = ChatKeyboardAvoidance.animation(forInheritedDuration: UIView.inheritedAnimationDuration)
        // Out of UIKit's layout pass before SwiftUI state changes.
        DispatchQueue.main.async { [weak self] in self?.onChange?(overlap, animation) }
    }
}

extension View {
    /// See `ChatKeyboardAvoidance`.
    func chatKeyboardAvoidance() -> some View {
        modifier(ChatKeyboardAvoidanceModifier())
    }
}
