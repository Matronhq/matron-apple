import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class MarkdownTextSnapshotTests: XCTestCase {
    func test_plainParagraph() {
        let view = MarkdownText("Hello, world. This is a plain paragraph with **bold** and *italics*.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "plainParagraph")
    }

    func test_inlineCode() {
        let view = MarkdownText("Use `swift test` to run the suite.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "inlineCode")
    }

    func test_codeBlock() {
        let view = MarkdownText(#"""
            Here's some Swift:
            ```swift
            func greet(name: String) -> String {
                return "Hello, \(name)!"
            }
            ```
            """#)
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "codeBlock")
    }

    func test_link() {
        let view = MarkdownText("See the [Matron docs](https://matron.example.com) for more.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "link")
    }
}
