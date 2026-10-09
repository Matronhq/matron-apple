#if os(macOS) && DEBUG
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// An image arriving must not rebuild the thread. A thread's images land
/// one at a time, each a fetch, long after the thread is on screen; when
/// each one re-ran `ItemDetailView`'s body, every comment row was built
/// again per image, and a reader scrolling a thread of thirty screenshots
/// while they loaded felt each as a stutter. The image is read where it is
/// drawn, so a host that keeps its images in an `ItemImageStore` re-runs
/// only the image views.
@MainActor
final class ItemDetailImageIsolationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Harness: View {
        let model: ItemDetailView.Model
        let images: ItemImageStore
        var body: some View {
            ItemDetailView(model: model, draft: .constant(""),
                           image: { images[$0.blobRef] }, onOpenAttachment: { _ in }, onOpenLink: { _ in },
                           onOpenConversation: { _ in }, onSubmit: {}, onAttach: {}, onVoiceNote: {},
                           onClose: { _ in }, onReopen: {}, now: Date(timeIntervalSince1970: 1_770_010_000))
                .frame(width: 560, height: 800)
        }
    }

    private func model(comments count: Int) -> ItemDetailView.Model {
        let item = TrackerItem(id: "it_images", num: 1, kind: .task, title: "Screenshots", body: "The item body.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        let comments = (0..<count).map { i in
            TrackerComment(id: "c\(i)", itemID: "it_images", author: .agent,
                           body: "Comment \(i), its picture inline:\n\n![shot](attachment:b\(i))\n\nand some text after.",
                           attachments: [TrackerAttachment(blobRef: "b\(i)", mime: "image/png", name: "shot.png",
                                                           size: 1000, width: 400, height: 200)],
                           createdAt: t0.addingTimeInterval(Double(i + 1) * 60))
        }
        return .init(item: item, comments: comments, pending: [], availableResolutions: [.done],
                     isBusy: false, loadedCommentCount: comments.count)
    }

    private func spin(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func picture(_ color: NSColor) -> Image {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        image.unlockFocus()
        return Image(nsImage: image)
    }

    private func mount(_ harness: Harness) -> (NSWindow, NSHostingView<Harness>) {
        let host = NSHostingView(rootView: harness)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        spin(0.5)
        return (window, host)
    }

    func test_anImageArriving_buildsNoCommentRow() {
        let images = ItemImageStore()
        let (window, _) = mount(Harness(model: model(comments: 20), images: images))
        defer { window.close() }
        XCTAssertGreaterThan(ItemDetailViewProbe.commentRowBuilds, 0, "the thread's rows were built at open")

        ItemDetailViewProbe.commentRowBuilds = 0
        for i in 0..<20 {
            images["b\(i)"] = picture(.systemRed)
            spin(0.02)
        }
        spin()
        XCTAssertEqual(ItemDetailViewProbe.commentRowBuilds, 0, "an image arriving rebuilt the thread")
    }

    /// The image still reaches the screen: the first card's placeholder
    /// turns into the picture.
    func test_anImageArriving_isDrawn() throws {
        let images = ItemImageStore()
        let (window, host) = mount(Harness(model: model(comments: 1), images: images))
        defer { window.close() }
        func redPixels() throws -> Int {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.redComponent > 0.7, c.greenComponent < 0.4, c.blueComponent < 0.4 { count += 1 }
                }
            }
            return count
        }
        XCTAssertEqual(try redPixels(), 0)
        images["b0"] = picture(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        spin(0.3)
        XCTAssertGreaterThan(try redPixels(), 100, "the loaded image never replaced its placeholder")
    }
}
#endif
