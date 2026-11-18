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

final class CodeBlockFenceInfoTests: XCTestCase {
    func test_languageIsTheFirstWord() {
        XCTAssertEqual(CodeBlock.FenceInfo("json"), .init("json"))
        XCTAssertEqual(CodeBlock.FenceInfo("json").language, "json")
        XCTAssertFalse(CodeBlock.FenceInfo("json").collapsed)
        XCTAssertEqual(CodeBlock.FenceInfo("").language, "")
    }

    func test_collapsedWordFoldsTheBlock() {
        let info = CodeBlock.FenceInfo("json collapsed")
        XCTAssertEqual(info.language, "json")
        XCTAssertTrue(info.collapsed)
        // Only a later word counts: a language called "collapsed" is a language.
        XCTAssertFalse(CodeBlock.FenceInfo("collapsed").collapsed)
    }
}

final class CodeBlockCollapsedSnapshotTests: XCTestCase {
    func test_collapsedJSON() {
        let view = CodeBlock(language: "json collapsed", source: #"{"message":"hello","room_id":"room-a"}"#)
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "collapsedJSON")
    }
}
