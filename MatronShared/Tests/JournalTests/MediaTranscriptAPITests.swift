import XCTest
@testable import MatronJournal

final class MediaTranscriptAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    func testTranscriptIsTheWordsOnlyWhenDone() async throws {
        let api = makeAPI()
        StubURLProtocol.responses = ["/media/m-1/transcript": (200, #"{"status":"done","transcript":" Merge it. "}"#)]
        let words = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertEqual(words, "Merge it.")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "wait=8")
        for body in [#"{"status":"pending"}"#, #"{"status":"none"}"#, #"{"status":"failed"}"#, #"{"status":"done","transcript":""}"#] {
            StubURLProtocol.responses = ["/media/m-1/transcript": (200, body)]
            let none = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 8)
            XCTAssertNil(none, body)
        }
        StubURLProtocol.responses = [:]   // an old journal: 404
        let old = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 99)
        XCTAssertNil(old)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "wait=30", "the journal's ceiling")
    }
}
