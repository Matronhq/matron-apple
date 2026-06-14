import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Visual baselines for `MessageBubble`. The two author styles
/// (`.bot` left-aligned no-bg, `.me` right-aligned with subtle bg) are
/// covered separately so a regression to either branch shows up as a
/// distinct failing baseline. Each carries a fixed timestamp so the
/// bottom-right time renders deterministically for the local baseline.
final class MessageBubbleSnapshotTests: XCTestCase {
    /// Fixed instant so the rendered bottom-right time is stable.
    private static let sampleTime = Date(timeIntervalSince1970: 1_733_055_300)

    func test_botBubble() {
        let view = MessageBubble(style: .bot, timestamp: Self.sampleTime) {
            MarkdownText("Sure — let me check the code and get back to you on that.",
                         theme: .matronMessage, lineSpacing: 4)
        }
        .frame(width: 320)
        assertVariants(of: view, named: "botBubble")
    }

    func test_meBubble() {
        let view = MessageBubble(style: .me, timestamp: Self.sampleTime) {
            MarkdownText("Can you look at the auth bug?",
                         theme: .matronMessage, lineSpacing: 4)
        }
        .frame(width: 320)
        assertVariants(of: view, named: "meBubble")
    }

    /// Column at phone width: guards that a long bot message extends to the
    /// same horizontal margin on the right as on the left (even margins).
    func test_column_evenMargins() {
        let view = VStack(spacing: 8) {
            MessageBubble(style: .bot, timestamp: Self.sampleTime) {
                MarkdownText("This is a longer assistant reply that should wrap and reach the same margin on the right edge as it has on the left, using the full width of the column.",
                             theme: .matronMessage, lineSpacing: 4)
            }
            MessageBubble(style: .me, timestamp: Self.sampleTime) {
                MarkdownText("Short one from me", theme: .matronMessage, lineSpacing: 4)
            }
        }
        .frame(width: 390)
        assertVariants(of: view, named: "column")
    }
}
