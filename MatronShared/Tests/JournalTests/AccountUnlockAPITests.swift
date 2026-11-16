import XCTest
import MatronModels
@testable import MatronJournal

/// Answers 401 after a pause, long enough to replace the token meanwhile.
final class SlowUnauthorizedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var authorizations: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"unauthenticated"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int] = []
    private var locks: [AccountLock] = []
    func add(_ status: Int) { lock.withLock { statuses.append(status) } }
    func add(_ accountLock: AccountLock) { lock.withLock { locks.append(accountLock) } }
    var allStatuses: [Int] { lock.withLock { statuses } }
    var allLocks: [AccountLock] { lock.withLock { locks } }
}

final class AccountUnlockAPITests: XCTestCase {
    private let approval = SignedApproval(statement: "{\"v\":1}", signature: "sig")

    private func api(status: Int = 200, body: [String: Any], heard: Heard? = nil) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://journal.example")!,
                          urlSession: URLSession(configuration: config), token: "t",
                          authResponses: { heard?.add($0) }, accountLocks: { heard?.add($0) })
    }

    func test_unlock_sendsTheApproval_andReturnsTheNewToken() async throws {
        let result = try await api(body: ["ok": true, "locked": false, "devices_revoked": 2, "token": "fresh"])
            .unlockAccount(approval: approval)
        XCTAssertEqual(result, AccountUnlockResult(token: "fresh", devicesRevoked: 2))
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/panic/unlock")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any])
        let sent = try XCTUnwrap(body["approval"] as? [String: String])
        XCTAssertEqual(sent, ["statement": "{\"v\":1}", "signature": "sig"])
    }

    func test_unlock_refusals() async {
        func refusal(_ status: Int, _ body: [String: Any]) async -> Error? {
            do { _ = try await api(status: status, body: body).unlockAccount(approval: approval); return nil } catch { return error }
        }
        let notLocked = await refusal(409, ["error": "not_locked"])
        XCTAssertEqual(notLocked as? AccountUnlockError, .notLocked)
        let required = await refusal(403, ["error": "approval_required"])
        XCTAssertEqual(required as? JournalAPIError, .approvalRequired)
        let invalid = await refusal(400, ["error": "approval_invalid", "reason": "mismatch"])
        XCTAssertEqual(invalid as? JournalAPIError, .approvalInvalid(reason: "mismatch"))
        let signedOut = await refusal(423, ["error": "account_locked", "since": 1_790_000_000_000])
        XCTAssertEqual(signedOut as? JournalAPIError, .accountLocked)
        // A success without a token is not taken as one.
        let noToken = await refusal(200, ["ok": true, "locked": false])
        XCTAssertNotNil(noToken)
    }

    func test_a423_saysWhenTheLockBegan_andWhetherThisDeviceCanUnlock() async {
        let heard = Heard()
        _ = try? await api(status: 423, body: ["error": "account_locked", "since": 1_790_000_000_000, "unlock": true],
                           heard: heard).devices()
        XCTAssertEqual(heard.allLocks, [AccountLock(since: 1_790_000_000_000, canUnlock: true)])
        let signedOut = Heard()
        _ = try? await api(status: 423, body: ["error": "account_locked", "since": 1_790_000_000_000],
                           heard: signedOut).devices()
        XCTAssertEqual(signedOut.allLocks, [AccountLock(since: 1_790_000_000_000, canUnlock: false)])
        // Anything else says nothing about a lock.
        let fine = Heard()
        _ = try? await api(body: ["devices": []], heard: fine).devices()
        XCTAssertTrue(fine.allLocks.isEmpty)
    }

    func test_aRequestOutWithAReplacedToken_isDropped_andItsAnswerNotHeard() async throws {
        let heard = Heard()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowUnauthorizedURLProtocol.self]
        SlowUnauthorizedURLProtocol.authorizations = []
        let api = JournalAPI(serverURL: URL(string: "https://journal.example")!,
                             urlSession: URLSession(configuration: config), token: "old",
                             authResponses: { heard.add($0) })
        let request = Task { try await api.devices() }
        try await Task.sleep(for: .milliseconds(100))
        await api.replaceToken("new")
        do {
            _ = try await request.value
            XCTFail("expected the request to be dropped")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .transport(JournalAPIError.cancelledDetail))
        }
        XCTAssertTrue(heard.allStatuses.isEmpty)
        // The next request carries the new token, and its answer is heard.
        _ = try? await api.devices()
        XCTAssertEqual(SlowUnauthorizedURLProtocol.authorizations, ["Bearer old", "Bearer new"])
        XCTAssertEqual(heard.allStatuses, [401])
    }

    func test_clearPanicSubject() {
        XCTAssertEqual(ApprovalSubjects.clearPanic(since: 1_790_000_000_000), ["op": "clear_panic", "since": "1790000000000"])
    }
}
