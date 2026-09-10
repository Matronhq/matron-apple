#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// The Mac timeline's link-click seam (`SelectableMessageText`'s NSTextView
/// coordinator). Item #115: `matron://item/N` must reach the in-app tracker
/// handler and NEVER `NSWorkspace` — the scheme isn't registered, so the OS
/// would answer with a "no application" sheet.
@MainActor
final class MessageLinkClickTests: XCTestCase {

    private func makeCoordinator() -> (SelectableTextViewRepresentable.Coordinator, () -> [URL], () -> [Int]) {
        let coordinator = SelectableTextViewRepresentable.Coordinator()
        let externals = Box<[URL]>([])
        let items = Box<[Int]>([])
        coordinator.openExternally = { externals.value.append($0) }
        coordinator.openTrackerItem = { items.value.append($0) }
        return (coordinator, { externals.value }, { items.value })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func click(_ coordinator: SelectableTextViewRepresentable.Coordinator, _ link: Any) -> Bool {
        coordinator.textView(NSTextView(), clickedOnLink: link, at: 0)
    }

    func test_itemLink_callsTrackerHandlerAndNeverOpensExternally() {
        let (coordinator, externals, items) = makeCoordinator()
        XCTAssertTrue(click(coordinator, URL(string: "matron://item/65")!))
        XCTAssertEqual(items(), [65])
        XCTAssertTrue(externals().isEmpty, "matron:// must never reach NSWorkspace")
    }

    func test_itemLinkAsString_isParsedToo() {
        // AppKit hands the delegate either a `URL` or a `String`.
        let (coordinator, externals, items) = makeCoordinator()
        XCTAssertTrue(click(coordinator, "matron://item/7"))
        XCTAssertEqual(items(), [7])
        XCTAssertTrue(externals().isEmpty)
    }

    func test_itemLink_withoutHandler_isSwallowed() {
        let coordinator = SelectableTextViewRepresentable.Coordinator()
        var externals: [URL] = []
        coordinator.openExternally = { externals.append($0) }
        XCTAssertTrue(click(coordinator, URL(string: "matron://item/65")!))
        XCTAssertTrue(externals.isEmpty, "no handler installed ⇒ swallow, never hand matron:// to the OS")
    }

    func test_httpLink_stillOpensExternally() {
        let (coordinator, externals, items) = makeCoordinator()
        XCTAssertTrue(click(coordinator, URL(string: "https://matron.chat")!))
        XCTAssertEqual(externals().map(\.absoluteString), ["https://matron.chat"])
        XCTAssertTrue(items().isEmpty)
    }

    /// Defense in depth: even if a non-item `matron://` URL somehow carried
    /// a `.link` attribute, the click must not reach `NSWorkspace`.
    func test_nonItemMatronLink_isSwallowed() {
        let (coordinator, externals, items) = makeCoordinator()
        XCTAssertTrue(click(coordinator, URL(string: "matron://link/abc")!))
        XCTAssertTrue(externals().isEmpty, "matron:// is registered with nothing")
        XCTAssertTrue(items().isEmpty)
    }

    /// …and it doesn't get rendered as a clickable link in the first place.
    func test_nonItemMatronLinkRendersUnclickable() {
        let attributed = MarkdownAttributed.attributedString(for: "See [pair](matron://link/abc) now.")
        let range = (attributed.string as NSString).range(of: "pair")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertNil(attributed.attributes(at: range.location, effectiveRange: nil)[.link])
    }

    func test_matrixLink_isStillSwallowed() {
        let (coordinator, externals, items) = makeCoordinator()
        XCTAssertTrue(click(coordinator, URL(string: "mxc://server/abc")!))
        XCTAssertTrue(externals().isEmpty)
        XCTAssertTrue(items().isEmpty)
    }

    /// Rendering half: the converter must keep an item link CLICKABLE (a
    /// `.link` attribute), unlike matrix/mxc which render as plain accent
    /// text — otherwise the tap never reaches the coordinator at all.
    func test_itemLinkRendersAsAClickableLink() {
        let attributed = MarkdownAttributed.attributedString(for: "See [#65](matron://item/65) for details.")
        let range = (attributed.string as NSString).range(of: "#65")
        XCTAssertNotEqual(range.location, NSNotFound, "the link text renders as `#65`")
        let link = attributed.attributes(at: range.location, effectiveRange: nil)[.link]
        XCTAssertEqual((link as? URL)?.absoluteString, "matron://item/65")
    }
}
#endif
