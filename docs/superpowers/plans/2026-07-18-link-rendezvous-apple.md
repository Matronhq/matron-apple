# Link Rendezvous — Apple (iOS + Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signed-out Macs (and iPhones) can SHOW a rendezvous QR that a signed-in phone scans; the signed-in Settings → Link a Device screen gains a Scan tab that completes the hand-off; the approve-card copy is sharpened.

**Architecture:** A new `RendezvousURI` payload format and `RelayClient` (talking to the shared relay at `https://push.matron.chat`) live in `MatronShared/Sources/Journal`. A new `RendezvousSignInViewModel` wraps rendezvous create/poll and then delegates to the existing `LinkSignInViewModel` (whose claim → poll → persist flow is untouched). The Settings side reuses the live `DeviceLinkViewModel` session — its code already exists when the screen is open — adding one `offerScanned` method. All new VMs use the established generation-guard pattern.

**Tech Stack:** Swift / SwiftUI, SwiftPM package `MatronShared` (VMs are SwiftUI-free), XCTest with scriptable fakes and CheckedContinuation gates.

**Spec:** `matron-journal:docs/superpowers/specs/2026-07-18-link-rendezvous-design.md` (approved). The server-side plan (relay endpoints) is `matron-journal:docs/superpowers/plans/2026-07-18-link-rendezvous-server.md` — the wire contract used below comes from there.

## Global Constraints

- Work in the worktree `/Users/danbarker/Dev/matron-apple-linklogin` on branch `feat/link-rendezvous` (create from `origin/main` if it doesn't exist: `git switch -c feat/link-rendezvous origin/main`). NEVER touch `/Users/danbarker/Dev/matron-apple` (it holds an unrelated branch).
- Shared-package tests: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`. App builds need `xcodegen generate` first, then `xcodebuild -project Matron.xcodeproj -scheme <Matron|MatronMac> build CODE_SIGNING_ALLOWED=NO` (tests: replace `build` with `test -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'` / `-destination 'platform=macOS'`, env `MATRON_SKIP_SNAPSHOT_TESTS=1 TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1`).
- Relay base URL is the hardcoded constant `https://push.matron.chat` (forks edit the constant). No UI override.
- Relay wire contract (server plan Task 2): `POST /link/rendezvous` (empty body) → `201 {rid, secret, expires_in}`; `GET /link/rendezvous/<rid>?secret=<hex>` → 204 waiting | `200 {server, code}` | 403 | 404 | 429; `POST /link/rendezvous/<rid>/offer` `{server, code}` → 204 | 409 | 404 | 400 | 429. `code` comes back dashed (`XXXX-XXXX`).
- QR payload: `matron://rlink?v=1&rid=<rid>`; `rid` is exactly 26 chars of `0123456789BCDFGHJKMNPQRSTVWXYZ`. Unknown version → the existing copy `"This QR code needs a newer version of Matron."`.
- Sharpened approve copy (all platforms, replaces the current footnote verbatim): `This signs a computer into **your** account — only approve if it's yours, in front of you.`
- Show-tab caption: `Scan this with a phone that's signed in to Matron`. Connecting copy: `Connecting to <server host>…`.
- Generation-guard every new async flow exactly like `DeviceLinkViewModel`/`LinkSignInViewModel` (snapshot `generation`, bump in `stop()`/`cancel()`, re-check after EVERY await before any state write).
- Mac has no camera: Mac gets the Show side only. Scan stays iOS-only.
- Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: `RendezvousURI` payload format

**Files:**
- Create: `MatronShared/Sources/Journal/RendezvousURI.swift`
- Test: `MatronShared/Tests/JournalTests/RendezvousURITests.swift`

**Interfaces:**
- Produces (used by Tasks 3, 4): `RendezvousURI.format(rid: String) -> String`, `RendezvousURI.parse(_ raw: String) throws -> String` (returns the rid), `RendezvousURI.ParseError { notALink, unsupportedVersion, malformed }`.

- [ ] **Step 1: Write failing tests**

Create `MatronShared/Tests/JournalTests/RendezvousURITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class RendezvousURITests: XCTestCase {
    private let rid = "23456789BCDFGHJKMNPQRSTVWX" // 26 chars, all in alphabet

    func test_format_roundTripsThroughParse() throws {
        let uri = RendezvousURI.format(rid: rid)
        XCTAssertEqual(uri, "matron://rlink?v=1&rid=\(rid)")
        XCTAssertEqual(try RendezvousURI.parse(uri), rid)
    }

    func test_parse_rejectsNonRlinkPayloads_asNotALink() {
        for raw in ["https://example.com", "matron://link?v=1&server=x&code=ABCD-2345", "random text", ""] {
            XCTAssertThrowsError(try RendezvousURI.parse(raw)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .notALink, raw)
            }
        }
    }

    func test_parse_futureVersion_isUnsupported_butMissingVersionIsMalformed() {
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?v=2&rid=\(rid)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?rid=\(rid)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .malformed)
        }
    }

    func test_parse_ridShapeIsEnforced() {
        for bad in [
            "matron://rlink?v=1",                                  // missing rid
            "matron://rlink?v=1&rid=SHORT",                        // wrong length
            "matron://rlink?v=1&rid=\(String(repeating: "A", count: 26))", // A not in alphabet
            "matron://rlink?v=1&rid=\(rid)X",                      // 27 chars
        ] {
            XCTAssertThrowsError(try RendezvousURI.parse(bad)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .malformed, bad)
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RendezvousURITests`
Expected: FAIL — `cannot find 'RendezvousURI' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Journal/RendezvousURI.swift`:

```swift
import Foundation

/// The rendezvous QR payload — the single place the format is known:
/// `matron://rlink?v=1&rid=<26-char rid>`. The reverse of `LinkURI`: this QR
/// is SHOWN by a signed-out device and SCANNED by a signed-in phone. It
/// carries only the rendezvous id — never the poll secret, never a server.
/// Android carries an equivalent parser; the relay never sees the URI.
public enum RendezvousURI {
    public enum ParseError: Error, Equatable {
        /// Not ours at all — scanner shows "Not a Matron link code."
        case notALink
        /// Ours, but a future version — scanner shows "update the app".
        case unsupportedVersion
        /// Ours and v=1, but the rid doesn't parse.
        case malformed
    }

    private static let prefix = "matron://rlink?"
    // Same alphabet as PairingCode / link codes; 26 chars ≈ 128 bits.
    private static let ridPattern = "^[0-9BCDFGHJKMNPQRSTVWXYZ]{26}$"

    public static func format(rid: String) -> String {
        "\(prefix)v=1&rid=\(rid)" // rid alphabet needs no percent-encoding
    }

    public static func parse(_ raw: String) throws -> String {
        guard raw.hasPrefix(prefix) else { throw ParseError.notALink }
        var params: [String: String] = [:]
        for pair in raw.dropFirst(prefix.count).split(separator: "&") {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            params[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                .removingPercentEncoding ?? ""
        }
        guard let version = params["v"] else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let rid = params["rid"], rid.range(of: ridPattern, options: .regularExpression) != nil else {
            throw ParseError.malformed
        }
        return rid
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RendezvousURITests` — Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/RendezvousURI.swift MatronShared/Tests/JournalTests/RendezvousURITests.swift
git commit -m "Add RendezvousURI payload format

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `RelayClient`

**Files:**
- Create: `MatronShared/Sources/Journal/RelayClient.swift`
- Test: `MatronShared/Tests/JournalTests/RelayClientTests.swift`

**Interfaces:**
- Produces (used by Tasks 3, 4):

```swift
public enum MatronRelay { public static let baseURL: URL } // https://push.matron.chat

public struct Rendezvous: Equatable, Sendable { public let rid: String; public let secret: String; public let expiresIn: Int }
public enum RendezvousPollResult: Equatable, Sendable { case waiting; case offered(server: String, code: String) }
public enum RelayError: Error, Equatable { case notFound, conflict, forbidden, rateLimited, transport(String) }

public protocol RelayRendezvousing: Sendable {
    func createRendezvous() async throws -> Rendezvous
    func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult
    func offerRendezvous(rid: String, server: String, code: String) async throws
}

public struct RelayClient: RelayRendezvousing {
    public init(baseURL: URL = MatronRelay.baseURL, urlSession: URLSession = .shared)
}
```

- [ ] **Step 1: Write failing tests** (the response mappers are pure functions — test those; the URLSession glue is a thin pass-through)

Create `MatronShared/Tests/JournalTests/RelayClientTests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class RelayClientTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_mapCreate_parses201() throws {
        let r = try RelayClient.mapCreate(status: 201, data: data(
            #"{"rid":"23456789BCDFGHJKMNPQRSTVWX","secret":"\#(String(repeating: "a", count: 64))","expires_in":180}"#))
        XCTAssertEqual(r, Rendezvous(rid: "23456789BCDFGHJKMNPQRSTVWX",
                                     secret: String(repeating: "a", count: 64), expiresIn: 180))
    }

    func test_mapCreate_errors() {
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 429, data: data(#"{"status":429,"reason":"rate_limited"}"#))) {
            XCTAssertEqual($0 as? RelayError, .rateLimited)
        }
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 201, data: data(#"{"nope":true}"#))) {
            XCTAssertEqual($0 as? RelayError, .transport("malformed relay response"))
        }
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 500, data: Data())) {
            XCTAssertEqual($0 as? RelayError, .transport("HTTP 500"))
        }
    }

    func test_mapPoll_coversAllStates() throws {
        XCTAssertEqual(try RelayClient.mapPoll(status: 204, data: Data()), .waiting)
        XCTAssertEqual(try RelayClient.mapPoll(status: 200, data: data(#"{"server":"https://j.example.com","code":"2345-6789"}"#)),
                       .offered(server: "https://j.example.com", code: "2345-6789"))
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 404, data: Data())) { XCTAssertEqual($0 as? RelayError, .notFound) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 403, data: Data())) { XCTAssertEqual($0 as? RelayError, .forbidden) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 429, data: Data())) { XCTAssertEqual($0 as? RelayError, .rateLimited) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 200, data: data(#"{"server":"https://x"}"#))) {
            XCTAssertEqual($0 as? RelayError, .transport("malformed relay response"))
        }
    }

    func test_mapOffer_coversAllStates() throws {
        XCTAssertNoThrow(try RelayClient.mapOffer(status: 204))
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 409)) { XCTAssertEqual($0 as? RelayError, .conflict) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 404)) { XCTAssertEqual($0 as? RelayError, .notFound) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 429)) { XCTAssertEqual($0 as? RelayError, .rateLimited) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 400)) { XCTAssertEqual($0 as? RelayError, .transport("HTTP 400")) }
    }

    func test_requestBuilders_hitTheDocumentedPathsAndBodies() throws {
        let base = URL(string: "https://push.matron.chat")!
        let create = RelayClient.createRequest(baseURL: base)
        XCTAssertEqual(create.url?.absoluteString, "https://push.matron.chat/link/rendezvous")
        XCTAssertEqual(create.httpMethod, "POST")

        let poll = RelayClient.pollRequest(baseURL: base, rid: "RID", secret: "SEC")
        XCTAssertEqual(poll.url?.absoluteString, "https://push.matron.chat/link/rendezvous/RID?secret=SEC")
        XCTAssertEqual(poll.httpMethod, "GET")

        let offer = RelayClient.offerRequest(baseURL: base, rid: "RID", server: "https://j.example.com", code: "2345-6789")
        XCTAssertEqual(offer.url?.absoluteString, "https://push.matron.chat/link/rendezvous/RID/offer")
        XCTAssertEqual(offer.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: offer.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["server": "https://j.example.com", "code": "2345-6789"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RelayClientTests`
Expected: FAIL — `cannot find 'RelayClient' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Journal/RelayClient.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one shared piece of Matron infrastructure. Forks: change this constant.
public enum MatronRelay {
    public static let baseURL = URL(string: "https://push.matron.chat")!
}

public struct Rendezvous: Equatable, Sendable {
    public let rid: String
    public let secret: String
    public let expiresIn: Int
    public init(rid: String, secret: String, expiresIn: Int) {
        self.rid = rid; self.secret = secret; self.expiresIn = expiresIn
    }
}

public enum RendezvousPollResult: Equatable, Sendable {
    case waiting
    case offered(server: String, code: String)
}

public enum RelayError: Error, Equatable {
    case notFound      // unknown/expired rendezvous — regenerate
    case conflict      // someone offered first
    case forbidden     // secret mismatch (should never happen for the creator)
    case rateLimited
    case transport(String)
}

/// Talks to the shared relay's rendezvous endpoints. Unauthenticated by
/// design — the relay carries only {server, code}, never a token, and the
/// approve tap on the signed-in phone remains the only credential gate.
public protocol RelayRendezvousing: Sendable {
    func createRendezvous() async throws -> Rendezvous
    func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult
    func offerRendezvous(rid: String, server: String, code: String) async throws
}

public struct RelayClient: RelayRendezvousing {
    let baseURL: URL
    let urlSession: URLSession

    public init(baseURL: URL = MatronRelay.baseURL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func createRendezvous() async throws -> Rendezvous {
        let (data, status) = try await send(Self.createRequest(baseURL: baseURL))
        return try Self.mapCreate(status: status, data: data)
    }

    public func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult {
        let (data, status) = try await send(Self.pollRequest(baseURL: baseURL, rid: rid, secret: secret))
        return try Self.mapPoll(status: status, data: data)
    }

    public func offerRendezvous(rid: String, server: String, code: String) async throws {
        let (_, status) = try await send(Self.offerRequest(baseURL: baseURL, rid: rid, server: server, code: code))
        try Self.mapOffer(status: status)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RelayError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.transport("not HTTP") }
        return (data, http.statusCode)
    }

    // MARK: - Pure request builders / response mappers (unit-tested)

    static func createRequest(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("link/rendezvous"))
        request.httpMethod = "POST"
        return request
    }

    static func pollRequest(baseURL: URL, rid: String, secret: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("link/rendezvous/\(rid)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        return URLRequest(url: components.url!)
    }

    static func offerRequest(baseURL: URL, rid: String, server: String, code: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("link/rendezvous/\(rid)/offer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["server": server, "code": code])
        return request
    }

    static func mapCreate(status: Int, data: Data) throws -> Rendezvous {
        try mapError(status, success: 201)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = obj["rid"] as? String,
              let secret = obj["secret"] as? String,
              let expiresIn = obj["expires_in"] as? Int else {
            throw RelayError.transport("malformed relay response")
        }
        return Rendezvous(rid: rid, secret: secret, expiresIn: expiresIn)
    }

    static func mapPoll(status: Int, data: Data) throws -> RendezvousPollResult {
        if status == 204 { return .waiting }
        try mapError(status, success: 200)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = obj["server"] as? String,
              let code = obj["code"] as? String else {
            throw RelayError.transport("malformed relay response")
        }
        return .offered(server: server, code: code)
    }

    static func mapOffer(status: Int) throws {
        try mapError(status, success: 204)
    }

    private static func mapError(_ status: Int, success: Int) throws {
        switch status {
        case success: return
        case 404: throw RelayError.notFound
        case 409: throw RelayError.conflict
        case 403: throw RelayError.forbidden
        case 429: throw RelayError.rateLimited
        default: throw RelayError.transport("HTTP \(status)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RelayClientTests` — Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/RelayClient.swift MatronShared/Tests/JournalTests/RelayClientTests.swift
git commit -m "Add RelayClient for the shared rendezvous relay

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `RendezvousSignInViewModel` (signed-out Show side)

**Files:**
- Create: `MatronShared/Sources/ViewModels/RendezvousSignInViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/RendezvousSignInViewModelTests.swift`

**Interfaces:**
- Consumes: `RelayRendezvousing`, `Rendezvous`, `RendezvousPollResult`, `RelayError`, `RendezvousURI` (Tasks 1–2); the existing `LinkSignInViewModel` (its `serverURL`/`codeInput` vars and `submitManual()` — untouched).
- Produces (used by Tasks 5, 6):

```swift
@Observable @MainActor public final class RendezvousSignInViewModel {
    public enum Phase: Equatable { case idle, loading, showing(qrPayload: String), connecting(serverHost: String), error(String) }
    public private(set) var phase: Phase
    public init(relay: any RelayRendezvousing, link: LinkSignInViewModel,
                pollInterval: Duration = .seconds(2), errorPollInterval: Duration = .seconds(5))
    public func start() async
    public func stop()
}
```

- [ ] **Step 1: Write failing tests**

Create `MatronShared/Tests/ViewModelTests/RendezvousSignInViewModelTests.swift`. The `FakeLinkClaimer`/`FakeAuth` in `LinkSignInViewModelTests.swift` are file-private — this file defines its own (the `FakeAuth` below is a verbatim copy of that file's; the claimer is minimal).

```swift
import XCTest
import MatronAuth
import MatronJournal
import MatronModels
@testable import MatronViewModels

@MainActor
final class RendezvousSignInViewModelTests: XCTestCase {
    private static let rid1 = "23456789BCDFGHJKMNPQRSTVWX"
    private static let rid2 = "X".padding(toLength: 26, withPad: "X", startingAt: 0)

    // MARK: Fakes

    private final class FakeRelay: RelayRendezvousing, @unchecked Sendable {
        var createResults: [Result<Rendezvous, Error>] =
            [.success(Rendezvous(rid: rid1, secret: String(repeating: "a", count: 64), expiresIn: 180))]
        private(set) var createCount = 0
        var pollScript: [Result<RendezvousPollResult, Error>] = [.success(.waiting)]
        private(set) var pollCount = 0
        var holdPoll = false
        private var pollContinuations: [CheckedContinuation<Void, Never>] = []
        var pollGateReached = false
        func releasePoll() { pollContinuations.forEach { $0.resume() }; pollContinuations.removeAll() }

        func createRendezvous() async throws -> Rendezvous {
            createCount += 1
            return try (createResults.count > 1 ? createResults.removeFirst() : createResults[0]).get()
        }
        func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult {
            pollCount += 1
            if holdPoll {
                pollGateReached = true
                await withCheckedContinuation { pollContinuations.append($0) }
            }
            return try (pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]).get()
        }
        func offerRendezvous(rid: String, server: String, code: String) async throws {}
    }

    private final class FakeClaimer: LinkClaiming, @unchecked Sendable {
        var claimResult: Result<LinkClaim, Error> = .success(LinkClaim(claimToken: "ct", expiresIn: 120))
        var pollScript: [Result<LinkPollResult, Error>] = []
        private(set) var claimedCodes: [String] = []
        func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
            claimedCodes.append(code)
            return try claimResult.get()
        }
        func linkPoll(claimToken: String) async throws -> LinkPollResult {
            try (pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]).get()
        }
    }

    // Verbatim copy of LinkSignInViewModelTests.swift's file-private FakeAuth.
    private final class FakeAuth: AuthService, @unchecked Sendable {
        var persistedSessions: [UserSession] = []
        var persistError: Error?
        func probe(_ rawURL: String) async throws -> ServerCapabilities {
            ServerCapabilities(supportsPasswordLogin: true, supportsSSO: false)
        }
        func loginPassword(homeserverURL: URL, username: String, password: String,
                           initialDeviceDisplayName: String) async throws -> UserSession {
            fatalError("unused")
        }
        func restoreSession() async throws -> UserSession? { nil }
        func persist(_ session: UserSession) throws {
            if let persistError { throw persistError }
            persistedSessions.append(session)
        }
        func clearSession() throws {}
    }

    // Same helper convention as LinkSignInViewModelTests.swift.
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeVM(relay: FakeRelay, claimer: FakeClaimer,
                        auth: FakeAuth = FakeAuth())
        -> (RendezvousSignInViewModel, LinkSignInViewModel, FakeAuth) {
        let link = LinkSignInViewModel(auth: auth, deviceDisplayName: "Matron Mac",
                                       apiFactory: { _ in claimer },
                                       pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        let vm = RendezvousSignInViewModel(relay: relay, link: link,
                                           pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        return (vm, link, auth)
    }

    // MARK: Tests

    func test_start_showsRlinkQR_thenOfferDrivesLinkSignInToCompletion() async throws {
        let relay = FakeRelay()
        relay.pollScript = [.success(.waiting),
                            .success(.offered(server: "https://chat.example.com", code: "2345-6789"))]
        let claimer = FakeClaimer()
        claimer.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, link, auth) = makeVM(relay: relay, claimer: claimer)

        await vm.start()
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid1)"))

        let expected = UserSession(userID: "dan", deviceID: "42",
                                   homeserverURL: URL(string: "https://chat.example.com")!, accessToken: "tok99")
        await waitUntil(link.phase == .signedIn(expected))
        XCTAssertEqual(link.phase, .signedIn(expected))
        XCTAssertEqual(vm.phase, .connecting(serverHost: "chat.example.com"))
        XCTAssertEqual(claimer.claimedCodes, ["2345-6789"])
        XCTAssertEqual(auth.persistedSessions.count, 1)
    }

    func test_expiredRendezvous_silentlyRegenerates() async {
        let relay = FakeRelay()
        relay.createResults = [
            .success(Rendezvous(rid: Self.rid1, secret: String(repeating: "a", count: 64), expiresIn: 180)),
            .success(Rendezvous(rid: Self.rid2, secret: String(repeating: "b", count: 64), expiresIn: 180)),
        ]
        relay.pollScript = [.failure(RelayError.notFound), .success(.waiting)]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        await waitUntil(relay.createCount == 2)
        await waitUntil(vm.phase == .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid2)"))
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid2)"))
    }

    func test_createFailure_isARetryableError() async {
        let relay = FakeRelay()
        relay.createResults = [.failure(RelayError.transport("down"))]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        XCTAssertEqual(vm.phase, .error("Couldn't reach the Matron relay — check your connection and try again."))
    }

    func test_transientPollFailure_keepsPolling() async {
        let relay = FakeRelay()
        relay.pollScript = [.failure(RelayError.transport("blip")), .success(.waiting), .success(.waiting)]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        await waitUntil(relay.pollCount >= 3)
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid1)"))
    }

    func test_stop_whilePollInFlight_dropsTheLateOffer() async {
        let relay = FakeRelay()
        relay.holdPoll = true
        relay.pollScript = [.success(.offered(server: "https://chat.example.com", code: "2345-6789"))]
        let claimer = FakeClaimer()
        let (vm, link, auth) = makeVM(relay: relay, claimer: claimer)
        await vm.start()
        await waitUntil(relay.pollGateReached)
        vm.stop()
        relay.releasePoll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(link.phase, .idle)
        XCTAssertTrue(claimer.claimedCodes.isEmpty)
        XCTAssertTrue(auth.persistedSessions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RendezvousSignInViewModelTests`
Expected: FAIL — `cannot find 'RendezvousSignInViewModel' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/ViewModels/RendezvousSignInViewModel.swift`:

```swift
import Foundation
import MatronJournal

/// Show-side of the reverse QR flow (spec §2): a signed-out device that
/// can't scan asks the shared relay for a rendezvous, renders it as a QR,
/// and polls. When a signed-in phone scans it and posts {server, code},
/// this VM hands both values to the existing LinkSignInViewModel — from
/// there the flow is byte-for-byte the shipped claim → approve → token
/// path against the user's own journal. The relay never sees a token.
@Observable @MainActor
public final class RendezvousSignInViewModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case showing(qrPayload: String)
        /// Shown before and during the claim so the user can see WHICH
        /// server the relay pointed us at (spec §4: compromised-relay
        /// transparency). The link VM's own phases drive the rest.
        case connecting(serverHost: String)
        case error(String)
    }

    public private(set) var phase: Phase = .idle

    private let relay: any RelayRendezvousing
    private let link: LinkSignInViewModel
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    // Same stale-async discipline as LinkSignInViewModel/DeviceLinkViewModel:
    // stop() bumps the generation; every post-await branch re-checks it
    // before touching state.
    private var generation = 0
    private var pollTask: Task<Void, Never>?

    public init(relay: any RelayRendezvousing, link: LinkSignInViewModel,
                pollInterval: Duration = .seconds(2), errorPollInterval: Duration = .seconds(5)) {
        self.relay = relay
        self.link = link
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func start() async {
        generation += 1
        let gen = generation
        pollTask?.cancel()
        pollTask = nil
        phase = .loading
        await createAndShow(gen)
    }

    public func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func createAndShow(_ gen: Int) async {
        do {
            let rendezvous = try await relay.createRendezvous()
            guard gen == generation else { return }
            phase = .showing(qrPayload: RendezvousURI.format(rid: rendezvous.rid))
            startPolling(rid: rendezvous.rid, secret: rendezvous.secret, gen: gen)
        } catch {
            guard gen == generation else { return }
            phase = .error("Couldn't reach the Matron relay — check your connection and try again.")
        }
    }

    private func startPolling(rid: String, secret: String, gen: Int) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                do {
                    let result = try await self.relay.pollRendezvous(rid: rid, secret: secret)
                    guard !Task.isCancelled, gen == self.generation else { return }
                    switch result {
                    case .waiting:
                        try? await Task.sleep(for: self.pollInterval)
                    case .offered(let server, let code):
                        self.phase = .connecting(serverHost: URL(string: server)?.host ?? server)
                        self.link.serverURL = server
                        self.link.codeInput = code
                        await self.link.submitManual()
                        return
                    }
                } catch RelayError.notFound {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    // Rendezvous expired: silently regenerate — the mirror of
                    // the show-side's link-expiry regeneration.
                    await self.createAndShow(gen)
                    return
                } catch {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    try? await Task.sleep(for: self.errorPollInterval)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter RendezvousSignInViewModelTests` — Expected: PASS (5/5).
Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test` — Expected: full package PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/RendezvousSignInViewModel.swift MatronShared/Tests/ViewModelTests/RendezvousSignInViewModelTests.swift
git commit -m "Add RendezvousSignInViewModel (show-side reverse QR)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `DeviceLinkViewModel.offerScanned` (signed-in Scan side)

**Files:**
- Modify: `MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift` (append)

**Interfaces:**
- Consumes: `RelayRendezvousing`, `RelayError`, `RendezvousURI`; the VM's own live session code (`Phase.showing`).
- Produces (used by Task 5): `DeviceLinkViewModel.init` gains `relay: (any RelayRendezvousing)? = nil` (after `serverURL`, before `pollInterval`); new method `public func offerScanned(_ payload: String) async`. Outcomes land in the EXISTING `noticeMessage` — no new phase (the desktop's claim flips the status poll to `.claimed` exactly like a normal claim).

**Design note (why no `linkStart` here):** the Settings screen's `DeviceLinkViewModel` already called `linkStart()` when the screen opened — a live session exists whichever tab is selected, and `link/start` REPLACES a starter's session, so starting another would kill the code we're about to offer. The scan handler offers the session the VM already holds.

- [ ] **Step 1: Write failing tests**

Append to `MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift` (inside the existing test class; the existing `FakeDeviceLinker` is reused as-is; add a file-private `FakeRelay` — only `offerRendezvous` matters here):

```swift
    private final class FakeRelay: RelayRendezvousing, @unchecked Sendable {
        var offerResult: Result<Void, Error> = .success(())
        private(set) var offers: [(rid: String, server: String, code: String)] = []
        func createRendezvous() async throws -> Rendezvous { fatalError("unused") }
        func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult { fatalError("unused") }
        func offerRendezvous(rid: String, server: String, code: String) async throws {
            offers.append((rid, server, code))
            try offerResult.get()
        }
    }

    private static let rid = "23456789BCDFGHJKMNPQRSTVWX"
    private static let rlinkPayload = "matron://rlink?v=1&rid=23456789BCDFGHJKMNPQRSTVWX"

    func test_offerScanned_sendsTheLiveSessionCodeAndServer() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(relay.offers.count, 1)
        XCTAssertEqual(relay.offers[0].rid, Self.rid)
        XCTAssertEqual(relay.offers[0].server, "https://chat.example.com")
        XCTAssertEqual(relay.offers[0].code, "2345-6789")
        XCTAssertEqual(vm.noticeMessage, "Sent — approve the request when it appears.")
    }

    func test_offerScanned_parseFailures_neverTouchTheRelay() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        await vm.offerScanned("matron://rlink?v=9&rid=\(Self.rid)")
        XCTAssertEqual(vm.noticeMessage, "This QR code needs a newer version of Matron.")
        await vm.offerScanned("https://not-matron.example.com")
        XCTAssertEqual(vm.noticeMessage, "Not a Matron link code.")
        XCTAssertTrue(relay.offers.isEmpty)
    }

    func test_offerScanned_relayOutcomes_mapToNotices() async {
        for (result, notice): (Result<Void, Error>, String) in [
            (.failure(RelayError.conflict), "That code was already used by another device."),
            (.failure(RelayError.notFound), "That code expired — ask the computer to show a fresh one."),
            (.failure(RelayError.transport("down")), "Couldn't reach the Matron relay — try again."),
        ] {
            let fake = FakeDeviceLinker()
            fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
            let relay = FakeRelay()
            relay.offerResult = result
            let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                         relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
            await vm.start()
            await vm.offerScanned(Self.rlinkPayload)
            XCTAssertEqual(vm.noticeMessage, notice)
        }
    }

    func test_offerScanned_withoutALiveCode_asksToRetry() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.failure(JournalAPIError.transport("down"))] // start fails → no .showing code
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertTrue(relay.offers.isEmpty)
        XCTAssertEqual(vm.noticeMessage, "Still fetching a link code — try scanning again in a moment.")
    }
```

(`FakeDeviceLinker` already exists at the top of this file with `startResults: [Result<LinkStart, Error>]` — the snippets above use it as-is.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DeviceLinkViewModelTests`
Expected: FAIL — no `relay:` init parameter / `offerScanned` undefined.

- [ ] **Step 3: Implement**

In `MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift`:

1. Add `import MatronJournal` if not present (it is — `LinkURI` is used).
2. Add stored property `private let relay: (any RelayRendezvousing)?` and the init parameter `relay: (any RelayRendezvousing)? = nil` (assign in init).
3. Add the method:

```swift
    /// Settings → Link a Device → Scan tab: the signed-in phone scanned a
    /// signed-out device's `matron://rlink` QR. Offers THIS VM's live link
    /// session to the relay — start() already minted a session when the
    /// screen opened, and link/start replaces a starter's session, so
    /// minting another here would kill the code being offered. After a
    /// successful offer the desktop claims within seconds and the existing
    /// status poll flips to .claimed → the normal approve card.
    public func offerScanned(_ payload: String) async {
        guard let relay else { return }
        let gen = generation
        let rid: String
        do {
            rid = try RendezvousURI.parse(payload)
        } catch RendezvousURI.ParseError.unsupportedVersion {
            noticeMessage = "This QR code needs a newer version of Matron."
            return
        } catch {
            noticeMessage = "Not a Matron link code."
            return
        }
        guard case .showing(let code) = phase else {
            noticeMessage = "Still fetching a link code — try scanning again in a moment."
            return
        }
        do {
            try await relay.offerRendezvous(rid: rid, server: serverURL.absoluteString, code: code)
            guard gen == generation else { return }
            noticeMessage = "Sent — approve the request when it appears."
        } catch {
            guard gen == generation else { return }
            switch error as? RelayError {
            case .conflict: noticeMessage = "That code was already used by another device."
            case .notFound: noticeMessage = "That code expired — ask the computer to show a fresh one."
            default: noticeMessage = "Couldn't reach the Matron relay — try again."
            }
        }
    }
```

(If `serverURL` is stored with its trailing slash stripped already — it is, `ServerURLValidator` handles that at session creation — `absoluteString` is the right value to offer.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test` — Expected: full package PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift
git commit -m "Add offerScanned to DeviceLinkViewModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: iOS UI — sign-in tabs, Settings tabs, approve copy

**Files:**
- Modify: `Matron/Features/Onboarding/SignInView.swift`
- Modify: `Matron/Features/Settings/DeviceLinkView.swift`
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (pass the relay)
- Modify: `Matron/App/MatronApp.swift` (construct the rendezvous VM)
- Test: `MatronTests/SignInViewBindingTests.swift` (update inits if they construct these views/VMs)

**Interfaces:**
- Consumes: `RendezvousSignInViewModel` (Task 3), `DeviceLinkViewModel.offerScanned` + `relay:` init param (Task 4), `RelayClient()` (Task 2), existing `QRScannerView` and `QRCodeView`.

- [ ] **Step 1: Wire the rendezvous VM into the app**

In `Matron/App/MatronApp.swift`, where `SignInViewModel` and `LinkSignInViewModel` are constructed (~lines 125–126), add a third VM and pass it to `SignInView`:

```swift
let rendezvousViewModel = RendezvousSignInViewModel(relay: RelayClient(), link: linkViewModel)
```

(match the surrounding storage style — if the two existing VMs are `@State` properties, make this one too; `SignInView` gains an `var rendezvousViewModel: RendezvousSignInViewModel` property set from here.)

- [ ] **Step 2: Add the Scan/Show tab area to `SignInView`**

In `Matron/Features/Onboarding/SignInView.swift`, replace the current `linkSignIn` QR area builder with a tabbed version. Add to the view:

```swift
    private enum QRTab: String, CaseIterable { case scan = "Scan", show = "Show" }
    @State private var qrTab: QRTab = .scan
```

The tab container (replacing the direct "Scan QR code" button placement; the manual "Have a link code?" entry stays OUTSIDE the tabs, beneath them, as today):

```swift
    Picker("QR mode", selection: $qrTab) {
        ForEach(QRTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("signin.qrtab")

    switch qrTab {
    case .scan:
        // the EXISTING "Scan QR code" button block moves here unchanged
    case .show:
        rendezvousShow
    }
```

The Show tab content (new `@ViewBuilder` on `SignInView`):

```swift
    @ViewBuilder private var rendezvousShow: some View {
        switch rendezvousViewModel.phase {
        case .idle, .loading:
            ProgressView()
        case .showing(let payload):
            VStack(spacing: 12) {
                QRCodeView(string: payload)
                    .frame(width: 220, height: 220)
                Text("Scan this with a phone that's signed in to Matron")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .connecting(let host):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(host)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(spacing: 8) {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await rendezvousViewModel.start() } }
            }
        }
    }
```

Lifecycle: start/stop with tab selection and screen lifetime —

```swift
    .onChange(of: qrTab) { _, tab in
        if tab == .show { Task { await rendezvousViewModel.start() } }
        else { rendezvousViewModel.stop() }
    }
    .onDisappear {
        rendezvousViewModel.stop()
        linkViewModel.cancel() // existing line — keep
    }
```

When `linkViewModel.phase` is `.error` while the Show tab is selected, show the link error with a "Show a new code" button that calls `Task { await rendezvousViewModel.start() }` (place it where the existing link-error rendering lives; `start()` resets both the rendezvous phase and, via a fresh offer, the flow).

- [ ] **Step 3: Add Show/Scan tabs + sharpened copy to `DeviceLinkView`**

In `Matron/Features/Settings/DeviceLinkView.swift`:

1. `init(api: any DeviceLinking, serverURL: URL)` → `init(api: any DeviceLinking, serverURL: URL, relay: any RelayRendezvousing)`, forwarding `relay:` into `DeviceLinkViewModel`.
2. Add tab state + picker above the QR content (Show is the default; the whole existing QR/status content becomes the Show tab):

```swift
    private enum LinkTab: String, CaseIterable { case show = "Show", scan = "Scan" }
    @State private var linkTab: LinkTab = .show
    @State private var showingScanner = false
```

3. Scan tab content:

```swift
    VStack(spacing: 12) {
        Text("If your computer is showing a Matron QR code, scan it to sign it in as you.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Button {
            showingScanner = true
        } label: {
            Label("Scan the computer's QR code", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(.borderedProminent)
    }
    .fullScreenCover(isPresented: $showingScanner) {
        QRScannerView { payload in
            Task { await viewModel.offerScanned(payload) }
        }
    }
```

The existing `noticeMessage` rendering already displays the offer outcomes; make sure it is visible on BOTH tabs (keep it outside the tab `switch`). The claimed/approve card must also render regardless of tab (the offer's whole point is that the status poll flips to `.claimed` — keep the `when`-on-phase branches for `.claimed`, `.approved`, `.denied` outside the tab switch so they take over the screen exactly as today).
4. Approve copy: replace the footnote line `Text("Approving signs that device in with full access to your account.")` with:

```swift
    Text("This signs a computer into **your** account — only approve if it's yours, in front of you.")
```

- [ ] **Step 4: Pass the relay at the call site**

In `Matron/Features/Settings/DeviceSettingsView.swift` (~line 38–44), the `DeviceLinkView(api: linkAPI, serverURL: session.homeserverURL)` call gains `relay: RelayClient()`.

- [ ] **Step 5: Build + run iOS tests**

```bash
xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme Matron build CODE_SIGNING_ALLOWED=NO
MATRON_SKIP_SNAPSHOT_TESTS=1 TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds; tests PASS. If `MatronTests/SignInViewBindingTests.swift` constructs `SignInView` directly, add the new `rendezvousViewModel:` argument there (a `RendezvousSignInViewModel(relay: RelayClient(), link: <the test's link VM>)` is fine — bindings tests never hit the network).

- [ ] **Step 6: Commit**

```bash
git add Matron/ MatronTests/
git commit -m "iOS: Scan/Show tabs on sign-in and Link a Device, sharpened approve copy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Mac UI — Show area on sign-in, approve copy

**Files:**
- Modify: `MatronMac/Features/Onboarding/MacSignInView.swift`
- Modify: `MatronMac/Features/Settings/MacDeviceLinkView.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (construct + pass the rendezvous VM)

**Interfaces:**
- Consumes: `RendezvousSignInViewModel` (Task 3), `RelayClient` (Task 2), `QRCodeView`.

- [ ] **Step 1: Wire and render the Show area**

In `MatronMac/App/MatronMacApp.swift` (~lines 114–115), construct `RendezvousSignInViewModel(relay: RelayClient(), link: linkViewModel)` alongside the existing two VMs and pass it into `MacSignInView`.

In `MacSignInView.swift`: Mac cannot scan, so there is NO tab picker — the rendezvous QR IS the QR area (spec: "default and only tab on Mac"). Add the same `rendezvousShow` builder as iOS Task 5 Step 2 (QR at 200×200 to match the Mac link screen's sizing), placed above the existing "Have a link code?" manual entry, and:

```swift
    .task { await rendezvousViewModel.start() }
    .onDisappear {
        rendezvousViewModel.stop()
        linkViewModel.cancel() // existing line — keep
    }
```

The window may need modest extra height for the QR — adjust the fixed `.frame(width: 480, height: 520)` to fit (e.g. height 640); verify visually if possible, otherwise keep the change minimal.

- [ ] **Step 2: Sharpen the Mac approve copy**

In `MacDeviceLinkView.swift` replace the footnote `Text("Approving signs that device in with full access to your account.")` with:

```swift
    Text("This signs a computer into **your** account — only approve if it's yours, in front of you.")
```

- [ ] **Step 3: Build + run Mac tests**

```bash
xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme MatronMac build CODE_SIGNING_ALLOWED=NO
MATRON_SKIP_SNAPSHOT_TESTS=1 TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds; tests PASS (update `MacSignInViewBindingTests.swift` inits if needed, as in Task 5).

- [ ] **Step 4: Commit**

```bash
git add MatronMac/ MatronMacTests/
git commit -m "Mac: rendezvous QR on the sign-in screen, sharpened approve copy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test` — green.
- [ ] Both `xcodebuild test` runs (Task 5 Step 5, Task 6 Step 3) — green.
- [ ] Grep check: the string `push.matron.chat` appears exactly once in `MatronShared/Sources` (the `MatronRelay.baseURL` constant).
- [ ] Open a non-draft PR against `main` titled "Link rendezvous: reverse QR sign-in (Show tab) + Settings Scan tab" — body summarizes the two flows and links the spec; ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- [ ] Note for reviewers in the PR body: until the journal/relay PR is deployed, the Show tab reports the relay-unreachable error — expected.
