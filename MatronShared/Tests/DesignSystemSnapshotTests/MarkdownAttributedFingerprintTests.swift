#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Pins the Mac renderer's exact output — every run's range, text, font,
/// colours, link, underline/strike and paragraph metrics (table blocks
/// included) — for a corpus covering every block and inline kind, in both
/// styles. Recorded on `main` BEFORE the UIKit port (plan Task 2); the port
/// must reproduce it byte for byte. Re-record ONLY on purpose:
/// `MATRON_RECORD_MARKDOWN_FINGERPRINT=1 swift test --filter MarkdownAttributedFingerprintTests`.
final class MarkdownAttributedFingerprintTests: XCTestCase {
    static let corpus: [String] = [
        "Plain paragraph with **bold**, *italic*, ~~struck~~ and `inline code`.",
        "# Heading one\n\nBody under it.\n\n## Heading two\n\n### Heading three\n\nClosing.",
        "Intro paragraph.\n\n## A heading after a paragraph",
        "- alpha\n- beta with **bold**\n  - nested gamma\n\n1. first\n2. second",
        "> A quoted line\n> that continues.\n\nAfter the quote.",
        "Before code.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nAfter code.",
        "Ends with code:\n\n```\nmake test\n```",
        "Links: [web](https://example.com/a), [#65](matron://item/65), [room](matron://convo/xyz-123), [matrix](matrix:r/room:server), [pair](matron://link?code=AAAA-BBBB).",
        "| Left | Center | Right |\n|:-----|:------:|------:|\n| a | **b** | `c` |\n| d | e | f |\n\nAfter the table.",
        "| A |\n|---|\n| 1 |\n\n| B |\n|---|\n| 2 |",
        "Ends with a table:\n\n| K | V |\n|---|---|\n| x | y |",
        "[Voice note transcription]: Hello there.",
        "Line one\nline two in the same paragraph.\n\n\n\nFar paragraph.",
    ]

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/markdown-fingerprint-mac.txt")
    }

    func test_macRenderingIsUnchangedByThePort() throws {
        var sections: [String] = []
        for (styleName, style) in [("chat", MarkdownAttributed.Style.chat), ("item", MarkdownAttributed.Style.item)] {
            for (index, source) in Self.corpus.enumerated() {
                let rendered = MarkdownAttributed.attributedString(for: source, style: style)
                sections.append("## \(styleName) \(index)\n" + Self.fingerprint(rendered))
            }
        }
        let actual = sections.joined(separator: "\n")
        if ProcessInfo.processInfo.environment["MATRON_RECORD_MARKDOWN_FINGERPRINT"] == "1" {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: fixtureURL, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertEqual(actual, expected, "Mac MarkdownAttributed output changed — the UIKit port must not alter it")
    }

    static func fingerprint(_ string: NSAttributedString) -> String {
        var lines: [String] = []
        let text = string.string as NSString
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            var parts = ["\(range.location)+\(range.length) \(String(reflecting: text.substring(with: range)))"]
            if let font = attributes[.font] as? NSFont {
                parts.append("font=\(font.fontName)@\(font.pointSize) traits=\(font.fontDescriptor.symbolicTraits.rawValue)")
            }
            if let color = attributes[.foregroundColor] as? NSColor { parts.append("fg=\(color)") }
            if let color = attributes[.backgroundColor] as? NSColor { parts.append("bg=\(color)") }
            if let link = attributes[.link] { parts.append("link=\(link)") }
            if let underline = attributes[.underlineStyle] { parts.append("underline=\(underline)") }
            if let strike = attributes[.strikethroughStyle] { parts.append("strike=\(strike)") }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle { parts.append(paragraph(style)) }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func paragraph(_ style: NSParagraphStyle) -> String {
        var line = "para ls=\(style.lineSpacing) ps=\(style.paragraphSpacing) psb=\(style.paragraphSpacingBefore)"
            + " hi=\(style.headIndent) fhi=\(style.firstLineHeadIndent) al=\(style.alignment.rawValue)"
            + " blocks=\(style.textBlocks.count)"
        for case let block as NSTextTableBlock in style.textBlocks {
            line += " cell(r\(block.startingRow),c\(block.startingColumn),cols\(block.table.numberOfColumns)"
                + ",pad\(block.width(for: .padding, edge: .minX)),border\(block.width(for: .border, edge: .minX))"
                + ",marginMaxY\(block.width(for: .margin, edge: .maxY))"
                + ",bg\(block.backgroundColor.map { "\($0)" } ?? "nil"))"
        }
        return line
    }
}
#endif
