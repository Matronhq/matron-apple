#if DEBUG || MATRON_PERF_PROBE
import UIKit

/// Frame pacing while a list scrolls, for measuring real swipes (a UI test
/// or a finger) rather than the timeline probe's steady auto-scroll.
/// Enabled by `MATRON_PERF_SCROLL_FRAMES=1` in a DEBUG or `MATRON_PERF_PROBE`
/// build. Every display frame it reads the content offset of the tallest
/// list on screen; the frames in which that offset moved are counted, and
/// a frame arriving more than 1.5 frame-durations after the one before is a
/// hitch. The running totals are written to `tmp/scroll-frames.json`.
///
/// With `MATRON_PERF_FLICKS=<n>` it also flicks the list itself, from end
/// to end and back `n` times, starting `MATRON_PERF_FLICK_AFTER_S` seconds (default 15)
/// after launch: each flick sets off at `MATRON_PERF_FLICK_SPEED` points a
/// second (default 5000) and slows the way a scroll view decelerates. That
/// leaves the test runner idle while it measures, as its element queries
/// between swipes stall the main thread themselves. `tmp/scroll-frames.done`
/// marks the end.
@MainActor
final class ScrollFramesProbe: NSObject {
    struct Report: Codable {
        var frames = 0
        var hitches = 0
        var hitchMilliseconds = 0.0
        var scrollSeconds = 0.0
        var worstFrameMilliseconds = 0.0
        /// Scrolling frames in which the list's top inset or its place
        /// in the window changed: the bars above it resizing.
        var layoutJumps = 0
        /// Scrolling frames that moved the other way from the frame
        /// before, inside the content (a bounce at either end is not one).
        var reversals = 0
        /// How far, in points, the list's top and top inset moved in
        /// those frames.
        var layoutTravel = 0.0
    }

    private static var shared: ScrollFramesProbe?
    private var link: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var lastOffset: CGFloat?
    private var lastDelta: CGFloat = 0
    private var lastLayout: CGRect?
    private var lastScrollingTick: CFTimeInterval?
    private var ticks = 0
    private var report = Report()
    private var flicker: Flicker?

    /// Flicks the list from inside the app, as a finger would set it off.
    struct Flicker {
        var remaining: Int
        let speed: CGFloat
        var startAt: CFTimeInterval
        var velocity: CGFloat = 0
        var down = true
        var restUntil: CFTimeInterval = 0
        var lastTimestamp: CFTimeInterval?

        /// Moves `scrollView` one frame; returns false once every flick is done.
        mutating func step(_ scrollView: UIScrollView, at timestamp: CFTimeInterval) -> Bool {
            defer { lastTimestamp = timestamp }
            guard timestamp >= startAt, timestamp >= restUntil else { return true }
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            if velocity == 0 {
                guard remaining > 0 else { return false }
                if down, scrollView.contentOffset.y >= maxY - 1 { down = false; remaining -= 1 }
                else if !down, scrollView.contentOffset.y <= minY + 1 { down = true; remaining -= 1 }
                guard remaining > 0 else { return false }
                velocity = down ? speed : -speed
                return true
            }
            let dt = CGFloat(timestamp - (lastTimestamp ?? timestamp))
            var y = scrollView.contentOffset.y + velocity * dt
            // UIScrollView.DecelerationRate.normal: 0.998 per millisecond.
            velocity *= pow(0.998, dt * 1000)
            if y <= minY || y >= maxY || abs(velocity) < 20 {
                y = min(max(y, minY), maxY)
                velocity = 0
                restUntil = timestamp + 0.3
            }
            scrollView.contentOffset.y = y
            return true
        }
    }

    static func startIfRequested(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["MATRON_PERF_SCROLL_FRAMES"] == "1", shared == nil else { return }
        let probe = ScrollFramesProbe()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: doneURL)
        if let flicks = environment["MATRON_PERF_FLICKS"].flatMap(Int.init), flicks > 0 {
            probe.flicker = Flicker(remaining: flicks * 2,
                                    speed: CGFloat(environment["MATRON_PERF_FLICK_SPEED"].flatMap(Double.init) ?? 5000),
                                    startAt: CACurrentMediaTime()
                                        + (environment["MATRON_PERF_FLICK_AFTER_S"].flatMap(Double.init) ?? 15))
        }
        let link = CADisplayLink(target: probe, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        probe.link = link
        shared = probe
    }

    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("scroll-frames.json") }
    static var doneURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("scroll-frames.done") }

    @objc private func tick(_ link: CADisplayLink) {
        ticks += 1
        if scrollView?.window == nil || ticks % 30 == 0 { scrollView = Self.tallestList() }
        guard let scrollView else { lastOffset = nil; lastScrollingTick = nil; return }
        if var flicker {
            if flicker.step(scrollView, at: link.timestamp) {
                self.flicker = flicker
            } else {
                self.flicker = nil
                if let data = try? JSONEncoder().encode(report) { try? data.write(to: Self.url) }
                try? Data().write(to: Self.doneURL)
            }
        }
        let offset = scrollView.contentOffset.y
        // The list's top inset and its top in the window, packed in a rect.
        let top = scrollView.superview?.convert(scrollView.frame.origin, to: nil).y ?? 0
        let layout = CGRect(x: scrollView.adjustedContentInset.top, y: top, width: 0, height: scrollView.frame.height)
        defer { lastOffset = offset; lastLayout = layout }
        guard let lastOffset, offset != lastOffset else { lastScrollingTick = nil; lastDelta = 0; return }
        let delta = offset - lastOffset
        defer { lastDelta = delta }
        if let previous = lastScrollingTick {
            if let lastLayout, layout != lastLayout {
                report.layoutJumps += 1
                report.layoutTravel += abs(layout.minY - lastLayout.minY) + abs(layout.minX - lastLayout.minX)
            }
            let minY = -scrollView.adjustedContentInset.top
            let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            if delta * lastDelta < 0, offset > minY, offset < maxY, lastOffset > minY, lastOffset < maxY {
                report.reversals += 1
            }
            let interval = link.timestamp - previous
            report.frames += 1
            report.scrollSeconds += interval
            report.worstFrameMilliseconds = max(report.worstFrameMilliseconds, interval * 1000)
            if interval > link.duration * 1.5 {
                report.hitches += 1
                report.hitchMilliseconds += (interval - link.duration) * 1000
            }
            if report.frames % 30 == 0, let data = try? JSONEncoder().encode(report) {
                try? data.write(to: Self.url)
            }
        }
        lastScrollingTick = link.timestamp
    }

    /// The list on show: the visible vertical scroll view with the most
    /// content, so a row's own sideways scroller is never picked.
    private static func tallestList() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if let scroll = view as? UIScrollView, scroll.bounds.height > 200,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(walk)
        }
        windows.filter(\.isKeyWindow).forEach(walk)
        return best
    }
}
#endif
