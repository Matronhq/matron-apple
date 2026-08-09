import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Local fake mirrors `FakeTimelineForChat` in `ChatViewBindingTests.swift` —
/// same lightweight per-file pattern; only `summaryEntriesStream()` is
/// exercised here.
private final class FakeTimelineForSummaries: TimelineService, @unchecked Sendable {
    var summariesToEmit: [[ConversationSummaryEntry]] = []

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}

    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        let snapshots = summariesToEmit
        return AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
}

/// No-op MediaService — these tests never resolve an image.
private final class FakeMediaForSummaries: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

final class SummariesSheetBindingTests: XCTestCase {

    @MainActor
    func test_sheet_bindsToViewModel_entriesStayNewestFirst() async throws {
        let fake = FakeTimelineForSummaries()
        let older = ConversationSummaryEntry(seq: 10, toc: "Older pass", detail: "", date: .now)
        let newer = ConversationSummaryEntry(seq: 42, toc: "Newer pass", detail: "", date: .now)
        // The journal store query orders `seq DESC` (newest first) and
        // `JournalTimelineService.summaryEntriesStream()` maps that array
        // verbatim — so a seeded fake emitting newest-first mirrors the
        // real backend's shape, and `SummariesSheet` (which lists
        // `viewModel.summaryEntries` with no re-sort) must preserve it.
        fake.summariesToEmit = [[newer, older]]

        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForSummaries())

        // Instantiating the sheet exercises its @State + binding wiring at
        // compile time, the same proof `ChatViewBindingTests` uses for
        // `ChatView` — the sheet itself isn't rendered in this unit test.
        let _ = SummariesSheet(viewModel: chatVM)

        let task = await chatVM.start()
        await task.value

        // `summaryEntriesStream()` is drained by its own unstructured task
        // inside `start()` (not the one `task.value` awaits above), so
        // poll rather than assert immediately — same pattern
        // `ChatViewModelTests.testSessionStatusSubscriptionMergesPartialFrames`
        // uses for the sibling `sessionStatus()` stream.
        for _ in 0..<200 {
            if chatVM.summaryEntries.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(chatVM.summaryEntries.map(\.seq), [42, 10],
                       "sheet lists the VM's entries verbatim, newest-first")
    }
}
