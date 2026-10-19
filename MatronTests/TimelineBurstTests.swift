import XCTest
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Several messages landing at once must never leave rows drawn over each other.
@MainActor
final class TimelineBurstTests: XCTestCase {
    private func text(_ id: String, _ body: String, own: Bool = false, state: TimelineSendState = .sent,
                      at seconds: Double) -> TimelineItem {
        TimelineItem(id: id, sender: own ? "@me:s" : "@bot:s",
                     timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
                     kind: .text(body: body, formattedHTML: nil), isOwn: own, sendState: state)
    }

    private func long(_ n: Int) -> String {
        (0..<n).map { "Paragraph \($0) has a fair number of words so that it wraps across a line or two." }
            .joined(separator: "\n\n")
    }

    /// Every cell on screen shows its own row, at the model's frame, and
    /// draws inside it.
    private func assertNoOverlap(_ h: TimelineHarness, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let cv = h.collectionView
        cv.layoutIfNeeded()
        let model = h.controller.scrollModel
        XCTAssertEqual(cv.numberOfItems(inSection: 0), model.rows.count, "\(step): item count", file: file, line: line)
        for cell in cv.visibleCells {
            guard let indexPath = cv.indexPath(for: cell), model.rows.indices.contains(indexPath.item) else { continue }
            let index = indexPath.item
            let id = model.rows[index].id
            let expected = CGRect(x: 0, y: model.rowMinY(at: index), width: cv.bounds.width, height: model.rows[index].height)
            XCTAssertEqual(cell.frame.minY, expected.minY, accuracy: 0.5, "\(step): cell of \(id) y", file: file, line: line)
            XCTAssertEqual(cell.frame.height, expected.height, accuracy: 0.5, "\(step): cell of \(id) height", file: file, line: line)
            guard let text = cell as? TextMessageCell, let render = text.render else { continue }
            XCTAssertEqual(render.content.itemID, id, "\(step): cell at \(id) shows another row", file: file, line: line)
            if case .text(let content)? = h.controller.session.contents[id] {
                XCTAssertEqual(render.content.body, content.body, "\(step): \(id) shows stale text", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(text.bubbleForTesting.frame.maxY, cell.bounds.height + 0.5,
                                     "\(step): bubble of \(id) spills out of its row", file: file, line: line)
            for segment in text.segmentViewsForTesting.compactMap({ $0 as? UITextView }) where !segment.isHidden {
                var used: CGFloat = 0
                if let tlm = segment.textLayoutManager {
                    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) {
                        used = max(used, $0.layoutFragmentFrame.maxY)
                        return true
                    }
                }
                used += segment.textContainerInset.top + segment.textContainerInset.bottom
                XCTAssertLessThanOrEqual(used, segment.bounds.height + 1,
                                         "\(step): text of \(id) overflows its segment (\(used) > \(segment.bounds.height))",
                                         file: file, line: line)
            }
        }
    }

    /// A file card's measurement drops out of the cache and the off-screen
    /// re-measure comes back shorter than the cell draws it: when the next
    /// message lands, the row is laid out short with nothing reconfigured.
    /// Its cell must put it right, not leave it drawn over the row below.
    func test_aHostedRowLaidOutShorterThanItDrawsIsCorrectedByItsCell() async throws {
        let cache = TimelineMeasureCache(countLimit: 4000)
        let h = TimelineHarness(cache: cache)
        var items = (1...4).map { text("\($0)", "Message \($0)", at: Double($0)) }
        items.append(TimelineItem(id: "notice", sender: "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_005),
                                  kind: .file(url: nil, filename: "notes.md", caption: "Delivered 2 queued messages",
                                              sizeBytes: 1200, expired: false),
                                  isOwn: false, sendState: .sent))
        items.append(text("6", "Message 6", at: 6))
        try await h.start(with: items)
        let model = { h.controller.scrollModel }
        let index = try XCTUnwrap(model().index(of: "notice"))
        let drawn = model().rows[index].height
        let content = try XCTUnwrap(h.controller.session.contents["notice"])
        let category = h.controller.traitCollection.preferredContentSizeCategory
        let key = TimelineMeasureKey(roomID: h.viewModel.roomID, rowID: "notice", width: h.collectionView.bounds.width,
                                     sizeCategory: (category == .unspecified ? .large : category).rawValue)
        cache.store(.hosted(drawn - 12), content: content, key: key)

        items.append(text("7", "Message 7", at: 7))
        try await h.emit(items)
        try await waitUntil { abs(model().rows[index].height - drawn) < 0.5 }
        assertNoOverlap(h, "after the notice was corrected")
    }

    func test_randomBurstsNeverOverlapRows() async throws {
        let seed = UInt64(ProcessInfo.processInfo.environment["BURST_SEED"] ?? "") ?? 7
        var rng = SeededGenerator(seed: seed)
        let h = TimelineHarness()
        var next = 1
        func make(_ own: Bool = false, _ state: TimelineSendState = .sent) -> TimelineItem {
            defer { next += 1 }
            let paragraphs = Int.random(in: 0...3, using: &rng)
            return text("m\(next)", paragraphs == 0 ? "Message \(next)" : long(paragraphs), own: own, state: state,
                        at: Double(next))
        }
        var items = (0..<25).map { _ in make() }
        try await h.start(with: items)
        assertNoOverlap(h, "open")
        var streaming: String?
        for step in 0..<60 {
            let burst = Int.random(in: 1...4, using: &rng)
            for _ in 0..<burst {
                switch Int.random(in: 0..<8, using: &rng) {
                case 0, 1:
                    items.append(make(Bool.random(using: &rng), [.sent, .queued, .sending].randomElement(using: &rng)!))
                case 2 where items.count > 10:
                    items.remove(at: Int.random(in: 0..<items.count, using: &rng))
                case 3:
                    let i = Int.random(in: max(0, items.count - 8)..<items.count, using: &rng)
                    let old = items[i]
                    let body = Bool.random(using: &rng) ? long(Int.random(in: 1...4, using: &rng)) : "short \(step)"
                    items[i] = TimelineItem(id: old.id, sender: old.sender, timestamp: old.timestamp,
                                            kind: .text(body: body, formattedHTML: nil), isOwn: old.isOwn,
                                            sendState: old.sendState)
                case 4:
                    if let i = items.indices.last(where: { items[$0].isOwn && items[$0].sendState != .sent }) {
                        let old = items[i]
                        items[i] = TimelineItem(id: old.id, sender: old.sender, timestamp: old.timestamp, kind: old.kind,
                                                isOwn: true, sendState: .sent)
                    }
                case 5 where items.count > 3:
                    let i = Int.random(in: (items.count - 3)..<(items.count - 1), using: &rng)
                    items.swapAt(i, i + 1)
                case 6:
                    streaming = (streaming ?? "Thinking") + (Bool.random(using: &rng) ? " more words here" : "\n\n" + long(1))
                default:
                    if let reply = streaming {
                        items.append(text("m\(next)", reply, at: Double(next)))
                        next += 1
                        streaming = nil
                    }
                }
            }
            let shown = items + (streaming.map {
                [JournalTimelineMapper.streamingItem(messageRef: "r", text: $0,
                                                     convoTS: Date(timeIntervalSince1970: 1_700_000_000 + Double(next)))]
            } ?? [])
            h.service.emit(shown)
            if Int.random(in: 0..<3, using: &rng) == 0 {
                try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...40_000_000, using: &rng))
                continue
            }
            try await waitUntil { h.viewModel.items == shown }
            try await h.settle()
            assertNoOverlap(h, "step \(step)")
        }
    }
}

/// Deterministic randomness for the fuzz (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
