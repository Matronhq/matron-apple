import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronDesignSystem
@testable import Matron

/// The bug: pills drawn over the last line of their message, the last
/// one cut off. A pill shows the link's own text until its conversation's
/// title loads, and the title is usually longer. Four pills that fitted two
/// lines then need four, and the row has to grow with them.
@MainActor
final class TimelinePillTitleTests: XCTestCase {
    /// What the journal store knows, filled in by the test mid-way.
    private final class Titles: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: String] = [:]

        func set(_ titles: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            known = titles
        }

        func title(for id: String) -> ConversationLinkTitle {
            lock.lock(); defer { lock.unlock() }
            return known[id].map(ConversationLinkTitle.known) ?? .unknown
        }
    }

    private let refs = [
        ConversationLinkRef(id: "e0", text: "stale-marker guard"),
        ConversationLinkRef(id: "9c", text: "app bugs"),
        ConversationLinkRef(id: "dd", text: "Asset Studio"),
        ConversationLinkRef(id: "0b", text: "render stack"),
    ]
    private let loaded = [
        "e0": "[e0] stale-marker guard fixes across both apps",
        "9c": "[9c] Mission #36: this rest of the app bugs list",
        "dd": "[dd] Asset Studio merge and the chrome wave follow-up",
        "0b": "[0b] render stack restart after the box went away",
    ]

    private func pillsHeight(_ host: ConversationLinkHost, width: CGFloat) -> CGFloat {
        HostedSizer().height(of: ConversationLinkPillRow(refs: refs, style: .bot)
            .environment(\.conversationLinkHost, host), width: width, sizeCategory: .large)
    }

    /// The message's own row: a date separator comes before it.
    private func rowHeight(_ id: String, in h: TimelineHarness) throws -> CGFloat {
        let model = h.controller.scrollModel
        return model.rows[try XCTUnwrap(model.index(of: id), "row \(id) is not in the timeline")].height
    }

    func test_rowGrowsWithItsPills_whenTheConversationTitlesLoad() async throws {
        let titles = Titles()
        let host = ConversationLinkHost(lookup: { titles.title(for: $0) })
        let h = TimelineHarness(environment: TimelineHostedEnvironment(conversationLinkHost: host))
        let body = "Running again: " + refs.map { "[\($0.text)](matron://convo/\($0.id))" }.joined(separator: ", ") + "."
        try await h.start(with: [TimelineFixtures.text(1, body: body)])
        let width = h.collectionView.bounds.width
        let rowBefore = try rowHeight("1", in: h)
        let pillsBefore = pillsHeight(host, width: width)

        titles.set(loaded)
        for ref in refs { await host.load(ref.id) }
        let pillsAfter = pillsHeight(host, width: width)
        XCTAssertGreaterThan(pillsAfter, pillsBefore + 20, "the loaded titles must need more lines for this test to mean anything")

        try await waitUntil {
            ((try? self.rowHeight("1", in: h)) ?? 0) > rowBefore + 1 && !h.controller.hasPendingWork
        }
        let rowAfter = try rowHeight("1", in: h)
        XCTAssertEqual(rowAfter - rowBefore, pillsAfter - pillsBefore, accuracy: 1,
                       "the row grows by exactly what its pills grew")
    }
}
