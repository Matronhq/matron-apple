import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class CodeBlockSnapshotTests: XCTestCase {
    func test_swiftSnippet() {
        let view = CodeBlock(language: "swift", source: """
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            """)
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "swiftSnippet")
    }

    func test_unknownLanguage() {
        let view = CodeBlock(language: "", source: "echo hello")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "unknownLanguage")
    }
}
