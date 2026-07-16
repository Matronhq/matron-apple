import XCTest
import SwiftUI
@testable import Matron
import MatronChat
import MatronModels

/// Regression under test (Dan, 2026-07-16): iPhone chat-list rows still jump
/// in height as messages stream in, and some rows appear to have no snippet
/// at all. The row reserves two snippet lines (`lineLimit(2,
/// reservesSpace:)`), so the reserved height must be CONTENT-INDEPENDENT:
/// empty snippets, emoji-bearing tool indicators, multi-line commands, and
/// leading-newline bodies must all produce the same row height.
@MainActor
final class ChatRowHeightTests: XCTestCase {

    private static let width: CGFloat = 361  // iPhone list content width

    private func rowHeight(snippet: String, unread: Int = 0, activity: Date? = Date(timeIntervalSince1970: 1_752_000_000)) -> CGFloat {
        let summary = ChatSummary(
            id: "!row:\(snippet.hashValue):\(unread)",
            title: "studio: Fix the composer",
            bot: BotIdentity(matrixID: "@bot:s", displayName: "Matron", avatarURL: nil),
            lastActivity: activity,
            unreadCount: unread,
            snippet: snippet
        )
        let host = UIHostingController(rootView: ChatRow(summary: summary))
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        return size.height
    }

    func test_rowHeight_isIndependentOfSnippetContent() {
        let variants: [(String, String)] = [
            ("empty", ""),
            ("plain", "Sounds good, shipping it now."),
            ("wrapping", "A longer snippet that definitely wraps onto a second line at iPhone width because it just keeps going."),
            ("toolEmoji", "🔧 `xcodebuild test -scheme MatronMac`"),
            ("readEmoji", "📖 /Users/danbarker/Dev/matron-apple/MatronMac/Features/Chat/MacChatView.swift"),
            ("dollarCommand", "$ deploy.sh --dry-run"),
            ("multiline", "$ ls -la\n$ pwd\n$ whoami"),
            ("leadingNewlines", "\n\nBody that started with blank lines"),
            ("diffPlaceholder", "[diff]"),
            ("todos", "📋 Todos:\n✅ first\n🔄 second"),
        ]
        let heights = variants.map { ($0.0, rowHeight(snippet: $0.1)) }
        let reference = heights[0].1
        print("ROWHEIGHTS \(heights.map { "\($0.0)=\($0.1)" }.joined(separator: " "))")
        for (name, height) in heights {
            XCTAssertEqual(
                height, reference, accuracy: 0.5,
                "row height must not depend on snippet content — '\(name)' rendered \(height) vs \(reference)"
            )
        }
    }

    /// The trailing accessory (relative time above the unread badge) must not
    /// change the row height either — a convo with no activity date or no
    /// unread must match one with both.
    func test_rowHeight_isIndependentOfTrailingAccessory() {
        let reference = rowHeight(snippet: "plain", unread: 3)
        XCTAssertEqual(rowHeight(snippet: "plain", unread: 0), reference, accuracy: 0.5,
                       "unread badge must not change row height")
        XCTAssertEqual(rowHeight(snippet: "plain", unread: 0, activity: nil), reference, accuracy: 0.5,
                       "missing lastActivity must not change row height")
    }
}
