import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronDesignSystem
@testable import Matron

/// A tracker link shows its target's kind and title after it once the
/// journal answers, with the message unchanged. The row must rebuild and
/// re-measure with the chip, which here wraps the text onto more lines.
@MainActor
final class TimelineTrackerChipTests: XCTestCase {
    private func rowHeight(_ id: String, in h: TimelineHarness) throws -> CGFloat {
        let model = h.controller.scrollModel
        return model.rows[try XCTUnwrap(model.index(of: id), "row \(id) is not in the timeline")].height
    }

    func test_rowGrowsWithItsChip_whenTheAnswerLands() async throws {
        let origin = TrackerLinkFixture.origin
        let gate = AsyncGate()
        let title = "A tracker item whose title is a good deal longer than the link that points at it"
        let titles = TrackerLinkTitles(origin: origin, lookup: { _, _ in
            await gate.wait()
            return .found(kind: "item", title: title)
        })
        let links = TrackerNumberLinks(origin: origin, find: { _ in .web }, titles: titles)
        let h = TimelineHarness(environment: TimelineHostedEnvironment(trackerNumberLinks: links))
        try await h.start(with: [TimelineFixtures.text(1, body: "Filed [#12](matron://item/12).")])
        let before = try rowHeight("1", in: h)

        await gate.open()
        try await waitUntil {
            ((try? self.rowHeight("1", in: h)) ?? 0) > before + 10 && !h.controller.hasPendingWork
        }
    }
}
