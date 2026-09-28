#if DEBUG
import AppKit
import Darwin
import QuartzCore
import os
import MatronViewModels

/// Perf rig for the Mac chat timeline, DEBUG builds only (the rig builds
/// Release with `-DDEBUG`, see the timeline spec). Armed by
/// `MATRON_PERF_CMD_FILE=<path>`: the probe polls that file, runs the
/// command in it, deletes it, and appends one JSON line per result to
/// `MATRON_PERF_OUT` (default `/tmp/matron-mac-perf.jsonl`).
///
/// Commands (one per file):
/// - `open <convoID>` — select the conversation; reports the time until the
///   first frame after its rows were handed to the timeline, and the hitch
///   time in the 3 s after the selection.
/// - `scroll <pt/frame> <steps>` — synthetic trackpad scroll (phased
///   scroll-wheel events sent straight to the timeline's scroll view, never
///   posted to the system) bouncing between the ends.
/// - `stream <deltas> <hz>` — grows a streaming `eph:` reply in the open
///   chat through the view model's real snapshot path.
/// - `idle <seconds>` — the instrument's noise floor.
/// - `float [off]` — keep the rig window un-occluded but invisible.
/// - `snap <path>` — PNG of the window.
/// - `bottom` — jump to the bottom and re-arm follow-tail.
///
/// Every result carries CPU seconds (getrusage), display-link hitches and
/// the physical footprint, so the SwiftUI and AppKit timelines are measured
/// by one instrument.
@MainActor
final class MacTimelinePerfProbe: NSObject {
    static let shared = MacTimelinePerfProbe()

    /// Set by whichever timeline is on screen for the main chat.
    var scrollViewProvider: (() -> NSScrollView?)?
    weak var viewModel: ChatViewModel?
    private var scrollView: NSScrollView? { scrollViewProvider?() }
    var jumpToBottom: (() -> Void)?

    private var commandURL: URL?
    private var outURL = URL(fileURLWithPath: "/tmp/matron-mac-perf.jsonl")
    private var pollTimer: Timer?
    private var link: CADisplayLink?
    private var tick: ((CADisplayLink) -> Void)?
    private var busy = false
    private static let logger = Logger(subsystem: "chat.matron", category: "perf-probe")

    // Open measurement state.
    private var openTarget: String?
    private var openStart: CFTimeInterval = 0
    private var rowsPresentedAt: CFTimeInterval?

    func armIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MATRON_PERF_CMD_FILE"] else { return }
        commandURL = URL(fileURLWithPath: path)
        if let out = env["MATRON_PERF_OUT"] { outURL = URL(fileURLWithPath: out) }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Self.logger.notice("perf probe armed cmd=\(path, privacy: .public)")
    }

    /// Called by the timeline once it has been handed a room's rows.
    func noteRowsPresented(roomID: String, count: Int) {
        guard let openTarget, openTarget == roomID, count > 0, rowsPresentedAt == nil else { return }
        rowsPresentedAt = CACurrentMediaTime()
    }

    private func poll() {
        guard !busy, let commandURL, let raw = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = parts.first else { return }
        Self.logger.notice("perf command \(raw, privacy: .public)")
        switch verb {
        case "open" where parts.count >= 2: runOpen(parts[1])
        case "scroll" where parts.count >= 3:
            runScroll(points: CGFloat(Double(parts[1]) ?? 25), steps: Int(parts[2]) ?? 900)
        case "stream" where parts.count >= 3:
            runStream(deltas: Int(parts[1]) ?? 200, hz: Double(parts[2]) ?? 10)
        case "snap":
            let path = parts.count >= 2 ? parts[1] : "/tmp/matron-mac-perf.png"
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            write(["cmd": "snap", "path": path])
        case "float":
            // Keeps the rig window un-occluded (so its display link runs at
            // the display rate) while staying invisible and click-through on
            // a Mac someone is using: floating level, 2% opacity, no mouse.
            let on = parts.count < 2 || parts[1] != "off"
            for window in NSApp.windows where window.isVisible && window.contentView != nil {
                window.level = on ? .floating : .normal
                window.alphaValue = on ? 0.02 : 1
                window.ignoresMouseEvents = on
            }
            write(["cmd": "float", "on": on])
        case "idle" where parts.count >= 2:
            runIdle(seconds: Double(parts[1]) ?? 5)
        case "bottom":
            jumpToBottom?()
            write(["cmd": "bottom"])
        default:
            write(["cmd": verb, "error": "unknown"])
        }
    }

    // MARK: Commands

    private func runOpen(_ convoID: String) {
        openTarget = convoID
        rowsPresentedAt = nil
        let cpu0 = Self.cpuSeconds()
        var counter = HitchCounter()
        var firstFrameAfterRows: CFTimeInterval?
        openStart = CACurrentMediaTime()
        NotificationCenter.default.post(name: .matronPerfOpenConversation, object: convoID)
        runLink { [self] link in
            counter.frame(at: link.timestamp, duration: link.duration)
            if firstFrameAfterRows == nil, let presented = rowsPresentedAt, link.timestamp > presented {
                firstFrameAfterRows = link.timestamp
            }
            guard link.timestamp - openStart >= 5 else { return false }
            write([
                "cmd": "open", "convo": convoID,
                "rowsReadyMs": rowsPresentedAt.map { Int(($0 - openStart) * 1000) } ?? -1,
                "firstFrameMs": firstFrameAfterRows.map { Int(($0 - openStart) * 1000) } ?? -1,
                "cpuS": Self.round(Self.cpuSeconds() - cpu0),
                "hitches": counter.hitches, "hitchMs": Int(counter.hitchSeconds * 1000),
                "maxGapMs": Int(counter.maxGap * 1000),
                "rows": viewModel?.windowedRows.count ?? -1,
                "footprintMB": Self.footprintMB(),
                "load": Self.loadAverage(),
            ])
            openTarget = nil
            return true
        }
    }

    /// The instrument's noise floor: nothing driven, just frames counted.
    private func runIdle(seconds: Double) {
        let cpu0 = Self.cpuSeconds()
        var counter = HitchCounter()
        var start: CFTimeInterval?
        runLink { [self] link in
            if start == nil { start = link.timestamp }
            counter.frame(at: link.timestamp, duration: link.duration)
            guard link.timestamp - (start ?? link.timestamp) >= seconds else { return false }
            write([
                "cmd": "idle", "seconds": seconds, "cpuS": Self.round(Self.cpuSeconds() - cpu0),
                "frames": counter.frames, "hitches": counter.hitches,
                "hitchMs": Int(counter.hitchSeconds * 1000), "maxGapMs": Int(counter.maxGap * 1000),
                "frameMs": Self.round(link.duration * 1000),
            ])
            return true
        }
    }

    /// A fixed workload — `steps` scroll events of `points` each, one per
    /// frame — so a slower timeline does the SAME work and CPU seconds
    /// compare directly (a fixed duration let a starved run scroll less).
    private func runScroll(points: CGFloat, steps: Int) {
        guard let scrollView else { write(["cmd": "scroll", "error": "no scroll view"]); return }
        let cpu0 = Self.cpuSeconds()
        var counter = HitchCounter()
        var start: CFTimeInterval?
        // Positive wheel delta = toward older history (content moves down).
        var direction: CGFloat = 1
        var lastY = scrollView.contentView.bounds.origin.y
        var stuckFrames = 0
        var reversals = 0
        var sent = 0
        var travelled: CGFloat = 0
        sendScroll(to: scrollView, delta: 0, phase: .began)
        runLink { [self] link in
            if start == nil { start = link.timestamp }
            counter.frame(at: link.timestamp, duration: link.duration)
            sendScroll(to: scrollView, delta: points * direction, phase: .changed)
            sent += 1
            let y = scrollView.contentView.bounds.origin.y
            travelled += abs(y - lastY)
            if abs(y - lastY) < 0.5 { stuckFrames += 1 } else { stuckFrames = 0 }
            lastY = y
            // Parked at an end for 30 frames (the top waits for the history
            // window to extend first): turn round.
            if stuckFrames > 30 { direction = -direction; stuckFrames = 0; reversals += 1 }
            guard sent >= steps else { return false }
            sendScroll(to: scrollView, delta: 0, phase: .ended)
            write([
                "cmd": "scroll", "ptPerFrame": Double(points), "steps": steps,
                "wallS": Self.round(link.timestamp - (start ?? link.timestamp)),
                "cpuS": Self.round(Self.cpuSeconds() - cpu0),
                "frames": counter.frames, "hitches": counter.hitches,
                "hitchMs": Int(counter.hitchSeconds * 1000), "maxGapMs": Int(counter.maxGap * 1000),
                "reversals": reversals, "travelledPt": Int(travelled),
                "rows": viewModel?.windowedRows.count ?? -1,
                "footprintMB": Self.footprintMB(),
                "load": Self.loadAverage(),
            ])
            return true
        }
    }

    /// A fixed workload: `deltas` growing snapshots, `hz` per second.
    private func runStream(deltas total: Int, hz: Double) {
        guard let viewModel else { write(["cmd": "stream", "error": "no view model"]); return }
        let reply = Self.streamingReply
        let cpu0 = Self.cpuSeconds()
        var counter = HitchCounter()
        var start: CFTimeInterval?
        var lastDelta: CFTimeInterval = 0
        var deltas = 0
        let ref = "perf-\(Int(Date().timeIntervalSince1970))"
        runLink { [self] link in
            if start == nil { start = link.timestamp }
            counter.frame(at: link.timestamp, duration: link.duration)
            if deltas < total, link.timestamp - lastDelta >= 1 / hz {
                lastDelta = link.timestamp
                deltas += 1
                let chars = reply.count * deltas / total
                viewModel.debugReceiveStreamingText(String(reply.prefix(chars)), messageRef: ref)
            }
            // Half a second past the last delta so its commit is counted.
            guard deltas >= total, link.timestamp - lastDelta >= 0.5 else { return false }
            viewModel.debugEndStreaming(messageRef: ref)
            write([
                "cmd": "stream", "deltas": deltas, "hz": hz,
                "wallS": Self.round(link.timestamp - (start ?? link.timestamp)),
                "cpuS": Self.round(Self.cpuSeconds() - cpu0),
                "frames": counter.frames, "hitches": counter.hitches,
                "hitchMs": Int(counter.hitchSeconds * 1000), "maxGapMs": Int(counter.maxGap * 1000),
                "footprintMB": Self.footprintMB(),
                "load": Self.loadAverage(),
            ])
            return true
        }
    }

    // MARK: Plumbing

    /// Drives `body` from a display link until it returns `true`.
    private func runLink(_ body: @escaping (CADisplayLink) -> Bool) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView else {
            write(["error": "no window"])
            return
        }
        busy = true
        let link = view.displayLink(target: self, selector: #selector(linkFired(_:)))
        tick = { [weak self] link in
            guard let self else { return }
            if body(link) {
                self.link?.invalidate()
                self.link = nil
                self.tick = nil
                self.busy = false
            }
        }
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func linkFired(_ link: CADisplayLink) { tick?(link) }

    private func sendScroll(to scrollView: NSScrollView, delta: CGFloat, phase: CGScrollPhase) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(delta))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
        if let window = scrollView.window {
            let mid = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: mid)
            let height = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screen.x, y: height - screen.y)
        }
        guard let event = NSEvent(cgEvent: cg) else { return }
        scrollView.scrollWheel(with: event)
    }

    private func write(_ fields: [String: Any]) {
        var fields = fields
        fields["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        Self.logger.notice("perf result \(line, privacy: .public)")
        if let handle = try? FileHandle(forWritingTo: outURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: outURL)
        }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func loadAverage() -> Double {
        var load = [Double](repeating: 0, count: 1)
        getloadavg(&load, 1)
        return (load[0] * 10).rounded() / 10
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// A long, realistic agent reply: prose, a list, links and two code
    /// blocks — the shapes that cost the most to lay out.
    static let streamingReply: String = {
        var parts: [String] = []
        for section in 1...6 {
            parts.append("## Step \(section): what changed\n")
            parts.append("The timeline now measures each row once and caches the height, so a streaming reply only re-lays out **its own row**. See [the spec](https://example.com/spec/\(section)) and `TimelineScrollModel` for the anchor maths, plus matron://item/\(4100 + section) for the tracker thread.\n")
            parts.append("- First, the row content is rebuilt from the view model.\n- Second, only rows whose content changed are re-measured.\n- Third, the table keeps the bottom pinned while following.\n")
            parts.append("```swift\nfunc apply(_ rows: [Row]) {\n    let changed = diff(old: current, new: rows)\n    for index in changed { table.noteHeightOfRows(withIndexesChanged: [index]) }\n    if isFollowingTail { scrollToBottom() }\n}\n```\n")
            parts.append("That keeps the main thread free while the agent is typing, which is the case Dan noticed most.\n")
        }
        return parts.joined(separator: "\n")
    }()
}

/// Frame pacing: a frame more than 1.5 frame-durations after the previous
/// one is a hitch; the time it was late is hitch time. Same rule as the iOS
/// perf gate's `HitchCounter`.
struct HitchCounter {
    private(set) var frames = 0
    private(set) var hitches = 0
    private(set) var hitchSeconds: Double = 0
    private(set) var maxGap: Double = 0
    private var last: CFTimeInterval?

    mutating func frame(at timestamp: CFTimeInterval, duration: CFTimeInterval) {
        defer { last = timestamp }
        guard let last else { return }
        frames += 1
        let interval = timestamp - last
        maxGap = max(maxGap, interval)
        let frame = duration > 0 ? duration : 1.0 / 60
        if interval > frame * 1.5 {
            hitches += 1
            hitchSeconds += interval - frame
        }
    }
}

extension Notification.Name {
    static let matronPerfOpenConversation = Notification.Name("chat.matron.perf.openConversation")
}
#endif
