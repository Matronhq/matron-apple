import XCTest
@testable import MatronJournal

final class StubURLProtocol: URLProtocol {
    /// path → (status, body). Set per-test; read by the loader.
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// Recorded body of the last request, read from `httpBody` when present
    /// and falling back to draining `httpBodyStream` otherwise (URLSession
    /// sometimes only populates the stream form for the loaded request).
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = Self.body(of: request)
        let path = request.url!.path
        let (status, body) = Self.responses[path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
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
            {"conversations":[{"id":"c1","title":"T","session_state":"waiting","last_seq":9,"unread_count":2,"snippet":"s","created_at":5,"last_ts":7000}],"seq":9}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertEqual(snap.seq, 9)
        XCTAssertEqual(snap.conversations, [
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "waiting", lastSeq: 9, snippet: "s", createdAt: 5, lastTS: 7000),
        ])
    }

    func testSnapshotToleratesMissingLastTS() async throws {
        // Older servers (and convos with no events) omit/null last_ts.
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[{"id":"c1","title":"T","session_state":"waiting","last_seq":9,"unread_count":2,"snippet":"s","created_at":5}],"seq":9}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertNil(snap.conversations.first?.lastTS)
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

    func testTokenPassedAtInitIsUsedWithoutSetToken() async throws {
        StubURLProtocol.responses = ["/snapshot": (200, #"{"conversations":[],"seq":0}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config),
                             token: "t0")
        _ = try await api.snapshot()
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t0")
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

    func testRegisterPushPostsTokenAndEnvironment() async throws {
        StubURLProtocol.responses = ["/push/register": (200, #"{"ok":true}"#)]
        let api = makeAPI()
        await api.setToken("t")
        try await api.registerPush(tokenHex: "aabbcc", environment: .sandbox)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/push/register")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["apns_token"] as? String, "aabbcc")
        XCTAssertEqual(obj["environment"] as? String, "sandbox")
    }

    func testUnregisterPushSendsNullToken() async throws {
        StubURLProtocol.responses = ["/push/register": (200, #"{"ok":true}"#)]
        let api = makeAPI()
        await api.setToken("t")
        try await api.unregisterPush()
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(obj["apns_token"] is NSNull)
    }

    func testMediaDataReturnsBytes() async throws {
        StubURLProtocol.responses = ["/media/b1": (200, "PNGDATA")]
        let api = makeAPI()
        await api.setToken("t")
        let data = try await api.mediaData(blobRef: "b1")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PNGDATA")
    }

    // MARK: Path-prefix preservation (bugbot "Homeserver path prefix dropped")

    func testServerPathPrefixIsPreservedOnRequests() async throws {
        StubURLProtocol.responses = ["/matron/snapshot": (200, #"{"conversations":[],"seq":0}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com/matron")!,
                             urlSession: URLSession(configuration: config))
        await api.setToken("t")
        _ = try await api.snapshot()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/matron/snapshot",
                       "endpoint paths must append to the server URL's prefix, not replace it")
    }

    func testServerPathPrefixTrailingSlashNormalized() async throws {
        StubURLProtocol.responses = ["/matron/snapshot": (200, #"{"conversations":[],"seq":0}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com/matron/")!,
                             urlSession: URLSession(configuration: config))
        await api.setToken("t")
        _ = try await api.snapshot()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/matron/snapshot")
    }

    func testWSURLKeepsPathPrefix() {
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com/matron")!)
        XCTAssertEqual(api.wsURL.absoluteString, "wss://chat.example.com/matron/ws")
        let bare = JournalAPI(serverURL: URL(string: "http://localhost:8787")!)
        XCTAssertEqual(bare.wsURL.absoluteString, "ws://localhost:8787/ws")
    }
}
