import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class ToolStreamCardSnapshotTests: XCTestCase {
    func test_streaming_collapsed_withCommand() {
        assertVariants(
            of: ToolStreamCard(command: "make test",
                               text: "$ make test\nCompiling Journal.swift\nCompiling Mapper.swift\nLinking…\n",
                               headTruncated: false).frame(width: 420),
            named: "streaming_collapsed")
    }

    func test_streaming_collapsed_withoutMeta_showsGenericHeader() {
        // Appends carry no meta; until a sync lands the header is generic.
        assertVariants(
            of: ToolStreamCard(command: nil, text: "warming up…\n", headTruncated: false)
                .frame(width: 420),
            named: "streaming_noMeta")
    }

    func test_streaming_expanded_headTruncated_showsNotice() {
        assertVariants(
            of: ToolStreamCard(command: "cargo build",
                               text: String(repeating: "compiling crate …\n", count: 12),
                               headTruncated: true, initiallyExpanded: true).frame(width: 420),
            named: "streaming_expanded_truncatedHead")
    }
}
