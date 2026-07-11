import XCTest
@testable import MatronJournal

final class StubURLProtocol: URLProtocol {
    /// path → (status, body). Set per-test; read by the loader.
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let path = request.url!.path
        let (status, body) = Self.responses[path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JournalAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config))
    }

    func testLoginSuccessStoresToken() async throws {
        StubURLProtocol.responses = ["/login": (200, #"{"token":"aabb","device_id":12,"user_id":3}"#)]
        let api = makeAPI()
        let login = try await api.login(username: "dan", password: "pw", deviceName: "mac")
        XCTAssertEqual(login.token, "aabb")
        XCTAssertEqual(login.deviceID, 12)

        StubURLProtocol.responses["/snapshot"] = (200, #"{"conversations":[],"seq":0}"#)
        _ = try await api.snapshot()
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer aabb")
    }

    func testLoginErrors() async throws {
        StubURLProtocol.responses = ["/login": (403, #"{"error":"bad_credentials"}"#)]
        let api = makeAPI()
        do {
            _ = try await api.login(username: "dan", password: "x", deviceName: "mac")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .badCredentials)
        }

        StubURLProtocol.responses = ["/login": (429, #"{"error":"locked_out","retry_after":60}"#)]
        do {
            _ = try await api.login(username: "dan", password: "x", deviceName: "mac")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .lockedOut(retryAfterSeconds: 60))
        }
    }

    func testSnapshotParsesConversations() async throws {
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[{"id":"c1","title":"T","session_state":"waiting","last_seq":9,"unread_count":2,"snippet":"s","created_at":5}],"seq":9}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertEqual(snap.seq, 9)
        XCTAssertEqual(snap.conversations, [
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "waiting", lastSeq: 9, snippet: "s", createdAt: 5),
        ])
    }

    func testMessagesBuildsQueryAndParsesEvents() async throws {
        StubURLProtocol.responses = ["/convo/c1/messages": (200, """
            {"events":[{"seq":8,"convo_id":"c1","ts":8000,"sender":"agent:a","type":"text","payload":{"body":"m8"}}]}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let events = try await api.messages(convoID: "c1", beforeSeq: 9, limit: 30)
        XCTAssertEqual(events.map(\.seq), [8])
        let query = StubURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("before_seq=9"))
        XCTAssertTrue(query.contains("limit=30"))
    }

    func testUnauthenticatedMapsToError() async throws {
        StubURLProtocol.responses = ["/snapshot": (401, #"{"error":"unauthenticated"}"#)]
        let api = makeAPI()
        do {
            _ = try await api.snapshot()
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .unauthenticated)
        }
    }

    func testWsURL() {
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!)
        XCTAssertEqual(api.wsURL.absoluteString, "wss://chat.example.com/ws")
    }

    func testMessagesEscapesConvoIDSegment() async throws {
        StubURLProtocol.responses = ["/convo/c 1/x/messages": (200, #"{"events":[]}"#)]
        let api = makeAPI()
        await api.setToken("t")
        _ = try await api.messages(convoID: "c 1/x", beforeSeq: nil, limit: 10)
        let url = StubURLProtocol.lastRequest?.url
        XCTAssertTrue(url?.absoluteString.contains("/convo/c%201%2Fx/messages") ?? false)
    }

    func testRegisterAPNsTokenSwallowsNotFound() async throws {
        StubURLProtocol.responses = ["/devices/apns": (404, #"{"error":"not_found"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        try await api.registerAPNsToken("aabbcc") // must NOT throw
    }

    func testMediaDataReturnsBytes() async throws {
        StubURLProtocol.responses = ["/media/b1": (200, "PNGDATA")]
        let api = makeAPI()
        await api.setToken("t")
        let data = try await api.mediaData(blobRef: "b1")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PNGDATA")
    }
}
