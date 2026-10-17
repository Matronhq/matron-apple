import SwiftUI
import XCTest
import MarkdownUI
@testable import MatronDesignSystem

/// Images written into markdown text are never fetched when the text is
/// shown: `MarkdownText` installs placeholder providers in place of
/// MarkdownUI's network loaders.
@MainActor
final class MarkdownImagePolicyTests: XCTestCase {

    func test_markdownText_installsThePlaceholderProviders_notTheNetworkLoaders() {
        // The seam `MarkdownText.body` reads its providers from.
        XCTAssertTrue(type(of: MarkdownImagePolicy.blockImageProvider) == PlaceholderImageProvider.self)
        XCTAssertTrue(type(of: MarkdownImagePolicy.inlineImageProvider) == PlaceholderInlineImageProvider.self)
        XCTAssertFalse((MarkdownImagePolicy.blockImageProvider as Any) is DefaultImageProvider)
        XCTAssertFalse((MarkdownImagePolicy.inlineImageProvider as Any) is DefaultInlineImageProvider)
    }

    func test_inlineProvider_returnsAGlyphForAnyURL_withoutLoading() async throws {
        for string in ["https://example.com/cat.png", "http://example.com/a.gif", "file:///tmp/a.png"] {
            let url = try XCTUnwrap(URL(string: string))
            // Returns at once: nothing is requested, so nothing can fail.
            _ = try await MarkdownImagePolicy.inlineImageProvider.image(with: url, label: "alt")
        }
    }

    func test_onlyWebLinksOpenOnTap() {
        let opens = ["https://example.com/cat.png", "HTTP://example.com/a.png"]
        let stays = ["file:///tmp/a.png", "mxc://example.com/abc", "attachment:blob-1", "data:image/png;base64,AA=="]
        for string in opens {
            XCTAssertTrue(MarkdownImagePolicy.opensOnTap(URL(string: string)), string)
        }
        for string in stays {
            XCTAssertFalse(MarkdownImagePolicy.opensOnTap(URL(string: string)), string)
        }
        XCTAssertFalse(MarkdownImagePolicy.opensOnTap(nil))
    }

    func test_caption_namesWhereAWebImagePoints() {
        XCTAssertEqual(MarkdownImagePolicy.caption(for: URL(string: "https://example.com/pics/cat.png")),
                       "Image · example.com/cat.png")
        XCTAssertEqual(MarkdownImagePolicy.caption(for: URL(string: "https://example.com")), "Image · example.com")
        XCTAssertEqual(MarkdownImagePolicy.caption(for: URL(string: "https://example.com/")), "Image · example.com")
        XCTAssertEqual(MarkdownImagePolicy.caption(for: URL(string: "file:///tmp/a.png")), "Image")
        XCTAssertEqual(MarkdownImagePolicy.caption(for: nil), "Image")
    }

    #if os(macOS)
    /// End to end: an image on its own line draws the placeholder chip at
    /// once. MarkdownUI's network loader draws nothing until a download
    /// finishes, so ink here means the placeholder provider is in effect.
    func test_markdownText_drawsAPlaceholderForAnImageAtOnce() {
        XCTAssertGreaterThan(inkHeight(MarkdownText("![a cat](https://example.com/cat.png)")), 8)
    }

    /// The Mac timeline and item thread render through `MarkdownAttributed`
    /// (an NSTextView), which keeps an image as its alt text and never
    /// attaches an image to load.
    func test_macRenderer_keepsTheAltText_andAttachesNoImage() {
        let attributed = MarkdownAttributed.attributedString(for: "Look: ![a cat](https://example.com/cat.png)")
        XCTAssertTrue(attributed.string.contains("a cat"), attributed.string)
        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0)
    }

    /// Height of the rendered non-white ink, in pixels.
    private func inkHeight<V: View>(_ view: V) -> Int {
        let host = NSHostingView(rootView: view.frame(width: 400, height: 80, alignment: .topLeading).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.9 {
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
        return maxY >= 0 ? maxY - minY + 1 : 0
    }
    #endif
}
