#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Buffers snapshots from creation: `ChatViewModel.start()` returns only
/// once the first one has been applied.
private final class StreamTimeline: TimelineService, @unchecked Sendable {
    let stream: AsyncThrowingStream<[TimelineItem], Error>
    let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { stream }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class NoMediaForSeen: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class SentOps: @unchecked Sendable {
    private let lock = NSLock(); private var ops: [ClientOp] = []
    func append(_ op: ClientOp) { lock.lock(); ops.append(op); lock.unlock() }
    var seqs: Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        var out = Set<Int64>()
        for case let .seen(_, ranges) in ops { for range in ranges { out.formUnion(range) } }
        return out
    }
}

/// Read state on the Mac SwiftUI timeline (spec 2026-09-30): row frames and
/// the viewport → the rows `SeenVisibility` counts, only while the window
/// is on screen and only for rows still in the timeline's window.
@MainActor
final class MacSeenRowsTests: XCTestCase {

    private func text(_ seq: Int) -> TimelineItem {
        TimelineItem(id: "\(seq)", sender: "matron", timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(seq)),
                     kind: .text(body: "m\(seq)", formattedHTML: nil), isOwn: false)
    }

    private static func messageIDs(_ chat: ChatViewModel) -> [String] {
        chat.windowedRows.compactMap { row in
            if case .message(let item) = row { return item.id }
            return nil
        }
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func make(_ sent: SentOps, seqs: [Int], windowVisible: Bool = true) async throws
        -> (MacSeenRows, ChatViewModel, StreamTimeline) {
        let timeline = StreamTimeline()
        // A room of its own: the view model keeps per-room state (the history
        // window) across instances.
        let chat = ChatViewModel(roomID: "!seen-\(UUID().uuidString):s", timeline: timeline, media: NoMediaForSeen())
        chat.seen = SeenTracker(dwell: .milliseconds(30), flushInterval: .milliseconds(30)) { sent.append($0) }
        timeline.continuation.yield(seqs.map(text))
        _ = await chat.start()
        await waitFor { Self.messageIDs(chat) == seqs.map(String.init) }
        XCTAssertEqual(Self.messageIDs(chat), seqs.map(String.init))

        let rows = MacSeenRows()
        rows.attach(chat, scroll: NativeScrollViewBox())
        rows.isWindowVisible = { _ in windowVisible }
        return (rows, chat, timeline)
    }

    func test_reportsTheRowsInTheViewport() async throws {
        let sent = SentOps()
        let (rows, chat, _) = try await make(sent, seqs: [1, 2, 3, 4])
        for seq in 1...4 { rows.setFrame(CGRect(x: 0, y: CGFloat(seq - 1) * 100, width: 300, height: 100), for: "\(seq)") }
        rows.setFrame(CGRect(x: 0, y: 0, width: 300, height: 20), for: "sep:1")
        // 150–340: row 2 shows exactly half (counts), row 4 only 40 of 100.
        rows.setViewport(CGRect(x: 0, y: 150, width: 300, height: 190))
        await waitFor { !sent.seqs.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.seqs, [2, 3], "1 and 4 show under half; the separator has no seq")
        rows.end()
        withExtendedLifetime(chat) {} // `MacSeenRows` holds it weakly
    }

    func test_rowsThatLeftTheWindowAreNotReported() async throws {
        let sent = SentOps()
        let (rows, chat, timeline) = try await make(sent, seqs: [1, 2])
        rows.setFrame(CGRect(x: 0, y: 0, width: 300, height: 100), for: "1")
        rows.setFrame(CGRect(x: 0, y: 100, width: 300, height: 100), for: "2")
        // Row 1 leaves the timeline, keeping its stale frame in the box.
        timeline.continuation.yield([text(2)])
        await waitFor { Self.messageIDs(chat) == ["2"] }
        rows.setViewport(CGRect(x: 0, y: 0, width: 300, height: 400))
        await waitFor { !sent.seqs.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.seqs, [2])
        rows.end()
        withExtendedLifetime(chat) {} // `MacSeenRows` holds it weakly
    }

    func test_aWindowThatIsNotOnScreenReportsNothing() async throws {
        let sent = SentOps()
        let (rows, chat, _) = try await make(sent, seqs: [1], windowVisible: false)
        rows.setFrame(CGRect(x: 0, y: 0, width: 300, height: 100), for: "1")
        rows.setViewport(CGRect(x: 0, y: 0, width: 300, height: 400))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sent.seqs.isEmpty)
        rows.end()
        withExtendedLifetime(chat) {} // `MacSeenRows` holds it weakly
    }

    /// The real gate reads the window's occlusion state; no window yet
    /// (the scroll view not captured) is not visible.
    func test_theDefaultGateNeedsAWindow() {
        XCTAssertFalse(MacSeenRows().isWindowVisible(nil))
    }

    /// Bugbot (PR 279): geometry callbacks during teardown must not report
    /// after the chat has closed.
    func test_nothingIsReportedAfterEnd() async throws {
        let sent = SentOps()
        let (rows, chat, _) = try await make(sent, seqs: [1])
        rows.end()
        rows.setFrame(CGRect(x: 0, y: 0, width: 300, height: 100), for: "1")
        rows.setViewport(CGRect(x: 0, y: 0, width: 300, height: 400))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sent.seqs.isEmpty)
        withExtendedLifetime(chat) {}
    }
}
#endif
