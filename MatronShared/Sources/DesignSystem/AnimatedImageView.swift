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
/// the still, which is hidden once the first frame is up (a transparent
/// GIF must not show its first frame through the later ones).
///
/// Playback pauses whenever the image can't be seen — scrolled out of its
/// scroll view, in a hidden tab, a window that is covered or minimised, an
/// app in the background — and releases its decoded frames while it is
/// paused. With Reduce Motion on it rests on the first frame with a play
/// button; a tap plays it until it goes off screen.
public struct PlayableImage: View {
    let image: Image
    let animation: AnimatedImageSource?
    let interpolation: Image.Interpolation?
    let fullResolution: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameShowing = false
    /// The user's play/pause choice; `nil` until they make one, so the
    /// system setting decides.
    @State private var userWantsPlayback: Bool?

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

    private var plays: Bool { userWantsPlayback ?? !reduceMotion }

    public var body: some View {
        let resizable = image.resizable()
        let still = (interpolation.map { resizable.interpolation($0) } ?? resizable).scaledToFit()
        if let animation {
            still
                .opacity(frameShowing ? 0 : 1)
                .overlay {
                    AnimatedImageRepresentable(
                        source: animation, plays: plays, fullResolution: fullResolution,
                        onFrame: { if !frameShowing { frameShowing = true } }
                    )
                }
                // One element for still and frames: the still goes
                // transparent once frames are up, and would drop out.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Animated image"))
                .accessibilityAddTraits(.isImage)
                .overlay(alignment: .bottomLeading) {
                    if reduceMotion {
                        AnimationPlayButton(playing: plays) { userWantsPlayback = !plays }
                            .padding(6)
                    }
                }
        } else {
            still
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
    /// How often a paused image that is in a window but out of sight
    /// checks whether it has come back into view. Scrolling moves the
    /// image's ancestors, not the image, so there is no event to wait for.
    static let visibilityProbe: TimeInterval = 0.5
}

#if canImport(UIKit) && !os(macOS)

private struct AnimatedImageRepresentable: UIViewRepresentable {
    let source: AnimatedImageSource
    let plays: Bool
    let fullResolution: Bool
    let onFrame: () -> Void

    func makeUIView(context: Context) -> AnimatedImageView {
        AnimatedImageView(source: source, fullResolution: fullResolution)
    }

    func updateUIView(_ view: AnimatedImageView, context: Context) {
        view.onFrame = onFrame
        view.setSource(source, fullResolution: fullResolution)
        view.wantsPlayback = plays
    }

    static func dismantleUIView(_ view: AnimatedImageView, coordinator: ()) {
        view.tearDown()
    }
}

/// The layer the frames are drawn on. Touches pass through to the SwiftUI
/// gestures around it (tap to open, long-press menus).
final class AnimatedImageView: UIView {
    private var player: AnimatedImagePlayer
    private var fullResolution: Bool
    private var probe: Timer?
    /// A paused image's resting frame is on its way.
    private var loadingStill = false
    private var observers: [NSObjectProtocol] = []
    var onFrame: () -> Void = {}

    var wantsPlayback = false {
        didSet {
            guard wantsPlayback != oldValue else { return }
            if wantsPlayback, player.isFinished { player.restart() }
            updatePlayback()
        }
    }

    init(source: AnimatedImageSource, fullResolution: Bool) {
        self.fullResolution = fullResolution
        self.player = AnimatedImagePlayer(source: source, memoryBudget: Self.budget(fullResolution))
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
        backgroundColor = .clear
        attach(player)
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func budget(_ fullResolution: Bool) -> Int {
        fullResolution ? AnimatedImageLimits.fullResolutionBudget : AnimatedImageLimits.inlineBudget
    }

    private func attach(_ player: AnimatedImagePlayer) {
        player.display = { [weak self] frame in
            guard let self else { return }
            // No implicit fade between frames.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = frame
            CATransaction.commit()
            self.onFrame()
            self.frameShown()
        }
    }

    /// A reused cell can hand this view another image.
    func setSource(_ source: AnimatedImageSource, fullResolution: Bool) {
        guard source !== player.source || fullResolution != self.fullResolution else { return }
        player.stop(releasingFrames: true)
        self.fullResolution = fullResolution
        player = AnimatedImagePlayer(source: source, memoryBudget: Self.budget(fullResolution))
        attach(player)
        layer.contents = nil
        updateMaxPixel()
        updatePlayback()
    }

    /// For tests.
    var isPlaying: Bool { player.isRunning }

    func tearDown() {
        probe?.invalidate()
        probe = nil
        player.stop(releasingFrames: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMaxPixel()
        updatePlayback()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMaxPixel()
        updatePlayback()
    }

    private func updateMaxPixel() {
        let source = player.source
        let native = max(source.pixelSize.width, source.pixelSize.height)
        let scale = traitCollection.displayScale
        let drawn = max(bounds.width, bounds.height) * max(scale, 1)
        let wanted = fullResolution ? native : min(native, drawn.rounded(.up))
        player.maxPixel = min(wanted, AnimatedImageLimits.maxPixel)
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

    private func updatePlayback() {
        let canPlay = wantsPlayback && player.maxPixel > 0
        if canPlay && isOnScreen {
            stopProbe()
            player.start()
        } else {
            player.stop(releasingFrames: true)
            // Paused or Reduce Motion: rest on a real frame, not nothing.
            if layer.contents == nil, !loadingStill, player.maxPixel > 0, window != nil {
                loadingStill = true
                Task {
                    await player.showCurrentFrame()
                    loadingStill = false
                }
            }
            if canPlay, window != nil { startProbe() } else { stopProbe() }
        }
    }

    /// Each frame re-checks visibility, so a scroll that takes the image
    /// out of sight stops it within a frame.
    private func frameShown() {
        if player.isRunning, !isOnScreen { updatePlayback() }
    }

    private func startProbe() {
        guard probe == nil else { return }
        let timer = Timer(timeInterval: AnimatedImageLimits.visibilityProbe, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOnScreen { self.updatePlayback() }
            }
        }
        timer.tolerance = AnimatedImageLimits.visibilityProbe / 2
        RunLoop.main.add(timer, forMode: .common)
        probe = timer
    }

    private func stopProbe() {
        probe?.invalidate()
        probe = nil
    }
}

#elseif os(macOS)

private struct AnimatedImageRepresentable: NSViewRepresentable {
    let source: AnimatedImageSource
    let plays: Bool
    let fullResolution: Bool
    let onFrame: () -> Void

    func makeNSView(context: Context) -> AnimatedImageView {
        AnimatedImageView(source: source, fullResolution: fullResolution)
    }

    func updateNSView(_ view: AnimatedImageView, context: Context) {
        view.onFrame = onFrame
        view.setSource(source, fullResolution: fullResolution)
        view.wantsPlayback = plays
    }

    static func dismantleNSView(_ view: AnimatedImageView, coordinator: ()) {
        view.tearDown()
    }
}

/// The layer the frames are drawn on. Clicks pass through to the SwiftUI
/// gestures around it (click to open, right-click menus).
final class AnimatedImageView: NSView {
    private var player: AnimatedImagePlayer
    private var fullResolution: Bool
    private var probe: Timer?
    /// A paused image's resting frame is on its way.
    private var loadingStill = false
    private var windowObservers: [NSObjectProtocol] = []
    var onFrame: () -> Void = {}

    var wantsPlayback = false {
        didSet {
            guard wantsPlayback != oldValue else { return }
            if wantsPlayback, player.isFinished { player.restart() }
            updatePlayback()
        }
    }

    init(source: AnimatedImageSource, fullResolution: Bool) {
        self.fullResolution = fullResolution
        self.player = AnimatedImagePlayer(source: source, memoryBudget: Self.budget(fullResolution))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        attach(player)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func budget(_ fullResolution: Bool) -> Int {
        fullResolution ? AnimatedImageLimits.fullResolutionBudget : AnimatedImageLimits.inlineBudget
    }

    private func attach(_ player: AnimatedImagePlayer) {
        player.display = { [weak self] frame in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = frame
            CATransaction.commit()
            self.onFrame()
            self.frameShown()
        }
    }

    /// A reused row can hand this view another image.
    func setSource(_ source: AnimatedImageSource, fullResolution: Bool) {
        guard source !== player.source || fullResolution != self.fullResolution else { return }
        player.stop(releasingFrames: true)
        self.fullResolution = fullResolution
        player = AnimatedImagePlayer(source: source, memoryBudget: Self.budget(fullResolution))
        attach(player)
        layer?.contents = nil
        updateMaxPixel()
        updatePlayback()
    }

    /// For tests.
    var isPlaying: Bool { player.isRunning }

    func tearDown() {
        probe?.invalidate()
        probe = nil
        player.stop(releasingFrames: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePlayback() }
                })
            }
        }
        updateMaxPixel()
        updatePlayback()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMaxPixel()
    }

    override func layout() {
        super.layout()
        updateMaxPixel()
        updatePlayback()
    }

    private func updateMaxPixel() {
        let source = player.source
        let native = max(source.pixelSize.width, source.pixelSize.height)
        let scale = window?.backingScaleFactor ?? 2
        let drawn = max(bounds.width, bounds.height) * scale
        let wanted = fullResolution ? native : min(native, drawn.rounded(.up))
        player.maxPixel = min(wanted, AnimatedImageLimits.maxPixel)
    }

    /// Whether any of the image can be seen right now: in a window that
    /// is on screen and not covered, and not clipped out by a scroll view.
    var isOnScreen: Bool {
        guard let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 else { return false }
        return !visibleRect.isEmpty
    }

    private func updatePlayback() {
        let canPlay = wantsPlayback && player.maxPixel > 0
        if canPlay && isOnScreen {
            stopProbe()
            player.start()
        } else {
            player.stop(releasingFrames: true)
            if layer?.contents == nil, !loadingStill, player.maxPixel > 0, window != nil {
                loadingStill = true
                Task {
                    await player.showCurrentFrame()
                    loadingStill = false
                }
            }
            if canPlay, window != nil { startProbe() } else { stopProbe() }
        }
    }

    private func frameShown() {
        if player.isRunning, !isOnScreen { updatePlayback() }
    }

    private func startProbe() {
        guard probe == nil else { return }
        let timer = Timer(timeInterval: AnimatedImageLimits.visibilityProbe, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOnScreen { self.updatePlayback() }
            }
        }
        timer.tolerance = AnimatedImageLimits.visibilityProbe / 2
        RunLoop.main.add(timer, forMode: .common)
        probe = timer
    }

    private func stopProbe() {
        probe?.invalidate()
        probe = nil
    }
}

#endif
