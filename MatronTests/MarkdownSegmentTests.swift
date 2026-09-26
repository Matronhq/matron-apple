import XCTest
import UIKit
import MatronDesignSystem

/// Spec §2: code blocks and tables become their own block segments on iOS.
final class MarkdownSegmentTests: XCTestCase {
    private func segments(_ source: String) -> [MarkdownSegment] {
        MarkdownAttributed.rendered(for: source, style: .phoneChat(bodySize: 17), cache: false).segments
    }

    private func text(_ segment: MarkdownSegment) -> String? {
        if case .text(let string) = segment { return string.string }
        return nil
    }

    func test_plainMessage_isOneTextSegment() {
        let result = segments("Just a sentence.\n\nAnd another.")
        guard result.count == 1 else { return XCTFail("expected 1 segment, got \(result.count): \(result)") }
        XCTAssertEqual(text(result[0]), "Just a sentence.\nAnd another.")
    }

    func test_codeBlock_splitsProseAroundIt() {
        let result = segments("Intro line.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nOutro line.")
        guard result.count == 3 else { return XCTFail("expected 3 segments, got \(result.count): \(result)") }
        XCTAssertEqual(text(result[0]), "Intro line.")
        XCTAssertEqual(result[1], .code(language: "swift", code: "let x = 1\n\nlet y = 2"))
        XCTAssertEqual(text(result[2]), "Outro line.")
    }

    func test_messageEndingInCode_hasNoTrailingProse() {
        let result = segments("Run:\n\n```\nmake test\n```")
        guard result.count == 2 else { return XCTFail("expected 2 segments, got \(result.count): \(result)") }
        XCTAssertEqual(result[1], .code(language: nil, code: "make test"))
    }

    func test_table_becomesATableSegment_withAlignmentsAndInlineStyles() throws {
        let result = segments("Before.\n\n| Case | Result |\n|:--|--:|\n| retry | **failed** |\n\nAfter.")
        guard result.count == 3 else { return XCTFail("expected 3 segments, got \(result.count): \(result)") }
        guard case .table(let table) = result[1] else { return XCTFail("expected a table, got \(result[1])") }
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows.map { $0.map(\.string) }, [["Case", "Result"], ["retry", "failed"]])
        let bold = table.rows[1][1].attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        XCTAssertEqual(text(result[2]), "After.")
    }

    func test_backToBackTables_areTwoSegments() {
        let result = segments("| A |\n|---|\n| 1 |\n\n| B |\n|---|\n| 2 |")
        XCTAssertEqual(result.filter(\.isTable).count, 2)
    }

    func test_emptyBody_hasNoSegments() {
        XCTAssertEqual(segments(""), [])
    }
}
