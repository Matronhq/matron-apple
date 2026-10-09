import XCTest
import UIKit
import MatronDesignSystem
@testable import Matron

/// The measured size must be exactly what a live TextKit 2 `UITextView`
/// renders — that equality is what lets the layout know exact content
/// height with no estimates (spec §2 Self-sizing).
@MainActor
final class TextKitMeasureTests: XCTestCase {
    private let style = MarkdownAttributed.Style.phoneChat(bodySize: 17)
    private func rendered(_ source: String) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: style, cache: false).attributed
    }

    func test_emptyString_measuresZero() {
        XCTAssertEqual(TextKitMeasure.measure(NSAttributedString(), width: 300),
                       .init(size: .zero, lastBaseline: 0))
    }

    func test_shortText_hugsItsWidth() {
        let result = TextKitMeasure.hugging(rendered("Hi"), width: 300)
        XCTAssertLessThan(result.size.width, 40)
        XCTAssertGreaterThan(result.size.height, 15)
    }

    func test_longText_wrapsAtTheWidth() {
        let one = TextKitMeasure.hugging(rendered("word"), width: 200).size.height
        let result = TextKitMeasure.hugging(rendered(String(repeating: "word ", count: 60)), width: 200)
        XCTAssertLessThanOrEqual(result.size.width, 200)
        XCTAssertGreaterThan(result.size.height, one * 3)
    }

    func test_lastBaseline_sitsInsideTheLastLine() {
        let text = rendered("First line that wraps across several lines at this width for sure.")
        let result = TextKitMeasure.hugging(text, width: 120)
        XCTAssertLessThan(result.lastBaseline, result.size.height)
        XCTAssertGreaterThan(result.lastBaseline, result.size.height - 17 * 1.5)
    }

    func test_matchesALiveTextView() {
        let corpus = [
            "Hi",
            "A paragraph long enough to wrap onto a few lines at phone widths, with **bold** and `code`.",
            "# Heading\n\nBody under it.\n\n- one\n- two with a [link](https://example.com)\n\n> quoted",
            "1. first\n2. second item that goes on and wraps around at narrow widths\n3. third",
            String(repeating: "x", count: 300),
        ]
        for source in corpus {
            for width in [180.0, 269.0, 301.0] as [CGFloat] {
                let text = rendered(source)
                let measured = TextKitMeasure.hugging(text, width: width)
                let view = TimelineTextViewFactory.make()
                view.attributedText = text
                let live = view.sizeThatFits(CGSize(width: measured.size.width, height: .greatestFiniteMagnitude))
                XCTAssertEqual(ceil(live.height), measured.size.height, accuracy: 0.5,
                               "\(source.prefix(20)) @\(width)")
            }
        }
    }

    /// A list's lines start in from the edge. Hugging must count that
    /// indent as part of the width, or the second pass is narrower than
    /// the text it measured and wraps it again.
    func test_huggingAnIndentedParagraph_keepsItsLines() {
        for count in 4...40 {
            let source = "- " + (0..<count).map { "word\($0)" }.joined(separator: " ")
            let text = MarkdownAttributed.rendered(for: source, style: .phoneItem(bodySize: 18), cache: false).attributed
            let whole = TextKitMeasure.measure(text, width: 300)
            let hugged = TextKitMeasure.hugging(text, width: 300)
            XCTAssertEqual(hugged.size.height, whole.size.height, "\(count) words")
        }
    }
}
