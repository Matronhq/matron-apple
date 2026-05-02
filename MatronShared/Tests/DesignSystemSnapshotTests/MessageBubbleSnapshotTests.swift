import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Visual baselines for `MessageBubble`. The two author styles
/// (`.bot` left-aligned no-bg, `.me` right-aligned with subtle bg) are
/// covered separately so a regression to either branch shows up as a
/// distinct failing baseline.
final class MessageBubbleSnapshotTests: XCTestCase {
    func test_botBubble() {
        let view = MessageBubble(style: .bot, senderLabel: "Claude") {
            MarkdownText("Sure — let me check the code…")
        }
        .frame(width: 320)
        assertVariants(of: view, named: "botBubble")
    }

    func test_meBubble() {
        let view = MessageBubble(style: .me) {
            MarkdownText("Can you look at the auth bug?")
        }
        .frame(width: 320)
        assertVariants(of: view, named: "meBubble")
    }
}
