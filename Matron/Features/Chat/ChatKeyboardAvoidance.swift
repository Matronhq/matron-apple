import SwiftUI
import UIKit

/// Keeps a chat's composer above the keyboard from UIKit's
/// `keyboardLayoutGuide` instead of SwiftUI's keyboard safe area.
///
/// The bug: the composer sitting halfway up the Coordinator tab over an
/// empty band. Measured on the iPhone 17 simulator, 2026-09-25: when a chat
/// comes back on screen with its composer still focused — Back from a chat,
/// item or mission pushed on top of it, which a conversation pill now does
/// — UIKit restores the keyboard as the chat reappears, and SwiftUI's
/// keyboard safe area misses it. A `GeometryReader` in the chat reads 83pt
/// (the tab bar alone) while the chat's own `keyboardLayoutGuide` reads the
/// real keyboard at y=539, 335pt tall, so the composer sits hidden under the
/// keyboard. It is not particular to the Coordinator tab: a chat pushed in
/// Conversations does the same. The report's picture is the other half of
/// the same fault — SwiftUI still laying the chat out around a keyboard that
/// has gone — which a keyboard that ever moves while the chat is off screen
/// leaves behind. The next keyboard show/hide seen on screen heals either.
///
/// So the chat opts out of SwiftUI's keyboard safe area and pads by the
/// keyboard itself. It follows the keyboard's own animation and tracks an
/// interactive dismissal frame by frame.
///
/// The keyboard's frame notifications are the source of truth, not the
/// layout guide. Measured on the iPhone 17 simulator, 2026-10-22: put the
/// app in the background with the composer focused and bring it back. The
/// keyboard returns, and `keyboardWillShow` reports it at y=546, but the
/// chat's `keyboardLayoutGuide` stays at the bottom edge. It never moves
/// again for that chat: later shows, hides and fresh focuses all leave it
/// where it is. Read alone, the guide hid the composer under a visible
/// keyboard. When it sticks the other way it leaves the composer raised
/// over an empty band with no keyboard, and nothing heals it: there is no
/// keyboard to drag down. The notifications stay right throughout, so they
/// decide how far the keyboard reaches, and the guide is only used, capped
/// by them, to follow an interactive dismissal that has no notifications
/// of its own.
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

    /// How far a keyboard at `keyboardFrame` reaches up into a view at
    /// `viewFrame`, both in screen coordinates, on a screen `screenBounds`
    /// big. Zero for a hidden keyboard (off the bottom edge, or zero
    /// height), and for one that is not docked to the bottom edge (iPad's
    /// floating and split keyboards, which the layout guide ignores too).
    static func overlap(keyboardFrame: CGRect, viewFrame: CGRect, screenBounds: CGRect) -> CGFloat {
        guard keyboardFrame.height > 0,
              keyboardFrame.maxY >= screenBounds.maxY - 0.5,
              keyboardFrame.minX < viewFrame.maxX, keyboardFrame.maxX > viewFrame.minX
        else { return 0 }
        return max(0, viewFrame.maxY - keyboardFrame.minY)
    }

    /// The overlap to report from a layout pass. `notified` is the overlap
    /// the keyboard's last frame notification gives (`nil` before the app
    /// has seen one). `guide` is the layout guide's, and `guideMoved` says
    /// whether it changed since the last pass. Inside a UIKit animation
    /// (`animating`) the keyboard's own show/hide or a rotation is running,
    /// and the notification has the answer. Outside one, a guide that moves
    /// is following an interactive dismissal, and it is believed up to the
    /// notified overlap. A guide that has stopped tracking never moves, so
    /// it never overrides the notification. Around a trip to the
    /// background (`trustsGuide` false: the app is not active, or became
    /// active moments ago) the guide is where it goes wrong, and it can
    /// jump once on its way to being stuck, so it is not believed at all.
    static func layoutOverlap(guide: CGFloat, guideMoved: Bool, notified: CGFloat?,
                              animating: Bool, trustsGuide: Bool = true) -> CGFloat {
        guard let notified else { return guide }
        if guideMoved, !animating, trustsGuide { return min(guide, notified) }
        return notified
    }
}

/// The keyboard's last reported frame, app-wide, from its frame
/// notifications. Started at launch so a chat created later still knows
/// where the keyboard is. Each chat's `KeyboardGuideView` registers to hear
/// about changes.
@MainActor
final class KeyboardFrameTracker {
    static let shared = KeyboardFrameTracker()

    /// The keyboard's frame in screen coordinates; `nil` until the first
    /// notification, `.zero` once it has hidden.
    private(set) var frame: CGRect?
    private var listeners: [ObjectIdentifier: (TimeInterval) -> Void] = [:]

    private init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardDidHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
                let hides = name == UIResponder.keyboardWillHideNotification
                    || name == UIResponder.keyboardDidHideNotification
                MainActor.assumeIsolated { self?.record(end: end, hides: hides, duration: duration) }
            }
        }
    }

    /// Starts listening; call once at launch.
    static func start() { _ = shared }

    private func record(end: CGRect?, hides: Bool, duration: TimeInterval) {
        if hides {
            // No keyboard whatever the end frame says, so a hide always
            // lowers the composer.
            frame = .zero
        } else if let end {
            frame = end
        } else {
            return
        }
        for listener in listeners.values { listener(duration) }
    }

    func addListener(_ owner: AnyObject, _ listener: @escaping (TimeInterval) -> Void) {
        listeners[ObjectIdentifier(owner)] = listener
    }

    func removeListener(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
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

/// An invisible UIKit view that reports how far the keyboard covers it: on
/// every keyboard frame notification, on every layout pass (its
/// `keyboardLayoutGuide` drives one for each frame of an interactive
/// dismissal), and whenever it comes back into a window or the app comes
/// back to the foreground.
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

    /// The guide's overlap at the last layout pass, to tell a guide that
    /// moved from one that did not.
    private var lastGuideOverlap: CGFloat?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        KeyboardFrameTracker.shared.removeListener(self)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        guard window != nil else { return }
        KeyboardFrameTracker.shared.addListener(self) { [weak self] duration in
            self?.reportNotified(duration: duration)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        // The keyboard may have come or gone while this chat was off screen.
        reportNotified(duration: 0)
    }

    /// Until when the guide is not believed: see `layoutOverlap`.
    private var guideDistrustedUntil = Date.distantPast

    @objc private func didBecomeActive() {
        guideDistrustedUntil = Date().addingTimeInterval(1)
        reportNotified(duration: 0)
    }

    private var trustsGuide: Bool {
        UIApplication.shared.applicationState == .active && Date() >= guideDistrustedUntil
    }

    /// The overlap the keyboard's last frame notification gives, for this
    /// view where it is now; `nil` before any notification or out of a
    /// window.
    private var notifiedOverlap: CGFloat? {
        guard let keyboard = KeyboardFrameTracker.shared.frame, let screen = window?.screen else { return nil }
        let space = screen.coordinateSpace
        return ChatKeyboardAvoidance.overlap(keyboardFrame: keyboard,
                                             viewFrame: convert(bounds, to: space),
                                             screenBounds: space.bounds)
    }

    private func reportNotified(duration: TimeInterval) {
        guard let overlap = notifiedOverlap else { return }
        report(overlap, ChatKeyboardAvoidance.animation(forInheritedDuration: duration))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let guide = ChatKeyboardAvoidance.overlap(viewHeight: bounds.height,
                                                  keyboardTop: keyboardLayoutGuide.layoutFrame.minY)
        let inherited = UIView.inheritedAnimationDuration
        let overlap = ChatKeyboardAvoidance.layoutOverlap(guide: guide,
                                                          guideMoved: guide != lastGuideOverlap,
                                                          notified: notifiedOverlap,
                                                          animating: inherited > 0,
                                                          trustsGuide: trustsGuide)
        lastGuideOverlap = guide
        report(overlap, ChatKeyboardAvoidance.animation(forInheritedDuration: inherited))
    }

    private func report(_ overlap: CGFloat, _ animation: Animation?) {
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
