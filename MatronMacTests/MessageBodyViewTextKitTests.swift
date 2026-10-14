#if os(macOS)
import XCTest
import AppKit
import MatronDesignSystem

/// Item bodies are measured with TextKit 1 (`Rendered.size(width:)`), so the
/// native item thread draws them with TextKit 1 too.
@MainActor
final class MessageBodyViewTextKitTests: XCTestCase {
    func test_forcesTextKit1_putsAPlainBodyOnTextKit1() {
        let body = MessageBodyView()
        body.forcesTextKit1 = true
        let source = "Just a paragraph, no table."
        body.configure(source: source, rendered: MarkdownAttributed.rendered(for: source, style: .item, cache: false),
                       itemID: "a", selectionController: nil)
        XCTAssertNil(body.textView.textLayoutManager)
        XCTAssertNotNil(body.textView.layoutManager)
    }

    func test_byDefault_aPlainBodyStaysOnTextKit2() {
        let body = MessageBodyView()
        let source = "Just a paragraph, no table."
        body.configure(source: source, rendered: MarkdownAttributed.rendered(for: source, style: .item, cache: false),
                       itemID: "a", selectionController: nil)
        XCTAssertNotNil(body.textView.textLayoutManager)
    }
}
#endif
