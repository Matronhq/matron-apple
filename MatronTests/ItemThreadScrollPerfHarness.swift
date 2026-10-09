import XCTest
import UIKit
import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
@testable import Matron

/// Profiling harness: hosts the tracker item thread as the iPhone app does
/// (an `ItemDetailView` whose images arrive through the host's cache) and
/// scrolls it end to end at a steady speed, counting hitches with the chat
/// timeline's `HitchCounter`. Skipped unless `ITEM_PERF_FIXTURE` names a
/// thread (`{item, comments}` as the store rows; an attachment's `path`
/// names its image file on disk); with `ITEM_PERF_SYNTHETIC=1` it runs on
/// a generated thread instead.
///
/// - `ITEM_PERF_SPEED`: points per frame (default 30).
/// - `ITEM_PERF_PASSES`: end-to-end passes (default 4: down, up, down, up).
/// - `ITEM_PERF_HOLD`: seconds to wait before scrolling, to attach a profiler.
/// - `ITEM_PERF_IMAGES=0` / `ITEM_PERF_TABLES=0`: leave the images
///   unloaded / drop table rows from the bodies, to attribute the cost.
/// - `ITEM_PERF_OUT`: where the report is written.
@MainActor
final class ItemThreadScrollPerfHarness: XCTestCase {
    @Observable final class Harness {
        let model: ItemDetailView.Model
        let images = ItemImageStore()
        var imageCount = 0
        var draft = ""
        init(model: ItemDetailView.Model) { self.model = model }
    }

    struct Host: View {
        let harness: Harness
        var body: some View {
            ItemDetailView(model: harness.model,
                           draft: ItemReplyDraft(get: { harness.draft }, set: { harness.draft = $0 }),
                           image: { harness.images[$0.blobRef] },
                           onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                           onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
        }
    }

    struct Pass {
        var counter = HitchCounter()
        var worst: CFTimeInterval = 0
        var seconds: CFTimeInterval = 0
    }

    func test_profileScroll() throws {
        let env = ProcessInfo.processInfo.environment
        let fixture: Fixture
        if let path = env["ITEM_PERF_FIXTURE"] {
            fixture = try Self.load(URL(fileURLWithPath: path), tables: env["ITEM_PERF_TABLES"] != "0")
        } else if env["ITEM_PERF_SYNTHETIC"] == "1" {
            fixture = Self.synthetic(comments: 60, images: 30)
        } else {
            throw XCTSkip("set ITEM_PERF_FIXTURE or ITEM_PERF_SYNTHETIC")
        }
        let speed = CGFloat(env["ITEM_PERF_SPEED"].flatMap(Double.init) ?? 30)
        let passCount = env["ITEM_PERF_PASSES"].flatMap(Int.init) ?? 4

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let harness = Harness(model: fixture.model)
        let window = UIWindow(windowScene: scene)
        let open = Self.time {
            window.rootViewController = UIHostingController(rootView: Host(harness: harness))
            window.isHidden = false
            window.layoutIfNeeded()
            Self.spin(0.3)
        }
        defer { window.isHidden = true }

        var imageLoad = 0.0
        if env["ITEM_PERF_IMAGES"] != "0" {
            imageLoad = Self.time {
                for (ref, data) in fixture.imageData {
                    harness.images[ref] = Self.decode(data)
                    harness.imageCount += 1
                    Self.spin(0.01)
                }
            }
        }
        Self.spin(env["ITEM_PERF_HOLD"].flatMap(Double.init) ?? 1)

        let scrollView = try XCTUnwrap(Self.threadScrollView(in: window))
        let startCPU = TimelinePerfProbe.cpuSeconds()
        var passes: [Pass] = []
        for index in 0..<passCount {
            passes.append(Self.scroll(scrollView, down: index % 2 == 0, pointsPerFrame: speed))
        }
        let cpu = TimelinePerfProbe.cpuSeconds() - startCPU

        var lines = [String(format: "ITEMSCROLL comments=%d images=%d height=%.0fpt speed=%.0fpt/frame open=%.0fms image-load=%.0fms cpu=%.2fs",
                            fixture.model.comments.count, harness.imageCount, scrollView.contentSize.height,
                            speed, open * 1000, imageLoad * 1000, cpu)]
        for (index, pass) in passes.enumerated() {
            lines.append(String(format: "ITEMSCROLL pass=%d %@ seconds=%.2f frames=%d hitches=%d hitch-ms=%.0f hitch-ms-per-s=%.1f worst-frame=%.0fms",
                                index + 1, index % 2 == 0 ? "down" : "up", pass.seconds, pass.counter.frames,
                                pass.counter.hitches, pass.counter.hitchSeconds * 1000,
                                pass.seconds > 0 ? pass.counter.hitchSeconds * 1000 / pass.seconds : 0, pass.worst * 1000))
        }
        let report = lines.joined(separator: "\n")
        print(report)
        try? report.write(toFile: env["ITEM_PERF_OUT"] ?? NSTemporaryDirectory() + "item-scroll-perf.txt",
                          atomically: true, encoding: .utf8)
    }

    // MARK: - Scrolling

    /// One end-to-end pass, a fixed distance every display frame.
    static func scroll(_ scrollView: UIScrollView, down: Bool, pointsPerFrame: CGFloat) -> Pass {
        let driver = Driver(scrollView: scrollView, down: down, pointsPerFrame: pointsPerFrame)
        let link = CADisplayLink(target: driver, selector: #selector(Driver.tick(_:)))
        link.add(to: .main, forMode: .common)
        while !driver.done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        link.invalidate()
        return driver.pass
    }

    final class Driver: NSObject {
        let scrollView: UIScrollView
        let down: Bool
        let pointsPerFrame: CGFloat
        var pass = Pass()
        var done = false
        private var first: CFTimeInterval?
        private var last: CFTimeInterval?

        init(scrollView: UIScrollView, down: Bool, pointsPerFrame: CGFloat) {
            self.scrollView = scrollView; self.down = down; self.pointsPerFrame = pointsPerFrame
        }

        @objc func tick(_ link: CADisplayLink) {
            guard !done else { return }
            pass.counter.frame(at: link.timestamp, duration: link.duration)
            if let last { pass.worst = max(pass.worst, link.timestamp - last) }
            last = link.timestamp
            if first == nil { first = link.timestamp }
            pass.seconds = link.timestamp - (first ?? link.timestamp)
            let top = -scrollView.adjustedContentInset.top
            let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let y = scrollView.contentOffset.y + (down ? pointsPerFrame : -pointsPerFrame)
            if (down && y >= bottom) || (!down && y <= top) {
                scrollView.contentOffset.y = down ? bottom : top
                done = true
            } else {
                scrollView.contentOffset.y = y
            }
        }
    }

    /// The thread's own vertical scroll view: the tallest one, so a table's
    /// sideways scroller is never picked.
    static func threadScrollView(in view: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }

    // MARK: - Helpers

    static func time(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return CACurrentMediaTime() - start
    }

    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The image as the app's item host makes it.
    static func decode(_ data: Data) -> Image? {
        SizedImage.decodeThumbnail(data, maxPixel: ItemDetailHost.threadImageMaxPixel)?.image
    }

    struct Fixture {
        var model: ItemDetailView.Model
        var imageData: [(ref: String, data: Data)]
    }

    static func load(_ url: URL, tables: Bool) throws -> Fixture {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var imageData: [(ref: String, data: Data)] = []
        func attachments(_ any: Any?) -> [[String: Any]] {
            (any as? [[String: Any]] ?? []).map { a in
                if let ref = a["blob_ref"] as? String, let path = a["path"] as? String,
                   (a["mime"] as? String)?.hasPrefix("image/") == true,
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    imageData.append((ref, data))
                }
                return a
            }
        }
        var item = root["item"] as! [String: Any]
        item["attachments"] = attachments(item["attachments"])
        if !tables { item["body"] = withoutTables(item["body"]) }
        let comments = (root["comments"] as! [[String: Any]]).compactMap { c -> TrackerComment? in
            var c = c
            c["attachments"] = attachments(c["attachments"])
            if !tables { c["body"] = withoutTables(c["body"]) }
            return TrackerComment(json: c)
        }
        let parsed = TrackerItem(json: item)!
        return Fixture(model: .init(item: parsed, comments: comments, pending: [], availableResolutions: [.done],
                                    isBusy: false, loadedCommentCount: comments.count),
                       imageData: imageData)
    }

    static func withoutTables(_ body: Any?) -> String {
        (body as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("|") }.joined(separator: "\n")
    }

    static func synthetic(comments: Int, images: Int) -> Fixture {
        let body = """
            **Done.** The change is on the branch, and here's what moved:

            - The thread reads its attachments' sizes up front, so nothing shifts.
            - Item links like [#12](matron://item/12) still open in place.

            | Part | Before | After | Note |
            | :--- | ---: | ---: | :--- |
            | Open | 120 ms | 40 ms | measured on a long thread |
            | Scroll | 30 ms | 4 ms | per frame, worst case |
            | Reply | 21 ms | 2 ms | a keystroke |

            Next I'll run the tests and post the timings here.
            """
        let item = TrackerItem(id: "it_perf", num: 1, kind: .decision, title: "A long thread", body: body,
                               originConvoID: "c1")
        let picture = Self.picture()
        var imageData: [(ref: String, data: Data)] = []
        let list = (0..<comments).map { i -> TrackerComment in
            var attachments: [TrackerAttachment] = []
            if i < images {
                attachments = [TrackerAttachment(blobRef: "b\(i)", mime: "image/jpeg", name: "shot.jpeg",
                                                 size: Int64(picture.count), width: 3840, height: 2160)]
                imageData.append(("b\(i)", picture))
            }
            return TrackerComment(id: "c\(i)", itemID: "it_perf", author: i % 3 == 0 ? .user : .agent, body: body,
                                  attachments: attachments,
                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60))
        }
        return Fixture(model: .init(item: item, comments: list, pending: [], availableResolutions: [.done],
                                    isBusy: false, loadedCommentCount: list.count),
                       imageData: imageData)
    }

    /// A screenshot-sized JPEG with enough detail that decoding it costs
    /// what a real one does.
    static func picture() -> Data {
        let size = CGSize(width: 3840, height: 2160)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for row in 0..<54 {
                for column in 0..<96 {
                    UIColor(hue: CGFloat((row * 7 + column * 13) % 100) / 100, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: column * 40 + 4, y: row * 40 + 4, width: 32, height: 32))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
