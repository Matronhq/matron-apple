import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Visual baselines for the conversation-link pill row under a bubble
/// (decision #2954): current titles for known conversations, the link text
/// (disabled) for one this device doesn't have, the "+N" overflow past four,
/// and right-alignment under an own message.
@MainActor
final class ConversationLinkPillSnapshotTests: XCTestCase {
    private static let sampleTime = Date(timeIntervalSince1970: 1_733_055_300)

    private let titles: [String: String] = [
        "c-1": "Auth refactor", "c-2": "Docs site redesign", "c-3": "Release 1.2",
        "c-5": "Flaky tests", "c-6": "Push relay",
    ]

    private func host() async -> ConversationLinkHost {
        let titles = self.titles
        let host = ConversationLinkHost(lookup: { titles[$0].map { .known($0) } ?? .unknown })
        for id in ["c-1", "c-2", "c-3", "c-4", "c-5", "c-6"] { await host.load(id) }
        return host
    }

    private func row(_ body: String, style: MessageAuthorStyle, host: ConversationLinkHost) -> some View {
        VStack(spacing: 4) {
            MessageBubble(style: style, timestamp: Self.sampleTime) {
                MarkdownText(body, theme: .matronMessage, lineSpacing: 4)
            }
            ConversationLinkPillRow(refs: ConversationLinkRefs.extract(from: body), style: style)
        }
        .environment(\.conversationLinkHost, host)
        .environment(\.openConversation, host.action)
        .frame(width: 390)
    }

    /// Two known conversations (current titles, not the link text) and one
    /// unknown (its link text, greyed).
    func test_botPills_knownAndUnknown() async {
        let host = await host()
        let body = "Started [auth](matron://convo/c-1) and [docs](matron://convo/c-2); [old one](matron://convo/c-4) is gone."
        assertVariants(of: row(body, style: .bot, host: host), named: "botPills")
    }

    /// Six links: four pills, then "+2"; wraps at phone width.
    func test_botPills_overflow() async {
        let host = await host()
        let body = (1...6).map { "[L\($0)](matron://convo/c-\($0))" }.joined(separator: " ")
        assertVariants(of: row(body, style: .bot, host: host), named: "botPillsOverflow")
    }

    func test_mePills_alignTrailing() async {
        let host = await host()
        assertVariants(of: row("Look at [this](matron://convo/c-3)", style: .me, host: host), named: "mePills")
    }
}
