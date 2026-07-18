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

    func testSnapshotParsesParentConvoID() async throws {
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[\
            {"id":"p1","title":"Parent","session_state":"running","last_seq":5,"snippet":"","created_at":1,"parent_convo_id":null},\
            {"id":"p1:sub:a1","title":"child","session_state":"done","last_seq":6,"snippet":"","created_at":2,"parent_convo_id":"p1"}\
            ],"seq":6}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertNil(snap.conversations.first(where: { $0.id == "p1" })?.parentConvoID)
        XCTAssertEqual(snap.conversations.first(where: { $0.id == "p1:sub:a1" })?.parentConvoID, "p1")
    }

    func testSnapshotToleratesMissingParentConvoID() async throws {
        // Older server: no parent_convo_id field at all → nil, treated top-level.
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[{"id":"c1","title":"T","session_state":"running","last_seq":1,"snippet":"","created_at":0}],"seq":1}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertNil(snap.conversations.first?.parentConvoID)
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

    func testUploadMediaPostsRawBytesAndReturnsMediaID() async throws {
        StubURLProtocol.responses = ["/media": (200, #"{"media_id":"m-123","size":3,"content_type":"image/png","sha256":"ab"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        let mediaID = try await api.uploadMedia(Data("PNG".utf8), contentType: "image/png")
        XCTAssertEqual(mediaID, "m-123")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/media")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        // The bytes ride verbatim as the raw request body (not JSON-wrapped).
        XCTAssertEqual(StubURLProtocol.lastRequestBody, Data("PNG".utf8))
    }

    func testUploadMediaMapsErrorStatus() async throws {
        StubURLProtocol.responses = ["/media": (401, #"{"error":"unauthenticated"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        do {
            _ = try await api.uploadMedia(Data("x".utf8), contentType: "application/octet-stream")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .unauthenticated)
        }
    }

    // MARK: Devices + pairing (journal PR #19 spec)

    func testDevicesDecodesRosterIncludingNulls() async throws {
        StubURLProtocol.responses = ["/devices": (200, #"""
        {"devices":[
          {"device_id":7,"kind":"client","name":"dan-mac","created_at":1784000000000,
           "cursor":5123,"lag":0,"last_seen_at":1784500000000,"is_self":true,"connected":true},
          {"device_id":9,"kind":"agent","name":"dev-7","created_at":1784100000000,
           "cursor":5000,"lag":123,"last_seen_at":null,"is_self":false}
        ]}
        """#)]
        let api = makeAPI()
        await api.setToken("t")
        let devices = try await api.devices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0], DeviceDTO(id: 7, kind: "client", name: "dan-mac",
                                             createdAt: 1_784_000_000_000, cursor: 5123, lag: 0,
                                             lastSeenAt: 1_784_500_000_000, isSelf: true, connected: true))
        XCTAssertEqual(devices[1].lastSeenAt, nil, "last_seen_at:null must decode as nil (never connected)")
        XCTAssertFalse(devices[1].isSelf)
        XCTAssertFalse(devices[1].connected, "absent connected key (older server) must decode as false")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testRevokeDevicePostsToScopedPath() async throws {
        StubURLProtocol.responses = ["/devices/7/revoke": (200, #"{"ok":true}"#)]
        let api = makeAPI()
        await api.setToken("t")
        try await api.revokeDevice(id: 7)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/devices/7/revoke")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testRevokeDeviceMapsNotFound() async throws {
        StubURLProtocol.responses = ["/devices/9/revoke": (404, #"{"error":"not_found"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        do {
            try await api.revokeDevice(id: 9)
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPairPreviewSendsCodeAndDecodes() async throws {
        StubURLProtocol.responses = ["/pair/preview": (200, #"{"requester_ip":"65.108.10.252","expires_in":412}"#)]
        let api = makeAPI()
        await api.setToken("t")
        let preview = try await api.pairPreview(code: "KTNM3VQ8")
        XCTAssertEqual(preview, PairPreview(requesterIP: "65.108.10.252", expiresIn: 412))
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["pair_code"] as? String, "KTNM3VQ8")
    }

    func testPairApproveSendsCodeAndName() async throws {
        StubURLProtocol.responses = ["/pair/approve": (200, #"{"status":"approved"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        try await api.pairApprove(code: "KTNM3VQ8", agentName: "dev-7")
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["pair_code"] as? String, "KTNM3VQ8")
        XCTAssertEqual(obj["agent_name"] as? String, "dev-7")
    }

    func testPairApproveMapsConflict() async throws {
        StubURLProtocol.responses = ["/pair/approve": (409, #"{"error":"conflict"}"#)]
        let api = makeAPI()
        await api.setToken("t")
        do {
            try await api.pairApprove(code: "KTNM3VQ8", agentName: "dev-7")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .conflict, "409 must map to the dedicated conflict case (already approved)")
        }
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

    // MARK: Device link (QR sign-in)

    func testLinkStartParsesResponse() async throws {
        StubURLProtocol.responses = ["/link/start": (200, #"{"link_code":"KTNM-3VQ8","expires_in":120}"#)]
        let api = makeAPI()
        await api.setToken("tok")
        let started = try await api.linkStart()
        XCTAssertEqual(started, LinkStart(code: "KTNM-3VQ8", expiresIn: 120))
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testLinkStatusWaitingAndClaimed() async throws {
        let api = makeAPI()
        StubURLProtocol.responses = ["/link/status": (200, #"{"status":"waiting","expires_in":90}"#)]
        let waiting = try await api.linkStatus()
        XCTAssertEqual(waiting, .waiting(expiresIn: 90))
        StubURLProtocol.responses = ["/link/status": (200, #"{"status":"claimed","device_name":"Pixel 9","requester_ip":"198.51.100.7","expires_in":55}"#)]
        let claimed = try await api.linkStatus()
        XCTAssertEqual(claimed,
                       .claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7", expiresIn: 55))
    }

    func testLinkApproveAndDenySendCode() async throws {
        let api = makeAPI()
        StubURLProtocol.responses = ["/link/approve": (200, #"{"status":"approved"}"#)]
        try await api.linkApprove(code: "KTNM-3VQ8")
        var body = try JSONSerialization.jsonObject(with: StubURLProtocol.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["link_code"] as? String, "KTNM-3VQ8")
        StubURLProtocol.responses = ["/link/deny": (200, #"{"status":"denied"}"#)]
        try await api.linkDeny(code: "KTNM-3VQ8")
        body = try JSONSerialization.jsonObject(with: StubURLProtocol.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["link_code"] as? String, "KTNM-3VQ8")
    }

    func testLinkClaimSendsBodyUnauthenticatedAndParses() async throws {
        StubURLProtocol.responses = ["/link/claim": (200, #"{"status":"claimed","claim_token":"aa11","expires_in":60}"#)]
        let api = makeAPI()
        await api.setToken("tok") // must NOT be sent: claim is the unauthenticated side
        let claim = try await api.linkClaim(code: "KTNM-3VQ8", deviceName: "Matron iOS")
        XCTAssertEqual(claim, LinkClaim(claimToken: "aa11", expiresIn: 60))
        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: StubURLProtocol.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["link_code"] as? String, "KTNM-3VQ8")
        XCTAssertEqual(body?["device_name"] as? String, "Matron iOS")
    }

    func testLinkPollPendingDeniedApproved() async throws {
        let api = makeAPI()
        StubURLProtocol.responses = ["/link/poll": (200, #"{"status":"pending"}"#)]
        let pending = try await api.linkPoll(claimToken: "aa11")
        XCTAssertEqual(pending, .pending)
        StubURLProtocol.responses = ["/link/poll": (200, #"{"status":"denied"}"#)]
        let denied = try await api.linkPoll(claimToken: "aa11")
        XCTAssertEqual(denied, .denied)
        StubURLProtocol.responses = ["/link/poll": (200,
            #"{"status":"approved","token":"bb22","device_id":42,"user_id":7,"username":"dan"}"#)]
        let approved = try await api.linkPoll(claimToken: "aa11")
        XCTAssertEqual(approved,
                       .approved(LinkApproval(token: "bb22", deviceID: 42, userID: 7, username: "dan")))
    }

    func testLinkPollApprovedWithoutUsernameIsMalformed() async throws {
        // username is load-bearing (it becomes UserSession.userID) — a server
        // that omits it must fail loudly, not sign in with a garbage identity.
        StubURLProtocol.responses = ["/link/poll": (200,
            #"{"status":"approved","token":"bb22","device_id":42,"user_id":7}"#)]
        let api = makeAPI()
        do {
            _ = try await api.linkPoll(claimToken: "aa11")
            XCTFail("expected transport error")
        } catch JournalAPIError.transport { /* expected */ }
    }
}
