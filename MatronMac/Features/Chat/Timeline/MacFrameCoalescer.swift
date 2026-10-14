import AppKit
import QuartzCore

/// Runs `action` once on the next display frame however often it was
/// requested since — the Mac twin of iOS `FrameCoalescer`, on
/// `NSView.displayLink`. Paused whenever idle; `invalidate()` is final.
///
/// An occluded window (behind others, on a locked or sleeping display, a
/// test host's window) gets no display-link ticks at all, so every request
/// also arms a one-shot fallback timer: whichever fires first runs the
/// action and disarms the other. On screen the link always wins.
@MainActor
final class MacFrameCoalescer {
    /// Longer than any real frame (≤ 16.7 ms), short enough that an
    /// occluded timeline still settles promptly.
    static let fallbackDelay: TimeInterval = 0.05

    /// The display link's and timer's target: holds its owner weakly (the
    /// link retains the target, never the owner) and invalidates the link
    /// itself if it ever ticks after the owner is gone.
    private final class Target: NSObject {
        weak var owner: MacFrameCoalescer?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                guard let owner else {
                    link.invalidate()
                    return
                }
                #if DEBUG
                MacFrameCoalescer.noteFirstFire(viaDisplayLink: true)
                #endif
                owner.fire()
            }
        }
        @objc func fallback(_ timer: Timer) {
            MainActor.assumeIsolated {
                // A timer outliving its coalescer is no fire: no breadcrumb.
                guard let owner else { return }
                #if DEBUG
                MacFrameCoalescer.noteFirstFire(viaDisplayLink: false)
                #endif
                owner.fire()
            }
        }
    }

    #if DEBUG
    /// One breadcrumb per process for each path, so a rig `app.log` shows
    /// whether the display link ever ticked or only the fallback timer ran.
    private static var loggedLinkTick = false
    private static var loggedFallback = false
    fileprivate static func noteFirstFire(viaDisplayLink: Bool) {
        if viaDisplayLink, !loggedLinkTick {
            loggedLinkTick = true
            timelineLogger.breadcrumb("mac timeline coalescer: display link ticked")
        } else if !viaDisplayLink, !loggedFallback {
            loggedFallback = true
            timelineLogger.breadcrumb("mac timeline coalescer: fallback timer fired")
        }
    }
    #endif

    /// `nonisolated(unsafe)` only so the nonisolated `deinit` can read them;
    /// every other access is on the main actor.
    nonisolated(unsafe) private var link: CADisplayLink?
    nonisolated(unsafe) private var fallbackTimer: Timer?
    private let target = Target()
    private weak var view: NSView?
    private let action: () -> Void
    private var isInvalidated = false

    init(view: NSView, action: @escaping () -> Void) {
        self.view = view
        self.action = action
        target.owner = self
    }

    deinit {
        let link = link, timer = fallbackTimer
        guard link != nil || timer != nil else { return }
        if Thread.isMainThread {
            link?.invalidate()
            timer?.invalidate()
        } else {
            nonisolated(unsafe) let orphanLink = link
            nonisolated(unsafe) let orphanTimer = timer
            DispatchQueue.main.async {
                orphanLink?.invalidate()
                orphanTimer?.invalidate()
            }
        }
    }

    var isPending: Bool { fallbackTimer != nil }

    func request() {
        guard !isInvalidated, fallbackTimer == nil else { return }
        if link == nil, let view {
            let link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        let timer = Timer(timeInterval: Self.fallbackDelay, target: target,
                          selector: #selector(Target.fallback(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func invalidate() {
        isInvalidated = true
        link?.invalidate()
        link = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    fileprivate func fire() {
        // A tick with nothing requested (the link was unpaused and paused
        // again in between) does nothing.
        guard let timer = fallbackTimer else {
            link?.isPaused = true
            return
        }
        timer.invalidate()
        fallbackTimer = nil
        link?.isPaused = true
        action()
    }
}
