import SwiftUI
import MatronModels
#if canImport(UIKit) && !os(macOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An image that plays when its file is an animated GIF, APNG or WebP.
///
/// Laid out exactly like `image.resizable().scaledToFit()` (the still is
/// what sizes it), so swapping it in for a plain image changes nothing
/// around it. With an `animation`, the frames play on a layer laid over
/// the still, which is hidden while a frame is up (a transparent GIF must
/// not show its first frame through the later ones).
///
/// Playback pauses whenever the image can't be seen — scrolled out of its
/// scroll view, in a hidden tab, a window that is covered or minimised, an
/// app in the background — and gives back its decoded frames while it is
/// paused, showing the still again. With Reduce Motion on it rests on the
/// still with a play button; once tapped it plays whenever it is in sight,
/// until it is tapped again.
public struct PlayableImage: View {
    let image: Image
    let animation: AnimatedImageSource?
    let interpolation: Image.Interpolation?
    let fullResolution: Bool

    /// `fullResolution` decodes frames at the file's own size (capped)
    /// rather than the size on screen — for the full-screen viewer, whose
    /// zoom scales the layer up.
    public init(_ image: Image, animation: AnimatedImageSource?,
                interpolation: Image.Interpolation? = nil, fullResolution: Bool = false) {
        self.image = image
        self.animation = animation
        self.interpolation = interpolation
        self.fullResolution = fullResolution
    }

    public var body: some View {
        let resizable = image.resizable()
        let still = (interpolation.map { resizable.interpolation($0) } ?? resizable).scaledToFit()
        if let animation {
            AnimatedStill(still: still, animation: animation, fullResolution: fullResolution)
                // A reused row handed another animation starts afresh: its
                // "frame showing" and the user's play choice belong to the
                // old one.
                .id(ObjectIdentifier(animation))
        } else {
            still
        }
    }
}

private struct AnimatedStill<Still: View>: View {
    let still: Still
    let animation: AnimatedImageSource
    let fullResolution: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameShowing = false
    /// The user's play/pause choice; `nil` until they make one, so the
    /// system setting decides.
    @State private var userWantsPlayback: Bool?

    private var plays: Bool { userWantsPlayback ?? !reduceMotion }

    var body: some View {
        still
            .opacity(frameShowing ? 0 : 1)
            .overlay {
                AnimatedImageRepresentable(
                    source: animation, plays: plays, fullResolution: fullResolution,
                    onFrame: { showing in if frameShowing != showing { frameShowing = showing } }
                )
            }
            // One element for still and frames: the still goes
            // transparent while frames are up, and would drop out.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Animated image"))
            .accessibilityAddTraits(.isImage)
            .overlay(alignment: .bottomLeading) {
                if reduceMotion || userWantsPlayback != nil {
                    AnimationPlayButton(playing: plays) { userWantsPlayback = !plays }
                        .padding(6)
                }
            }
    }
}

/// The play/pause badge Reduce Motion shows on an animated image.
private struct AnimationPlayButton: View {
    let playing: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                Text(verbatim: "GIF")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause animation" : "Play animation")
    }
}

/// How much decoded animation one image may keep between loops, and the
/// largest frame it decodes. A thread image is at most 280 pt, so 840 px
/// at 3×: about 2.8 MB a frame, and this keeps a short GIF whole.
enum AnimatedImageLimits {
    static let inlineBudget = 16 * 1024 * 1024
    static let fullResolutionBudget = 48 * 1024 * 1024
    static let maxPixel: CGFloat = 2048
}


/// What both platforms' frame views share: when to play, and what to show
/// while not playing. The view supplies the platform answers.
@MainActor
final class AnimatedPlayback {
    private(set) var player: AnimatedImagePlayer
    private let fullResolution: Bool
    /// Whether frames should play when the image is in sight (autoplay, or
    /// the user's tap under Reduce Motion).
    var wantsPlayback = false {
        didSet {
            guard wantsPlayback != oldValue else { return }
            if wantsPlayback, player.isFinished { player.restart() }
            update()
        }
    }
    /// Tells SwiftUI whether a frame is up (so the still can hide).
    var onFrame: (Bool) -> Void = { _ in }

    /// Platform hooks.
    var isOnScreen: () -> Bool = { false }
    var setContents: (CGImage?) -> Void = { _ in }
    var hasContents: () -> Bool = { false }

    private var reportedFrame = false

    init(source: AnimatedImageSource, fullResolution: Bool) {
        self.fullResolution = fullResolution
        self.player = AnimatedImagePlayer(source: source, memoryBudget: fullResolution
            ? AnimatedImageLimits.fullResolutionBudget : AnimatedImageLimits.inlineBudget)
        attach()
    }

    private func attach() {
        let player = self.player
        player.display = { [weak self, weak player] frame in
            guard let self, let player, player === self.player else { return false }
            self.setContents(frame)
            self.report(true)
            // Each frame re-checks visibility, so a scroll that takes the
            // image out of sight stops it within a frame.
            if !self.isOnScreen() { self.update() }
            return true
        }
    }

    /// The decode size for an image drawn `drawnPixels` on its longer side.
    func setDrawnSize(_ drawnPixels: CGFloat) {
        let native = max(player.source.pixelSize.width, player.source.pixelSize.height)
        let wanted = fullResolution ? native : min(native, drawnPixels.rounded(.up))
        player.maxPixel = min(wanted, AnimatedImageLimits.maxPixel)
    }

    /// Plays when wanted and in sight; otherwise stops. An image that would
    /// play but can't be seen gives back its frames and shows the still; a
    /// paused one (Reduce Motion) keeps the frame it stopped on.
    func update() {
        if wantsPlayback, player.maxPixel > 0, isOnScreen() {
            player.start()
        } else if wantsPlayback {
            player.stop(releasingFrames: true)
            if hasContents() {
                setContents(nil)
                report(false)
            }
        } else {
            player.stop(releasingFrames: false)
        }
    }

    func tearDown() {
        player.stop(releasingFrames: true)
    }

    /// SwiftUI state can't change while it is updating views, which is
    /// when a frame view hears about layout and window moves.
    private func report(_ showing: Bool) {
        guard showing != reportedFrame else { return }
        reportedFrame = showing
        let onFrame = self.onFrame
        DispatchQueue.main.async { onFrame(showing) }
    }
}

#if canImport(UIKit) && !os(macOS)

private struct AnimatedImageRepresentable: UIViewRepresentable {
    let source: AnimatedImageSource
    let plays: Bool
    let fullResolution: Bool
    let onFrame: (Bool) -> Void

    func makeUIView(context: Context) -> AnimatedImageView {
        AnimatedImageView(source: source, fullResolution: fullResolution)
    }

    func updateUIView(_ view: AnimatedImageView, context: Context) {
        view.playback.onFrame = onFrame
        view.playback.wantsPlayback = plays
    }

    static func dismantleUIView(_ view: AnimatedImageView, coordinator: ()) {
        view.playback.tearDown()
    }
}

/// The layer the frames are drawn on. Touches pass through to the SwiftUI
/// gestures around it (tap to open, long-press menus).
final class AnimatedImageView: UIView {
    let playback: AnimatedPlayback
    private var observers: [NSObjectProtocol] = []
    private var scrollObservations: [NSKeyValueObservation] = []

    init(source: AnimatedImageSource, fullResolution: Bool) {
        playback = AnimatedPlayback(source: source, fullResolution: fullResolution)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
        backgroundColor = .clear
        playback.isOnScreen = { [weak self] in self?.isOnScreen ?? false }
        playback.hasContents = { [weak self] in self?.layer.contents != nil }
        playback.setContents = { [weak self] frame in
            // No implicit fade between frames.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer.contents = frame
            CATransaction.commit()
        }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.playback.update() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// For tests.
    var isPlaying: Bool { playback.player.isRunning }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Scrolling moves the image's ancestors, not the image: watch every
        // scroll view it sits in, so a paused image starts again as it
        // scrolls back into sight.
        scrollObservations = []
        if window != nil {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    scrollObservations.append(scrollView.observe(\.contentOffset) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.scrolled() }
                    })
                }
                view = current.superview
            }
        }
        updateDrawnSize()
        playback.update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawnSize()
        playback.update()
    }

    private func scrolled() {
        // A playing image checks itself every frame; only a paused one
        // needs telling.
        guard playback.wantsPlayback, !playback.player.isRunning else { return }
        if isOnScreen { playback.update() }
    }

    private func updateDrawnSize() {
        playback.setDrawnSize(max(bounds.width, bounds.height) * max(traitCollection.displayScale, 1))
    }

    /// Whether any of the image can be seen right now.
    var isOnScreen: Bool {
        guard let window, !bounds.isEmpty, window.windowScene?.activationState == .foregroundActive
        else { return false }
        var visible = convert(bounds, to: window)
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return false }
            if current.clipsToBounds, current !== self, let superview = current.superview {
                visible = visible.intersection(superview.convert(current.frame, to: window))
            }
            view = current.superview
        }
        return !visible.intersection(window.bounds).isEmpty
    }
}

#elseif os(macOS)

private struct AnimatedImageRepresentable: NSViewRepresentable {
    let source: AnimatedImageSource
    let plays: Bool
    let fullResolution: Bool
    let onFrame: (Bool) -> Void

    func makeNSView(context: Context) -> AnimatedImageView {
        AnimatedImageView(source: source, fullResolution: fullResolution)
    }

    func updateNSView(_ view: AnimatedImageView, context: Context) {
        view.playback.onFrame = onFrame
        view.playback.wantsPlayback = plays
    }

    static func dismantleNSView(_ view: AnimatedImageView, coordinator: ()) {
        view.playback.tearDown()
    }
}

/// The layer the frames are drawn on. Clicks pass through to the SwiftUI
/// gestures around it (click to open, right-click menus).
final class AnimatedImageView: NSView {
    let playback: AnimatedPlayback
    private var windowObservers: [NSObjectProtocol] = []

    init(source: AnimatedImageSource, fullResolution: Bool) {
        playback = AnimatedPlayback(source: source, fullResolution: fullResolution)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        playback.isOnScreen = { [weak self] in self?.isOnScreen ?? false }
        playback.hasContents = { [weak self] in self?.layer?.contents != nil }
        playback.setContents = { [weak self] frame in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = frame
            CATransaction.commit()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// For tests.
    var isPlaying: Bool { playback.player.isRunning }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            let center = NotificationCenter.default
            let observe = { [weak self] (name: Notification.Name, object: AnyObject) in
                guard let self else { return }
                self.windowObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.changed() }
                })
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observe(name, window)
            }
            // Scrolling moves the image's ancestors, not the image: watch
            // every clip view it sits in, so a paused image starts again
            // as it scrolls back into sight.
            var view = superview
            while let current = view {
                if let clip = current as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    observe(NSView.boundsDidChangeNotification, clip)
                }
                view = current.superview
            }
        }
        updateDrawnSize()
        playback.update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawnSize()
    }

    override func layout() {
        super.layout()
        updateDrawnSize()
        playback.update()
    }

    private func changed() {
        // A playing image checks itself every frame; a paused one needs
        // telling when it may have come back (a scroll, the window shown).
        if playback.player.isRunning, isOnScreen { return }
        playback.update()
    }

    private func updateDrawnSize() {
        playback.setDrawnSize(max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2))
    }

    /// Whether any of the image can be seen right now: in a window that
    /// is on screen and not covered, and not clipped out by a scroll view.
    var isOnScreen: Bool {
        guard let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 else { return false }
        return !visibleRect.isEmpty
    }
}

#endif
