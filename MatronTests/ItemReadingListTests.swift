import XCTest
import UIKit
import CoreText
import MatronDesignSystem
@testable import Matron

/// The native item thread sets its lists the way the SwiftUI item cards
/// do: the marker right-aligned in a column 1.5 em wide, the text a gap
/// past it, a bullet a third of an em across, and a paragraph gap round
/// every item. The chat keeps its compact lists.
@MainActor
final class ItemReadingListTests: XCTestCase {
    private let bodySize: CGFloat = 17 * ItemTypography.phoneBodyScale
    private var style: MarkdownAttributed.Style { .phoneItem(bodySize: bodySize) }
    private var textColumn: CGFloat { 1.5 * bodySize + 8 }

    private func render(_ source: String, style: MarkdownAttributed.Style? = nil) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: style ?? self.style, cache: false).attributed
    }

    private func laidOut(_ text: NSAttributedString, width: CGFloat = 300) -> UITextView {
        let view = TimelineTextViewFactory.make()
        view.attributedText = text
        view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        view.layoutIfNeeded()
        return view
    }

    /// Where the first occurrence of `substring` is drawn.
    private func rect(of substring: String, in view: UITextView,
                      file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let range = (view.text as NSString).range(of: substring)
        guard range.location != NSNotFound,
              let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let textRange = view.textRange(from: start, to: end) else {
            XCTFail("\(substring.debugDescription) not laid out", file: file, line: line)
            return .null
        }
        return view.firstRect(for: textRange)
    }

    private func paragraph(_ text: NSAttributedString, at substring: String) -> NSParagraphStyle? {
        let range = (text.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    func test_bulletsAreShapesByDepth_andTheChatKeepsItsOwn() {
        let source = "- one\n  - two\n    - three\n      - four"
        XCTAssertEqual(render(source).string, "\u{25CF} one\n\u{25CB} two\n\u{25A0} three\n\u{25A0} four")
        XCTAssertEqual(render(source, style: .phoneChat(bodySize: 17)).string,
                       "\u{2022} one\n\u{2022} two\n\u{2022} three\n\u{2022} four")
    }

    func test_theBulletIsAThirdOfAnEmAcross_centredOnTheCapitals() throws {
        let text = render("- one")
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let lift = try XCTUnwrap(text.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{25CF}", attributes: [.font: font]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        XCTAssertEqual(ink.height, (bodySize / 3).rounded(), accuracy: 0.1)
        XCTAssertEqual(ink.midY + lift, UIFont.systemFont(ofSize: bodySize).capHeight / 2, accuracy: 0.1)
    }

    func test_theBulletDoesNotMakeItsLineTaller() {
        let wrapped = String(repeating: "word ", count: 30)
        let list = laidOut(render("- \(wrapped)"))
        let prose = laidOut(render(wrapped))
        XCTAssertEqual(rect(of: "word", in: list).height, rect(of: "word", in: prose).height, accuracy: 0.01)
        XCTAssertEqual(rect(of: "word", in: list).minY, rect(of: "word", in: prose).minY, accuracy: 0.01)
    }

    /// The leftmost and rightmost drawn points of `view` in a band of
    /// rows and columns. Drawn, not asked of the text view: a caret sits
    /// halfway into a kerned gap, so `firstRect` misplaces the letter
    /// after a marker.
    private func ink(in view: UITextView, rows: ClosedRange<CGFloat>,
                     columns: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        let scale: CGFloat = 3
        let width = Int(view.bounds.width * scale), height = Int((rows.upperBound + 1) * scale)
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        view.traitCollection.performAsCurrent {
            UIGraphicsPushContext(context)
            view.overrideUserInterfaceStyle = .light
            view.layer.render(in: context)
            UIGraphicsPopContext()
        }
        var lowest: Int?, highest: Int?
        for y in Int(rows.lowerBound * scale)..<Int(rows.upperBound * scale) {
            for x in Int(columns.lowerBound * scale)..<min(width, Int(columns.upperBound * scale))
            where pixels[y * width + x] < 128 {
                lowest = min(lowest ?? x, x)
                highest = max(highest ?? x, x)
            }
        }
        guard let lowest, let highest else { return nil }
        return CGFloat(lowest) / scale...CGFloat(highest + 1) / scale
    }

    /// The rows of the line `substring` is on.
    private func rows(of substring: String, in view: UITextView) -> ClosedRange<CGFloat> {
        let line = rect(of: substring, in: view)
        return max(0, line.minY)...line.maxY
    }

    /// Where the text of the line `substring` is on starts, and where
    /// its marker (if it has one) ends. `depth` is the list level.
    private func line(_ substring: String, in view: UITextView, depth: CGFloat = 0)
        -> (marker: ClosedRange<CGFloat>?, text: ClosedRange<CGFloat>?) {
        let rows = rows(of: substring, in: view)
        let gapMiddle = depth * textColumn + 1.5 * bodySize + 4
        return (ink(in: view, rows: rows, columns: 0...gapMiddle),
                ink(in: view, rows: rows, columns: gapMiddle...view.bounds.width))
    }

    /// A marker's glyph has a side bearing too, so its ink ends a point or
    /// so short of the column its advance ends at.
    /// "H" has a stem at its left edge, a side bearing in from the origin.
    private var bearing: CGFloat { 1.5 }

    func test_theTextStartsAtTheTextColumn_onEveryLine() throws {
        let view = laidOut(render("- Hfirst \(String(repeating: "Hword ", count: 30))Htail"))
        let first = try XCTUnwrap(line("Hfirst", in: view).text)
        XCTAssertEqual(first.lowerBound, textColumn + bearing, accuracy: 1)
        XCTAssertGreaterThan(rect(of: "Htail", in: view).minY, rect(of: "Hfirst", in: view).maxY, "the item wraps")
        let wrapped = try XCTUnwrap(ink(in: view, rows: rows(of: "Htail", in: view), columns: 0...300))
        XCTAssertEqual(wrapped.lowerBound, first.lowerBound, accuracy: 0.4, "a wrapped line starts under the first")
        XCTAssertEqual(paragraph(view.attributedText, at: "Hfirst")?.headIndent, textColumn)
    }

    func test_everyItemOfAListStartsAtTheTextColumn() throws {
        let view = laidOut(render("**What it answers**\n\n- Hardware for two\n- How they join\n  - Hollow"))
        XCTAssertEqual(try XCTUnwrap(line("Hardware", in: view).text).lowerBound, textColumn + bearing, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(line("How", in: view).text).lowerBound, textColumn + bearing, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(line("Hollow", in: view, depth: 1).text).lowerBound,
                       2 * textColumn + bearing, accuracy: 1)
    }

    func test_theMarkerEndsWhereItsColumnDoes() throws {
        let bullets = laidOut(render("- Hone"))
        let bullet = try XCTUnwrap(line("Hone", in: bullets).marker)
        XCTAssertEqual(bullet.upperBound, 1.5 * bodySize, accuracy: 1.5)
        XCTAssertEqual(bullet.upperBound - bullet.lowerBound, (bodySize / 3).rounded(), accuracy: 0.7)

        let source = (1...10).map { "\($0). Hitem\($0)" }.joined(separator: "\n")
        let numbers = laidOut(render(source))
        for item in ["Hitem1", "Hitem10"] {
            let drawn = line(item, in: numbers)
            XCTAssertEqual(try XCTUnwrap(drawn.marker).upperBound, 1.5 * bodySize, accuracy: 1.5, item)
            XCTAssertEqual(try XCTUnwrap(drawn.text).lowerBound, textColumn + bearing, accuracy: 1, item)
        }
    }

    func test_aNestedListStepsInByOneColumn_andAContinuationSitsUnderItsItem() throws {
        let view = laidOut(render("1. Houter\n   - Hinner\n\n   Hafter"))
        XCTAssertEqual(try XCTUnwrap(line("Houter", in: view).text).lowerBound, textColumn + bearing, accuracy: 1)
        let inner = line("Hinner", in: view, depth: 1)
        XCTAssertEqual(try XCTUnwrap(inner.text).lowerBound, 2 * textColumn + bearing, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(inner.marker).upperBound, textColumn + 1.5 * bodySize, accuracy: 1.5)
        let after = try XCTUnwrap(ink(in: view, rows: rows(of: "Hafter", in: view), columns: 0...300))
        XCTAssertEqual(after.lowerBound, textColumn + bearing, accuracy: 1)
    }

    func test_everyItemHasAParagraphGapRoundIt() {
        let text = render("Before\n\n- one\n- two\n\nAfter")
        // TextKit's own leading after the last line makes up the rest.
        let gap = ItemTypography.paragraphSpacing - ItemTypography.lineSpacing
        XCTAssertEqual(paragraph(text, at: "one")?.paragraphSpacing, gap)
        XCTAssertEqual(paragraph(text, at: "two")?.paragraphSpacing, gap)
        XCTAssertEqual(paragraph(text, at: "Before")?.paragraphSpacing, gap)

        let view = laidOut(text)
        let pitch = rect(of: "two", in: view).minY - rect(of: "one", in: view).minY
        XCTAssertEqual(pitch, UIFont.systemFont(ofSize: bodySize).lineHeight + ItemTypography.paragraphSpacing,
                       accuracy: 0.5, "as far apart as the SwiftUI cards set paragraphs")
        XCTAssertEqual(rect(of: "one", in: view).minY - rect(of: "Before", in: view).minY, pitch, accuracy: 0.5)
        XCTAssertEqual(rect(of: "After", in: view).minY - rect(of: "two", in: view).minY, pitch, accuracy: 0.5)
    }

    func test_aCopiedListStartsWithPlainBullets() {
        let text = render("- one\n  - two\n\n1. three").string
        XCTAssertEqual(MarkdownAttributed.plainText(copying: text), "\u{2022} one\n\u{2022} two\n1. three")
        XCTAssertEqual(MarkdownAttributed.plainText(copying: "a \u{25CF} b"), "a \u{25CF} b",
                       "a shape in the middle of a line is the writer's own")
    }

    func test_theProseViewCopiesAndReadsPlainBullets() {
        let view = ItemProseTextView.make()
        view.attributedText = render("- one\n- two")
        XCTAssertEqual(view.accessibilityValue, "\u{2022} one\n\u{2022} two")
        view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        UIPasteboard.general.string = ""
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "\u{2022} one\n\u{2022} two")
    }
}
