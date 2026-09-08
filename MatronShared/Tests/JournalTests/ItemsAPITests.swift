import XCTest
import MatronModels
@testable import MatronJournal

final class ItemsAPITests: XCTestCase {
    static let itemJSON: [String: Any] = [
        "id": "it_1", "user_id": 1, "num": 12, "kind": "question", "state": "open", "resolution": NSNull(),
        "awaiting": "user", "rank": 1024.0, "title": "Which auth?", "body": "A or B", "labels": ["auth"],
        "links": [["url": "https://x", "title": "issue"]],
        "attachments": [["blob_ref": "b1", "mime": "image/png", "name": "s.png", "size": 10]],
        "supersedes": NSNull(), "origin_convo_id": "c1", "origin_device_id": 3, "created_by": "agent",
        "idem_key": NSNull(), "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000, "closed_at": NSNull(),
        "comment_count": 2, "last_comment_at": 1_700_000_001_000, "has_image": 1,
    ]

    func testTrackerItemDecodes() throws {
        let item = try XCTUnwrap(TrackerItem(json: Self.itemJSON))
        XCTAssertEqual(item.id, "it_1"); XCTAssertEqual(item.num, 12); XCTAssertEqual(item.kind, .question)
        XCTAssertEqual(item.state, .open); XCTAssertNil(item.resolution); XCTAssertEqual(item.awaiting, .user)
        XCTAssertEqual(item.rank, 1024); XCTAssertEqual(item.labels, ["auth"]); XCTAssertEqual(item.links.first?.url, "https://x")
        XCTAssertEqual(item.attachments.first?.blobRef, "b1"); XCTAssertTrue(item.attachments.first!.isImage)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_700_000_000)); XCTAssertNil(item.closedAt)
        XCTAssertEqual(item.commentCount, 2); XCTAssertTrue(item.hasImage); XCTAssertTrue(item.needsUser)
        XCTAssertEqual(item.createdBy, .agent); XCTAssertEqual(item.originConvoID, "c1")
    }

    func testTrackerItemRejectsMissingKeys() {
        var bad = Self.itemJSON; bad["kind"] = "bug"
        XCTAssertNil(TrackerItem(json: bad))
        bad = Self.itemJSON; bad.removeValue(forKey: "num")
        XCTAssertNil(TrackerItem(json: bad))
    }

    func testTrackerCommentDecodesStatusMeta() throws {
        let json: [String: Any] = [
            "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "status",
            "body": "no", "attachments": [], "meta": ["from": ["state": "open", "resolution": NSNull(), "awaiting": "user"],
                                                    "to": ["state": "closed", "resolution": "reversed", "awaiting": NSNull()]],
            "idem_key": NSNull(), "created_at": 1_700_000_002_000,
        ]
        let c = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(c.kind, .status); XCTAssertEqual(c.author, .user); XCTAssertEqual(c.statusTo?.resolution, .reversed)
        XCTAssertEqual(c.statusFrom?.awaiting, .user); XCTAssertNil(c.statusTo?.awaiting)
    }

    // MARK: - JournalAPI items routes (Task 3)

    /// Builds a `JournalAPI` wired to `ItemsStubURLProtocol`, which always
    /// answers with the given status/body regardless of path — the tests
    /// below assert on the path via `recorder.lastRequest` instead.
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> (JournalAPI, ItemsStubURLProtocol.Type) {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        return (api, ItemsStubURLProtocol.self)
    }

    func testListItemsBuildsQueryAndDecodesPage() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["items": [Self.itemJSON], "next_cursor": "abc"])
        var q = ItemsListQuery(); q.convoID = "c1"; q.awaiting = .user; q.since = Date(timeIntervalSince1970: 1_700_000_000)
        let page = try await api.listItems(q)
        XCTAssertEqual(page.items.first?.num, 12); XCTAssertEqual(page.nextCursor, "abc")
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/items")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "convo", value: "c1")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "awaiting", value: "user")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "since", value: "1700000000000")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "sort", value: "rank")))
    }

    func testCreateItemAccepts201AndSendsIdempotencyKey() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["item": Self.itemJSON])
        let new = NewItem(kind: .task, title: "T", body: "b", convoID: "c1")
        let item = try await api.createItem(new, idempotencyKey: "k1")
        XCTAssertEqual(item.id, "it_1")
        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST"); XCTAssertEqual(req.value(forHTTPHeaderField: "Idempotency-Key"), "k1")
        let sent = try JSONSerialization.jsonObject(with: recorder.lastBody!) as! [String: Any]
        XCTAssertEqual(sent["kind"] as? String, "task"); XCTAssertEqual(sent["convo_id"] as? String, "c1")
    }

    func testCloseMapsConflict() async {
        let (api, _) = makeStubbedAPI(status: 409, body: ["error": "conflict"])
        do { _ = try await api.closeItem(id: "it_1", resolution: .done, comment: nil); XCTFail() }
        catch let e as JournalAPIError { XCTAssertEqual(e, .conflict) } catch { XCTFail("\(error)") }
    }

    func testItemDetailDecodesComments() async throws {
        let comment: [String: Any] = ["id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "comment", "body": "hi", "attachments": [], "meta": NSNull(), "idem_key": NSNull(), "created_at": 1_700_000_002_000]
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["item": Self.itemJSON, "comments": [comment]])
        let r = try await api.item(id: "#12")
        XCTAssertEqual(r.comments.first?.body, "hi")
        XCTAssertEqual(recorder.lastRequest?.url?.absoluteString.hasSuffix("/items/%2312"), true)
    }
}

/// Answers every request with a fixed status/body regardless of path —
/// deliberately simpler than `StubURLProtocol` (JournalAPITests.swift),
/// which keys responses per path. These tests assert on the recorded
/// request/body instead of routing different responses per path.
final class ItemsStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status: Int = 200
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = Self.readBody(of: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
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
