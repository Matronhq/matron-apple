import XCTest
@testable import MatronChat

/// Test-only fake. Plain `final class` (not `actor`) so `items()` can
/// synthesise a finite AsyncStream synchronously without needing
/// `nonisolated` accessors. Tests are single-threaded; mutable storage
/// is unguarded for that reason — same pattern as `FakeChatService`
/// and `FakeAuthService`.
final class FakeTimelineService: TimelineService, @unchecked Sendable {
    var snapshotsToEmit: [[TimelineItem]] = []
    /// When non-nil, `items()` finishes by throwing this error after
    /// yielding all queued snapshots. Lets tests pin the error-flow
    /// added in QA finding #10.
    var streamError: Error?
    var sentText: [String] = []
    var sentImages: [(filename: String, mime: String, sizeBytes: Int)] = []
    var sentFiles: [(filename: String, mime: String, sizeBytes: Int)] = []
    var paginateCalls: Int = 0
    var markReadCalls: Int = 0

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        let snapshots = snapshotsToEmit
        let err = streamError
        return AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            if let err {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }

    func sendText(_ body: String) async throws {
        sentText.append(body)
    }
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        sentImages.append((filename, mimeType, data.count))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        sentFiles.append((filename, mimeType, data.count))
    }
    func paginateBackward(requestSize: UInt16) async throws -> Bool {
        paginateCalls += 1
        return false
    }
    func markAsRead() async throws {
        markReadCalls += 1
    }
}

final class TimelineServiceFakeTests: XCTestCase {
    func test_streamsSnapshotsInOrder() async throws {
        let fake = FakeTimelineService()
        let t0 = Date(timeIntervalSince1970: 0)
        fake.snapshotsToEmit = [
            [TimelineItem(id: "1", sender: "@a:s", timestamp: t0, kind: .text(body: "hi", formattedHTML: nil), isOwn: true)],
            [
                TimelineItem(id: "1", sender: "@a:s", timestamp: t0, kind: .text(body: "hi", formattedHTML: nil), isOwn: true),
                TimelineItem(id: "2", sender: "@b:s", timestamp: t0, kind: .text(body: "hello", formattedHTML: nil), isOwn: false),
            ],
        ]
        var received: [[TimelineItem]] = []
        for try await snap in fake.items() { received.append(snap) }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].count, 1)
        XCTAssertEqual(received[1].count, 2)
    }

    func test_sendText_recordsCalls() async throws {
        let fake = FakeTimelineService()
        try await fake.sendText("/start")
        try await fake.sendText("hello")
        XCTAssertEqual(fake.sentText, ["/start", "hello"])
    }

    func test_sendImage_recordsFilenameMimeAndSize() async throws {
        let fake = FakeTimelineService()
        let data = Data(repeating: 0xAB, count: 42)
        try await fake.sendImage(data, filename: "pic.png", mimeType: "image/png")
        XCTAssertEqual(fake.sentImages.count, 1)
        XCTAssertEqual(fake.sentImages[0].filename, "pic.png")
        XCTAssertEqual(fake.sentImages[0].mime, "image/png")
        XCTAssertEqual(fake.sentImages[0].sizeBytes, 42)
    }

    func test_sendFile_recordsFilenameMimeAndSize() async throws {
        let fake = FakeTimelineService()
        let data = Data(repeating: 0x01, count: 7)
        try await fake.sendFile(data, filename: "report.pdf", mimeType: "application/pdf")
        XCTAssertEqual(fake.sentFiles.count, 1)
        XCTAssertEqual(fake.sentFiles[0].filename, "report.pdf")
        XCTAssertEqual(fake.sentFiles[0].mime, "application/pdf")
        XCTAssertEqual(fake.sentFiles[0].sizeBytes, 7)
    }

    func test_paginateBackward_andMarkAsRead_recordCalls() async throws {
        let fake = FakeTimelineService()
        try await fake.paginateBackward(requestSize: 20)
        try await fake.paginateBackward(requestSize: 20)
        try await fake.markAsRead()
        XCTAssertEqual(fake.paginateCalls, 2)
        XCTAssertEqual(fake.markReadCalls, 1)
    }
}
