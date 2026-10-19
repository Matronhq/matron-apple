import XCTest
import AppKit
import MatronChat
import MatronModels
import MatronEvents
import MatronViewModels
import MatronDesignSystem
import SwiftUI
@testable import MatronMac

/// Several messages landing at once must never leave rows drawn over each other.
@MainActor final class MacTimelineBurstTests: XCTestCase {
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

    /// Every drawn row sits in its table slot, and draws inside it.
    private func assertNoOverlap(_ h: MacTimelineHarness, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        h.controller.view.layoutSubtreeIfNeeded()
        let table = h.controller.tableView!
        let model = h.controller.session.scrollModel
        // Asked in order, every rect is the model's: a row view the table
        // placed on an estimated height shows up below as off its row.
        for i in model.rows.indices {
            let rect = table.rect(ofRow: i + 1)
            XCTAssertEqual(rect.minY, model.rowMinY(at: i), accuracy: 0.5, "\(step): row \(model.rows[i].id) y", file: file, line: line)
            XCTAssertEqual(rect.height, model.rows[i].height, accuracy: 0.5, "\(step): row \(model.rows[i].id) height", file: file, line: line)
        }
        // No row view left in the table that the table no longer counts as a row.
        var counted = Set<ObjectIdentifier>()
        table.enumerateAvailableRowViews { rowView, _ in counted.insert(ObjectIdentifier(rowView)) }
        for case let stray as NSTableRowView in table.subviews where !stray.isHidden && !counted.contains(ObjectIdentifier(stray)) {
            XCTFail("\(step): a stray row view at \(stray.frame) draws over the rows", file: file, line: line)
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard row >= 1, row <= model.rows.count else { return }
            let id = model.rows[row - 1].id
            let rect = table.rect(ofRow: row)
            XCTAssertEqual(rowView.frame.minY, rect.minY, accuracy: 0.5, "\(step): view of \(id) y", file: file, line: line)
            XCTAssertEqual(rowView.frame.height, rect.height, accuracy: 0.5, "\(step): view of \(id) height", file: file, line: line)
            let gap = row < model.rows.count ? MacTimelineController.rowSpacing : 0
            if let hosted = rowView.view(atColumn: 0) as? MacTimelineController.HostedView,
               let content = hosted.subviews.first {
                XCTAssertLessThanOrEqual(content.fittingSize.height, rect.height - gap + 0.5,
                                         "\(step): card \(id) draws taller than its row", file: file, line: line)
            }
            guard let cell = rowView.view(atColumn: 0) as? MacTextRowView else { return }
            cell.layoutSubtreeIfNeeded()
            for piece in cell.subviews.compactMap({ $0 as? NSHostingView<AnyView> }) where !piece.isHidden {
                XCTAssertLessThanOrEqual(piece.frame.maxY, rect.height - gap + 0.5,
                                         "\(step): a hosted piece of \(id) sits below its row", file: file, line: line)
                let drawn = NSHostingView(rootView: piece.rootView.frame(width: piece.frame.width)).fittingSize.height
                XCTAssertLessThanOrEqual(drawn, piece.frame.height + 0.5,
                                         "\(step): a hosted piece of \(id) draws taller (\(drawn)) than its frame (\(piece.frame.height))",
                                         file: file, line: line)
            }
            XCTAssertLessThanOrEqual(cell.bubbleFrameForTesting.maxY, rect.height + 0.5,
                                     "\(step): bubble of \(id) spills out of its row", file: file, line: line)
            if case .text(let content)? = h.controller.session.contents[id] {
                XCTAssertEqual(cell.renderForTesting?.content.body, content.body, "\(step): \(id) shows stale text", file: file, line: line)
            }
            let tv = cell.body.textView
            var used: CGFloat = 0
            if let tlm = tv.textLayoutManager {
                // The fragments, not `usageBoundsForTextContainer`: that one
                // can stay at an earlier, taller text after an edit.
                tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) {
                    used = max(used, $0.layoutFragmentFrame.maxY)
                    return true
                }
            } else if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                used = lm.usedRect(for: tc).height
            }
            XCTAssertLessThanOrEqual(used, cell.body.frame.height + 1,
                                     "\(step): text of \(id) overflows its body (\(used) > \(cell.body.frame.height))",
                                     file: file, line: line)
        }
    }

    func test_aBurstOfDeliveriesStreamsAndTranscriptsNeverOverlapsRows() async throws {
        let h = MacTimelineHarness()
        var items = (1...30).map { text("\($0)", $0 % 4 == 0 ? long(2) : "Message \($0)", at: Double($0)) }
        try await h.start(with: items)
        assertNoOverlap(h, "open")

        // The user's messages wait in the queue while the agent streams.
        items += [text("q1", "first queued message", own: true, state: .queued, at: 40),
                  text("q2", "🎙️ Voice note", own: true, state: .queued, at: 41)]
        var reply = "Looking"
        try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: reply, convoTS: Date(timeIntervalSince1970: 1_700_000_042))])
        assertNoOverlap(h, "queued + stream")
        for delta in [" into it.", "\n\nHere is what I found:", "\n\n- one\n- two\n- three", "\n\n" + long(3)] {
            reply += delta
            try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: reply, convoTS: Date(timeIntervalSince1970: 1_700_000_042))])
            assertNoOverlap(h, "stream delta")
        }

        // In one go: the reply finishes, the queue is delivered, the voice
        // note's transcript lands and several agent messages arrive.
        items[30] = text("q1", "first queued message", own: true, at: 40)
        items[31] = text("q2", "🎙️ " + long(2), own: true, at: 41)
        items += [text("final", reply, at: 42),
                  text("n1", "📨 Delivered 2 queued messages", at: 43),
                  text("a1", long(1), at: 44),
                  text("a2", "Short one", at: 45),
                  text("a3", long(4), at: 46)]
        try await h.emit(items)
        assertNoOverlap(h, "burst")

        // And a few back to back without settling in between.
        for n in 0..<6 {
            items.append(text("b\(n)", n % 2 == 0 ? long(n + 1) : "ok \(n)", at: 50 + Double(n)))
            h.service.emit(items)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await h.emit(items)
        assertNoOverlap(h, "back to back")
    }

    /// A message landing above the reader in a long chat (a queued send
    /// delivered into place, a transcript): the rows below it on screen
    /// move by its real height.
    func test_aRowLandingAboveTheReaderMovesTheRowsBelowByItsRealHeight() async throws {
        let h = MacTimelineHarness()
        var items = (1...200).map { text("\($0)", $0 % 3 == 0 ? long(2) : "Message \($0)", at: Double($0)) }
        try await h.start(with: items)
        assertNoOverlap(h, "open")
        for n in 0..<3 {
            items.insert(text("late\(n)", long(4), at: Double(180 + n) + 0.5), at: 180 + n)
            try await h.emit(items)
            assertNoOverlap(h, "landed \(n)")
        }
    }

    /// Random bursts: appends, removals, edits that grow or shrink a row,
    /// send-state changes, reorders (a queued send delivered into place)
    /// and a streaming reply, some landing without a settle in between.
    func test_randomBurstsNeverOverlapRows() async throws {
        var rng = SeededGenerator(seed: UInt64(ProcessInfo.processInfo.environment["BURST_SEED"] ?? "") ?? 7)
        let h = MacTimelineHarness()
        let host = ConversationLinkHost()
        var actions = MacTimelineActions.inert
        actions.linkRouting.conversationLinkHost = host
        h.controller.update(actions: actions)
        var next = 1
        var clock: Double = 0
        func make(_ own: Bool = false, _ state: TimelineSendState = .sent) -> TimelineItem {
            defer { next += 1 }
            // Some days apart, so day separators come and go.
            clock += Int.random(in: 0..<10, using: &rng) == 0 ? 40_000 : 1
            let at = clock
            let date = Date(timeIntervalSince1970: 1_700_000_000 + at)
            switch Int.random(in: 0..<8, using: &rng) {
            case 6:
                let notice = SystemNoticeEvent.parse(payload: [
                    "notice": ["summary": "Room message from another agent about the queue " + String(repeating: "and more ", count: 40),
                               "icon": "💬", "kind": "room"],
                    "body": long(2)])!
                return TimelineItem(id: "m\(next)", sender: "@bot:s", timestamp: date,
                                    kind: .systemNotice(eventID: "m\(next)", notice), isOwn: false, sendState: .sent)
            case 7:
                let live = LiveOutputEvent.parse(payload: ["command": "swift test --filter Burst\(next)",
                                                           "viewer_url": "https://example.com/live/\(next)?t=x"])!
                return TimelineItem(id: "m\(next)", sender: "@bot:s", timestamp: date,
                                    kind: .liveOutput(eventID: "m\(next)", live), isOwn: false, sendState: .sent)
            case 0:
                return TimelineItem(id: "m\(next)", sender: own ? "@me:s" : "@bot:s",
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + at),
                                    kind: .file(url: nil, filename: "voice-note-\(next).m4a", caption: nil,
                                                sizeBytes: 48_000, expired: false),
                                    isOwn: own, sendState: state)
            case 1:
                let links = (0..<Int.random(in: 1...4, using: &rng)).map { "[c\($0)](matron://convo/c\($0)-\(next % 3))" }
                return text("m\(next)", "See " + links.joined(separator: " ") + " and https://example.com/u/alice/\(next)",
                            own: own, state: state, at: at)
            default:
                let paragraphs = Int.random(in: 0...3, using: &rng)
                return text("m\(next)", paragraphs == 0 ? "Message \(next)" : long(paragraphs), own: own, state: state,
                            at: at)
            }
        }
        // Longer than the history window, so rows come and go above the
        // reader as well as at the tail.
        var items = (0..<300).map { _ in make() }
        try await h.start(with: items)
        var streaming: String?
        var dragOpen = false
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
                case 7 where Int.random(in: 0..<3, using: &rng) == 0:
                    // Conversation titles land (long ones wrap the pills).
                    let title = Bool.random(using: &rng) ? "A conversation whose title is much longer than its link" : "Short"
                    host.reset(lookup: { _ in .known(title) })
                    for i in 0..<4 { for k in 0..<3 { await host.load("c\(i)-\(k)") } }
                case 6:
                    streaming = (streaming ?? "Thinking") + (Bool.random(using: &rng) ? " more words here" : "\n\n" + long(1))
                default:
                    if let reply = streaming {
                        clock += 1; items.append(text("m\(next)", reply, at: clock))
                        next += 1
                        streaming = nil
                    }
                }
            }
            let sv = h.controller.scrollView!
            if Int.random(in: 0..<3, using: &rng) == 0 {
                // The reader nudges the trackpad while rows land, often
                // pulling past the bottom (the rubber band), and lifts a few
                // steps later.
                if !dragOpen { sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .began)); dragOpen = true }
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    let delta = Int32(Int.random(in: -60...30, using: &rng))
                    sv.scrollWheel(with: MacTimelineHarness.wheel(delta, phase: .changed))
                }
            } else if dragOpen, Bool.random(using: &rng) {
                sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .ended))
                if Bool.random(using: &rng) {
                    sv.scrollWheel(with: MacTimelineHarness.wheel(-8, phase: nil, momentum: .begin))
                    sv.scrollWheel(with: MacTimelineHarness.wheel(-4, phase: nil, momentum: .continuous))
                    sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: nil, momentum: .end))
                }
                dragOpen = false
            } else if !dragOpen, Int.random(in: 0..<10, using: &rng) == 0 {
                // The reader scrolls up a little, or back to the bottom.
                if Bool.random(using: &rng) {
                    h.controller.session.userDragBegan()
                    let y = max(0, h.clipY - CGFloat(Int.random(in: 50...400, using: &rng)))
                    h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                    h.controller.session.userScrolled(toOffset: y)
                    h.controller.session.userScrollSettled()
                } else {
                    h.controller.session.jumpToBottom()
                }
            }
            let shown = items + (streaming.map {
                [JournalTimelineMapper.streamingItem(messageRef: "r", text: $0,
                                                     convoTS: Date(timeIntervalSince1970: 1_700_000_000 + clock + 0.5))]
            } ?? [])
            h.service.emit(shown)
            if Int.random(in: 0..<3, using: &rng) == 0 {
                try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...40_000_000, using: &rng))
                continue
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                // Nothing more arrives for a while: whatever is on screen
                // now must already be right, with no help from a settle.
                try await Task.sleep(nanoseconds: 700_000_000)
                XCTAssertFalse(h.controller.hasPendingWork, "step \(step): work still pending after a quiet spell")
                assertNoOverlap(h, "step \(step) (quiet)")
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
