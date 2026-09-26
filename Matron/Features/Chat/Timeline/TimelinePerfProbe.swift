#if DEBUG || MATRON_PERF_PROBE
import UIKit
import Darwin
import MatronModels

/// Frame-pacing accounting for the perf gate: a frame arriving more than
/// 1.5 frame-durations after the previous one is a hitch, and the time it
/// was late is hitch time.
struct HitchCounter: Equatable {
    private(set) var frames = 0
    private(set) var hitches = 0
    private(set) var hitchSeconds: Double = 0
    private var last: CFTimeInterval?

    mutating func frame(at timestamp: CFTimeInterval, duration: CFTimeInterval) {
        defer { last = timestamp }
        guard let last else { return }
        frames += 1
        let interval = timestamp - last
        if interval > duration * 1.5 {
            hitches += 1
            hitchSeconds += interval - duration
        }
    }
}

/// Spec §1/§4 rig: auto-scrolls the timeline for `duration` seconds,
/// bouncing between the ends at `pointsPerFrame`, and writes CPU seconds
/// (getrusage, this process) + hitches to `tmp/timeline-perf.json`.
/// Enabled only by `MATRON_PERF_AUTOSCROLL_PT` in a DEBUG or
/// `MATRON_PERF_PROBE` build — compiled out of normal Release/App Store
/// builds. It is the one exempt `contentOffset` writer (controller ruling
/// F8): it stands in for a user's finger.
@MainActor
final class TimelinePerfProbe: NSObject {
    struct Config: Equatable {
        let pointsPerFrame: CGFloat
        let duration: TimeInterval

        static func fromEnvironment(_ environment: [String: String]) -> Config? {
            guard let raw = environment["MATRON_PERF_AUTOSCROLL_PT"], let points = Double(raw), points > 0 else {
                return nil
            }
            return Config(pointsPerFrame: CGFloat(points),
                          duration: environment["MATRON_PERF_DURATION_S"].flatMap(Double.init) ?? 15)
        }
    }

    struct Report: Codable, Equatable {
        let pointsPerFrame: Double
        let seconds: Double
        let cpuSeconds: Double
        let frames: Int
        let hitches: Int
        let hitchMilliseconds: Double
    }

    private weak var scrollView: UIScrollView?
    private let config: Config
    private let onStart: () -> Void
    private var link: CADisplayLink?
    private var counter = HitchCounter()
    private var direction: CGFloat = -1
    private var startTimestamp: CFTimeInterval?
    private var startCPU: Double = 0

    init(scrollView: UIScrollView, config: Config, onStart: @escaping () -> Void) {
        self.scrollView = scrollView
        self.config = config
        self.onStart = onStart
    }

    func start() {
        onStart()
        startCPU = Self.cpuSeconds()
        try? Data().write(to: Self.url("timeline-perf.started"))
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        counter.frame(at: link.timestamp, duration: link.duration)
        if startTimestamp == nil { startTimestamp = link.timestamp }
        guard let scrollView else { return finish(elapsed: 0) }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        var y = scrollView.contentOffset.y + direction * config.pointsPerFrame
        if y <= 0 {
            y = 0
            direction = 1
        } else if y >= maxY {
            y = maxY
            direction = -1
        }
        scrollView.contentOffset = CGPoint(x: 0, y: y)
        let elapsed = link.timestamp - (startTimestamp ?? link.timestamp)
        if elapsed >= config.duration { finish(elapsed: elapsed) }
    }

    private func finish(elapsed: CFTimeInterval) {
        link?.invalidate()
        link = nil
        let report = Report(pointsPerFrame: Double(config.pointsPerFrame), seconds: elapsed,
                            cpuSeconds: Self.cpuSeconds() - startCPU, frames: counter.frames,
                            hitches: counter.hitches, hitchMilliseconds: counter.hitchSeconds * 1000)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: Self.url("timeline-perf.json")) }
        timelineLogger.breadcrumb("perf probe done \(report)")
        if Self.baselineProbe === self { Self.baselineProbe = nil }
    }

    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    // MARK: SwiftUI baseline (flag off)

    private static var baselineProbe: TimelinePerfProbe?

    /// The same probe against the SwiftUI timeline (`chat.timeline.uikit`
    /// off), for the gate's baseline column. SwiftUI owns no controller hook,
    /// so this drives the UIScrollView with the tallest content in the key
    /// window — the open chat's timeline.
    static func startOnSwiftUITimeline(config: Config) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, !view.isHidden, view.window != nil,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        windows.filter(\.isKeyWindow).forEach(visit)
        guard let best else {
            timelineLogger.breadcrumb("perf probe: no scroll view for the SwiftUI baseline")
            return
        }
        let probe = TimelinePerfProbe(scrollView: best, config: config) {}
        baselineProbe = probe
        probe.start()
    }
}
#endif
