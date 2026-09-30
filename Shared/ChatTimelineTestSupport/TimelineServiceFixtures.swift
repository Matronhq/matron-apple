import XCTest
import MatronChat
import MatronModels
import MatronViewModels

/// A `TimelineService` whose snapshots the test pushes live (`emit`), so the
/// view model behaves exactly as with the journal: first snapshot returns
/// `start()`, later ones commit (coalesced ≤ 250ms).
final class LiveTimelineFixture: TimelineService, @unchecked Sendable {
    private let stream: AsyncThrowingStream<[TimelineItem], Error>
    private let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream<[TimelineItem], Error>.makeStream()
    }

    func emit(_ items: [TimelineItem]) { continuation.yield(items) }

    func items() -> AsyncThrowingStream<[TimelineItem], Error> { stream }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

final class NoMediaFixture: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

final class NoChildrenChatFixture: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

enum TimelineFixtures {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Item ids are numeric strings — journal seqs — so `focus(seq:)` works.
    static func text(_ index: Int, own: Bool = false, body: String? = nil) -> TimelineItem {
        TimelineItem(id: "\(index)", sender: own ? "@me:s" : "matron",
                     timestamp: base.addingTimeInterval(TimeInterval(index * 60)),
                     kind: .text(body: body ?? "Message \(index). "
                                    + String(repeating: "Lorem ipsum dolor sit amet. ", count: index % 4 + 1),
                                 formattedHTML: nil),
                     isOwn: own)
    }

    static func streaming(_ ref: String, body: String) -> TimelineItem {
        TimelineItem(id: "eph:\(ref)", sender: "agent", timestamp: base.addingTimeInterval(1_000_000),
                     kind: .text(body: body, formattedHTML: nil), isOwn: false)
    }

    static func activity(_ label: String) -> TimelineItem {
        TimelineItem(id: "activity", sender: "agent", timestamp: base.addingTimeInterval(2_000_000),
                     kind: .activityIndicator(label: label), isOwn: false)
    }

    static func conversation(_ count: Int) -> [TimelineItem] {
        (1...count).map { text($0, own: $0 % 5 == 0) }
    }

    @MainActor
    static func viewModel(_ service: LiveTimelineFixture, roomID: String = "!timeline:test") -> ChatViewModel {
        ChatViewModel(roomID: roomID, timeline: service, media: NoMediaFixture())
    }
}

/// Spins the main run loop (display links, dispatch) until `condition`.
@MainActor
func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
