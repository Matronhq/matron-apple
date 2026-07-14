#if os(macOS)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Visual-regression baseline for the Mac selectable message body. Renders a
/// message exercising the block kinds the converter maps (paragraphs, an
/// unordered list, inline formatting, and a fenced code block) so a regression
/// in `MarkdownAttributed` or the `NSTextView` layout is caught here.
final class SelectableMessageTextSnapshotTests: XCTestCase {
    func test_richMessage() {
        let view = SelectableMessageText("""
        Here's a **rich** message with some *emphasis* and `inline code`.

        A short list:
        - First item
        - Second item

        And a fenced block:
        ```swift
        let greeting = "hello"
        ```
        """)
        .frame(width: 320)
        .padding()
        assertVariants(of: view, named: "richMessage")
    }
}
#endif
