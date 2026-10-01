#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

/// Mission 6040 profiling harness: hosts the tracker item thread exactly as
/// the Mac items pane does (the detail beside a chat column in an
/// `HSplitView`) and times opening it, a keystroke in the reply, and the
/// thread's images arriving one by one. Skipped unless
/// `ITEM_PERF_FIXTURE` names a thread exported from a local store
/// (`{item, comments}` as the store rows); with `ITEM_PERF_SYNTHETIC=1` it
/// runs on a generated thread instead.
@MainActor
final class ItemThreadPerfHarness: XCTestCase {
    @Observable final class Harness {
        var model: ItemDetailView.Model
        var images: [String: Image] = [:]
        var draft = ""
        init(model: ItemDetailView.Model) { self.model = model }
    }

    /// `nav` (default): the Decisions surface, the detail column of a
    /// `NavigationSplitView`. `split`: the chat's items pane, an
    /// `HSplitView` side pane with the app's fixed split-pane frame.
    static var hostKind: String { ProcessInfo.processInfo.environment["ITEM_PERF_HOST"] ?? "nav" }

    struct Host: View {
        let harness: Harness
        var detail: some View {
            ItemDetailView(model: harness.model,
                           draft: Binding(get: { harness.draft }, set: { harness.draft = $0 }),
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
        let harness = Harness(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }

        SelectableMessageTextProbe.measurements = 0
        SelectableMessageTextProbe.widthlessMeasurements = 0
        let open = Self.time {
            window.contentViewController = NSHostingController(rootView: Host(harness: harness))
            window.setContentSize(NSSize(width: 1100, height: 800))
            window.orderFront(nil)
            Self.settle(window)
        }
        let openMeasures = SelectableMessageTextProbe.measurements
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
            ITEMPERF open=%.0fms measures=%d widthless=%d
            ITEMPERF keystroke median=%.1fms max=%.1fms measures/key=%d
            ITEMPERF images total=%.0fms per=%.1fms measures/image=%d
            """, model.comments.count, refs.count, open * 1000, openMeasures,
                            SelectableMessageTextProbe.widthlessMeasurements,
                            Self.median(keys) * 1000, (keys.max() ?? 0) * 1000, keyMeasures / max(keys.count, 1),
                            imageTimes.reduce(0, +) * 1000, Self.median(imageTimes) * 1000,
                            imageMeasures / max(refs.count, 1))
        print(report)
        try? report.write(toFile: env["ITEM_PERF_OUT"] ?? "/tmp/itemperf/last.txt", atomically: true, encoding: .utf8)
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

    static func picture() -> NSImage {
        let image = NSImage(size: NSSize(width: 1600, height: 1000))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
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
        return .init(item: parsed, comments: comments, pending: [], originTitle: nil,
                     availableResolutions: [.done], isBusy: false, loadedCommentCount: comments.count)
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
        return .init(item: item, comments: list, pending: [], originTitle: nil, availableResolutions: [.done],
                     isBusy: false, loadedCommentCount: list.count)
    }
}
#endif
