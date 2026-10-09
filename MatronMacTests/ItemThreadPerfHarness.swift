#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

/// Profiling harness: hosts the tracker item thread exactly as
/// the Mac items pane does (the detail beside a chat column in an
/// `HSplitView`) and times opening it, a keystroke in the reply, and the
/// thread's images arriving one by one. Skipped unless
/// `ITEM_PERF_FIXTURE` names a thread exported from a local store
/// (`{item, comments}` as the store rows); with `ITEM_PERF_SYNTHETIC=1` it
/// runs on a generated thread instead.
@MainActor
final class ItemThreadPerfHarness: XCTestCase {
    @Observable final class Harness {
        var model: ItemDetailView.Model?
        var images: [String: Image] = [:]
        var draft = ""
        init(model: ItemDetailView.Model?) { self.model = model }
    }

    /// `nav` (default): the Decisions surface, the detail column of a
    /// `NavigationSplitView`. `split`: the chat's items pane, an
    /// `HSplitView` side pane with the app's fixed split-pane frame.
    static var hostKind: String { ProcessInfo.processInfo.environment["ITEM_PERF_HOST"] ?? "nav" }

    struct Host: View {
        let harness: Harness
        @ViewBuilder var detail: some View {
            if let model = harness.model { thread(model) } else { Color.clear }
        }
        func thread(_ model: ItemDetailView.Model) -> some View {
            ItemDetailView(model: model,
                           draft: ItemReplyDraft(get: { harness.draft }, set: { harness.draft = $0 }),
                           image: { harness.images[$0.blobRef] },
                           onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                           onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
        }
        var body: some View {
            if ItemThreadPerfHarness.hostKind == "split" {
                GeometryReader { geo in
                    HSplitView {
                        Color.gray.frame(minWidth: 300, idealWidth: 500, maxWidth: .infinity,
                                         minHeight: geo.size.height, idealHeight: geo.size.height, maxHeight: geo.size.height)
                        detail.frame(minWidth: 420, idealWidth: 420, maxWidth: .infinity,
                                     minHeight: geo.size.height, idealHeight: geo.size.height, maxHeight: geo.size.height,
                                     alignment: .top)
                    }
                }
            } else {
                NavigationSplitView {
                    List(0..<20, id: \.self) { Text("Row \($0)") }
                } detail: {
                    detail
                }
            }
        }
    }

    func test_profileThread() throws {
        let env = ProcessInfo.processInfo.environment
        let model: ItemDetailView.Model
        if let path = env["ITEM_PERF_FIXTURE"] {
            model = try Self.load(URL(fileURLWithPath: path))
        } else if env["ITEM_PERF_SYNTHETIC"] == "1" {
            model = Self.synthetic(comments: 100, images: 30)
        } else {
            throw XCTSkip("set ITEM_PERF_FIXTURE or ITEM_PERF_SYNTHETIC")
        }
        if let repeats = env["ITEM_PERF_OPEN_LOOP"].flatMap(Int.init) {
            // Profiling mode: a pause to attach `sample`, then repeated opens.
            Self.spin(4)
            for _ in 0..<repeats {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                w.contentViewController = NSHostingController(rootView: Host(harness: Harness(model: model)))
                w.orderFront(nil)
                Self.settle(w)
                w.orderOut(nil)
            }
            return
        }
        // Repeat opens in fresh windows: the first is cold (markdown parsed
        // and measured), the rest warm; report both, the warm as a median.
        var warmOpens: [Double] = []
        var swapWidths: [Int: Int] = [:]
        for _ in 0..<(env["ITEM_PERF_REPEAT"].flatMap(Int.init) ?? 0) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            // As the app opens an item: the window and its split view are
            // already up, and the thread arrives in the detail.
            let h = Harness(model: nil)
            w.contentViewController = NSHostingController(rootView: Host(harness: h))
            w.setContentSize(NSSize(width: 1100, height: 800))
            w.orderFront(nil)
            Self.settle(w)
            SelectableMessageTextProbe.deferredWidths = []
            warmOpens.append(Self.time {
                h.model = model
                Self.settle(w)
            })
            swapWidths = Dictionary(SelectableMessageTextProbe.deferredWidths.map { ($0, 1) }, uniquingKeysWith: +)
            w.orderOut(nil)
            Self.spin(0.2)
        }
        let harness = Harness(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }

        SelectableMessageTextProbe.measurements = 0
        SelectableMessageTextProbe.widthlessMeasurements = 0
        SelectableMessageTextProbe.deferredWidths = []
        let open = Self.time {
            window.contentViewController = NSHostingController(rootView: Host(harness: harness))
            window.setContentSize(NSSize(width: 1100, height: 800))
            window.orderFront(nil)
            Self.settle(window)
        }
        let openMeasures = SelectableMessageTextProbe.measurements
        let openWidths = Dictionary(SelectableMessageTextProbe.deferredWidths.map { ($0, 1) }, uniquingKeysWith: +)
        Self.spin(1)

        SelectableMessageTextProbe.measurements = 0
        var keys: [Double] = []
        for ch in "Hello there" {
            keys.append(Self.time { harness.draft.append(ch); Self.settle(window) })
        }
        let keyMeasures = SelectableMessageTextProbe.measurements

        let refs = (model.item.attachments + model.comments.flatMap(\.attachments)).filter(\.isImage).map(\.blobRef)
        let picture = Image(nsImage: Self.picture())
        SelectableMessageTextProbe.measurements = 0
        var imageTimes: [Double] = []
        for ref in refs {
            imageTimes.append(Self.time { harness.images[ref] = picture; Self.settle(window) })
        }
        let imageMeasures = SelectableMessageTextProbe.measurements

        let report = String(format: """
            ITEMPERF comments=%d images=%d
            ITEMPERF open=%.0fms measures=%d widthless=%d warm-median=%.0fms deferred-widths=%@ swap-widths=%@
            ITEMPERF keystroke median=%.1fms max=%.1fms measures/key=%d
            ITEMPERF images total=%.0fms per=%.1fms measures/image=%d
            """, model.comments.count, refs.count, open * 1000, openMeasures,
                            SelectableMessageTextProbe.widthlessMeasurements, Self.median(warmOpens) * 1000,
                            openWidths.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ",") as NSString,
                            swapWidths.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ",") as NSString,
                            Self.median(keys) * 1000, (keys.max() ?? 0) * 1000, keyMeasures / max(keys.count, 1),
                            imageTimes.reduce(0, +) * 1000, Self.median(imageTimes) * 1000,
                            imageMeasures / max(refs.count, 1))
        print(report)
        try? report.write(toFile: env["ITEM_PERF_OUT"] ?? "/tmp/itemperf/last.txt", atomically: true, encoding: .utf8)
    }

    /// Scrolls the thread end to end, a fixed step a frame, and reports the
    /// frames that ran late. `ITEM_PERF_PASSES` (default 2) round trips.
    func test_profileScroll() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ITEM_PERF_FIXTURE"] else { throw XCTSkip("set ITEM_PERF_FIXTURE") }
        let model = try Self.load(URL(fileURLWithPath: path))
        let harness = Harness(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentViewController = NSHostingController(rootView: Host(harness: harness))
        window.setContentSize(NSSize(width: 1100, height: 800))
        window.orderFront(nil)
        Self.settle(window)
        // A screenshot's size, each its own bitmap as real ones are.
        for ref in (model.item.attachments + model.comments.flatMap(\.attachments)).filter(\.isImage).map(\.blobRef) {
            harness.images[ref] = Image(nsImage: Self.picture(NSSize(width: 1920, height: 1080)))
        }
        Self.spin(1)
        let scroll = try XCTUnwrap(Self.tallestScrollView(in: window.contentView))
        let step: CGFloat = 30
        var frames: [Double] = []
        var cpu = Self.cpuSeconds()
        for _ in 0..<(env["ITEM_PERF_PASSES"].flatMap(Int.init) ?? 2) {
            for down in [true, false] {
                while true {
                    let clip = scroll.contentView
                    let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                    let y = clip.bounds.origin.y
                    let next = min(max(y + (down ? step : -step), 0), limit)
                    if abs(next - y) < 0.5 { break }
                    frames.append(Self.time {
                        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
                        scroll.reflectScrolledClipView(clip)
                        Self.settle(window)
                    })
                }
            }
        }
        cpu = Self.cpuSeconds() - cpu
        let late = frames.filter { $0 > 1.0 / 60 * 1.5 }
        let report = String(format: "ITEMSCROLL height=%.0f frames=%d late=%d worst=%.0fms median=%.1fms cpu=%.1fs",
                            scroll.documentView?.frame.height ?? 0, frames.count, late.count,
                            (frames.max() ?? 0) * 1000, Self.median(frames) * 1000, cpu)
        print(report)
        try? report.write(toFile: env["ITEM_PERF_OUT"] ?? "/tmp/itemperf/scroll.txt", atomically: true, encoding: .utf8)
    }

    static func tallestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    // MARK: - Helpers

    static func time(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return CFAbsoluteTimeGetCurrent() - start
    }

    /// Lets SwiftUI apply pending updates, then forces layout and a draw.
    static func settle(_ window: NSWindow) {
        for _ in 0..<3 { RunLoop.main.run(until: Date()) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.sorted()[xs.count / 2]
    }

    static func picture(_ size: NSSize = NSSize(width: 1600, height: 1000)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2)).fill()
        image.unlockFocus()
        return image
    }

    static func load(_ url: URL) throws -> ItemDetailView.Model {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        func attachments(_ any: Any?) -> [[String: Any]] {
            (any as? [[String: Any]] ?? []).map { a in
                var a = a
                if a["blob_ref"] == nil { a["blob_ref"] = a["blobRef"] }
                return a
            }
        }
        var item = root["item"] as! [String: Any]
        item["attachments"] = attachments(item["attachments"])
        let comments = (root["comments"] as! [[String: Any]]).compactMap { c -> TrackerComment? in
            var c = c
            c["attachments"] = attachments(c["attachments"])
            return TrackerComment(json: c)
        }
        let parsed = TrackerItem(json: item)!
        return .init(item: parsed, comments: comments, pending: [], availableResolutions: [.done], isBusy: false, loadedCommentCount: comments.count)
    }

    static func synthetic(comments: Int, images: Int) -> ItemDetailView.Model {
        let body = """
            **Done.** The change is on the branch, and here's what moved:

            - The thread reads its attachments' sizes up front, so nothing shifts.
            - A queued reply says so, with a [Send now](https://example.com) button.
            - Item links like [#12](matron://item/12) still open in place.

            ```swift
            let x = thread.comments.count
            ```

            Next I'll run the tests and post the timings here.
            """
        let item = TrackerItem(id: "it_perf", num: 1, kind: .decision, title: "A long thread", body: body,
                               originConvoID: "c1")
        let list = (0..<comments).map { i in
            TrackerComment(id: "c\(i)", itemID: "it_perf", author: i % 3 == 0 ? .user : .agent, body: body,
                           attachments: i < images ? [TrackerAttachment(blobRef: "b\(i)", mime: "image/png",
                                                                        name: "shot.png", size: 1000)] : [],
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60))
        }
        return .init(item: item, comments: list, pending: [], availableResolutions: [.done],
                     isBusy: false, loadedCommentCount: list.count)
    }
}
#endif
