# QR Device-Link Login — Apple Implementation Plan (matron-apple)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both roles of QR device-link login on Apple platforms: a signed-in device shows a QR ("Link a Device" in Settings, iOS + Mac) and a signing-in device scans it (iOS camera) or types the code (iOS + Mac manual path), landing in the normal signed-in flow with nothing typed.

**Architecture:** Six new `JournalAPI` methods over the server's `/link/*` endpoints (see matron-journal `docs/protocol.md`, "Device link (QR sign-in)"). Two new shared view models in MatronShared — `DeviceLinkViewModel` (show side) and `LinkSignInViewModel` (claimant side) — tested against fakes, with thin per-platform SwiftUI views following the existing `AddAgentSheet`/`MacAddAgentSheet` split. Spec: matron-journal `docs/superpowers/specs/2026-07-18-qr-device-link-login-design.md` (§2 QR payload, §3 Apple, §5 Errors, §7 Testing).

**Tech Stack:** Swift 5.10 SPM package (MatronShared) + xcodegen projects. CoreImage `CIFilter.qrCodeGenerator` for rendering; `AVCaptureMetadataOutput` for iOS scanning. No new package dependencies.

**Worktree note:** The user's checkout sits on an unrelated branch with untracked files. Execute this plan in a fresh worktree off `main` (e.g. `git worktree add /Users/danbarker/Dev/matron-apple-linklogin -b feat/qr-device-link main`), run `xcodegen generate` there before any `xcodebuild`, and never touch the user's checkout.

## Global Constraints

Copied from the spec — every task's requirements implicitly include these:

- QR payload: `matron://link?v=1&server=<URL-encoded base server URL>&code=XXXX-XXXX`. `v` ≠ 1 → "This QR code needs a newer version of Matron." Non-`matron://link` payload → "Not a Matron sign-in code."
- Wire fields (server contract): start → `{link_code, expires_in}`; claim request `{link_code, device_name}` → `{status:'claimed', claim_token, expires_in}`; poll request `{claim_token}` → `{status:'pending'}` | `{status:'approved', token, device_id, user_id, username}` | `{status:'denied'}`; status → `{status:'waiting', expires_in}` | `{status:'claimed', device_name, requester_ip, expires_in}`; approve/deny request `{link_code}`. `claim` and `poll` are unauthenticated; the other four require the Bearer.
- The claimant builds `UserSession(userID: username, deviceID: String(device_id), homeserverURL: scanned server URL, accessToken: token)` — `userID` is the returned `username`, exactly what password login stores. Persist via the existing `auth.persist(session)` and enter the normal `onSignedIn` path (which already runs `awaitPendingTeardown()`).
- `device_name` sent on claim is the platform's existing display name: `"Matron iOS"` / `"Matron Mac"`.
- Show side polls status every **2 s** while visible; claimant polls every **2 s**; both back off to **5 s** on transport errors and keep trying until their screen closes. Status `404` on the show side silently regenerates (fresh `link/start`). Approve success is terminal for the show side.
- Old server (`404` on `/link/start`) → "Server doesn't support device linking yet."
- Error copy (spec §5, verbatim): denied claimant → "Sign-in was denied on the other device." · expired claimant poll → "Sign-in expired. Scan again." · claim 409 → "This code was already used. Generate a new one on your signed-in device." · approve-after-expiry on show side → "Code expired — showing a fresh one".
- Codes reuse `PairingCode` normalize/display helpers (8 chars, `XXXX-XXXX`); manual input auto-formats like `PairingViewModel.codeInput` does.
- Mac is show + manual-code only (no camera). iOS gets the camera sheet; `NSCameraUsageDescription` goes in `project.yml` (the `.xcodeproj` is generated — never edit a plist by hand): "Matron uses the camera to scan sign-in QR codes from your other devices."
- Camera-permission denial shows a message with a Settings deep-link; the manual path stays available.
- Match existing style: `@Observable @MainActor` view models, protocol-slice APIs for testability (like `DevicesProviding`), XCTest with `waitUntil`-style polling helpers, short pollIntervals injected in tests.
- Test commands: `cd MatronShared && swift test --filter <Class>` (focused), `swift test` (package). App builds: `xcodegen generate` then `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO` (iOS) / `-scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (Mac).
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- `MatronShared/Sources/Journal/JournalAPI.swift` (modify) — link DTOs + six methods.
- `MatronShared/Sources/Journal/LinkURI.swift` (create) — the one place the QR URI format is known.
- `MatronShared/Sources/DesignSystem/QRCodeView.swift` (create) — CoreImage QR render helper + SwiftUI wrapper (shared iOS/Mac).
- `MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift` (create) — show-side state machine + `DeviceLinking` protocol.
- `MatronShared/Sources/ViewModels/LinkSignInViewModel.swift` (create) — claimant state machine + `LinkClaiming` protocol.
- `Matron/Features/Settings/DeviceLinkView.swift` (create) + `Matron/Features/Settings/DeviceSettingsView.swift` (modify) + `Matron/Features/ChatList/ChatListView.swift` (modify) + `Matron/App/AppDependencies.swift` (modify) — iOS show side.
- `MatronMac/Features/Settings/MacDeviceLinkView.swift` (create) + `MatronMac/App/MatronMacApp.swift` (modify) + `MatronMac/App/AppDependencies.swift` (modify) — Mac show side.
- `Matron/Features/Onboarding/QRScannerView.swift` (create) + `Matron/Features/Onboarding/SignInView.swift` (modify) + `Matron/App/MatronApp.swift` (modify) + `project.yml` (modify) — iOS scan side.
- `MatronMac/Features/Onboarding/MacSignInView.swift` (modify) + `MatronMac/App/MatronMacApp.swift` (modify) — Mac manual path.
- Tests: `MatronShared/Tests/JournalTests/JournalAPITests.swift` (modify), `MatronShared/Tests/JournalTests/LinkURITests.swift` (create), `MatronShared/Tests/DesignSystemSnapshotTests/QRCodeTests.swift` (create), `MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift` (create), `MatronShared/Tests/ViewModelTests/LinkSignInViewModelTests.swift` (create).

---

### Task 1: JournalAPI link methods + DTOs

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift` (DTOs after `PairPreview` ~line 73; methods after `pairApprove` ~line 225)
- Test: `MatronShared/Tests/JournalTests/JournalAPITests.swift` (append)

**Interfaces:**
- Consumes: existing `request(path:method:body:authenticated:)` internals and `JournalAPIError` mapping (409→`.conflict`, 404→`.notFound` already handled).
- Produces (Tasks 3-4 rely on these exact signatures):
  - `public struct LinkStart: Equatable, Sendable { let code: String; let expiresIn: Int }`
  - `public enum LinkStatus: Equatable, Sendable { case waiting(expiresIn: Int); case claimed(deviceName: String, requesterIP: String, expiresIn: Int) }`
  - `public struct LinkClaim: Equatable, Sendable { let claimToken: String; let expiresIn: Int }`
  - `public struct LinkApproval: Equatable, Sendable { let token: String; let deviceID: Int64; let userID: Int64; let username: String }`
  - `public enum LinkPollResult: Equatable, Sendable { case pending; case denied; case approved(LinkApproval) }`
  - `func linkStart() async throws -> LinkStart` · `func linkStatus() async throws -> LinkStatus` · `func linkApprove(code: String) async throws` · `func linkDeny(code: String) async throws` · `func linkClaim(code: String, deviceName: String) async throws -> LinkClaim` · `func linkPoll(claimToken: String) async throws -> LinkPollResult`

- [ ] **Step 1: Write the failing tests**

Append to `JournalAPITests.swift` (uses the file's existing `StubURLProtocol` + `makeAPI()`):

```swift
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
        XCTAssertEqual(try await api.linkStatus(), .waiting(expiresIn: 90))
        StubURLProtocol.responses = ["/link/status": (200, #"{"status":"claimed","device_name":"Pixel 9","requester_ip":"198.51.100.7","expires_in":55}"#)]
        XCTAssertEqual(try await api.linkStatus(),
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
        XCTAssertEqual(try await api.linkPoll(claimToken: "aa11"), .pending)
        StubURLProtocol.responses = ["/link/poll": (200, #"{"status":"denied"}"#)]
        XCTAssertEqual(try await api.linkPoll(claimToken: "aa11"), .denied)
        StubURLProtocol.responses = ["/link/poll": (200,
            #"{"status":"approved","token":"bb22","device_id":42,"user_id":7,"username":"dan"}"#)]
        XCTAssertEqual(try await api.linkPoll(claimToken: "aa11"),
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /path/to/worktree/MatronShared && swift test --filter JournalAPITests`
Expected: COMPILE FAILURE — `LinkStart`/`linkStart` etc. don't exist. (A compile failure in the test target is this step's "red".)

- [ ] **Step 3: Implement the DTOs and methods**

In `JournalAPI.swift`, after the `PairPreview` struct (~line 73), add:

```swift
/// `POST /link/start` — a fresh device-link session for QR sign-in.
public struct LinkStart: Equatable, Sendable {
    /// Display form (`XXXX-XXXX`) — rendered under the QR and embedded in
    /// the payload verbatim.
    public let code: String
    public let expiresIn: Int

    public init(code: String, expiresIn: Int) {
        self.code = code
        self.expiresIn = expiresIn
    }
}

/// `POST /link/status` — what the show side's poll sees.
public enum LinkStatus: Equatable, Sendable {
    case waiting(expiresIn: Int)
    /// Someone claimed the code: show the approve card. The name is
    /// claimant-supplied; the IP is what the server saw — both go on
    /// screen before the user may approve (anti-phish, like PairPreview).
    case claimed(deviceName: String, requesterIP: String, expiresIn: Int)
}

/// `POST /link/claim` — the claimant's secret poll credential.
public struct LinkClaim: Equatable, Sendable {
    public let claimToken: String
    public let expiresIn: Int

    public init(claimToken: String, expiresIn: Int) {
        self.claimToken = claimToken
        self.expiresIn = expiresIn
    }
}

/// The identity minted at the approved `link/poll`. `username` exists
/// because the apps store the typed username as `UserSession.userID` and a
/// link claimant never types one.
public struct LinkApproval: Equatable, Sendable {
    public let token: String
    public let deviceID: Int64
    public let userID: Int64
    public let username: String

    public init(token: String, deviceID: Int64, userID: Int64, username: String) {
        self.token = token
        self.deviceID = deviceID
        self.userID = userID
        self.username = username
    }
}

/// `POST /link/poll` — pending until the starter acts; `denied` and
/// `approved` each arrive at most once (the server deletes the session).
public enum LinkPollResult: Equatable, Sendable {
    case pending
    case denied
    case approved(LinkApproval)
}
```

After `pairApprove` (~line 225), add:

```swift
    // MARK: Device link (QR sign-in)

    /// Starts (or replaces) this device's link session. `.notFound` means
    /// the server predates /link/* — callers surface "doesn't support
    /// device linking yet".
    public func linkStart() async throws -> LinkStart {
        let obj = try await request(path: "/link/start", method: "POST", body: [:])
        guard let code = obj["link_code"] as? String,
              let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
        else { throw JournalAPIError.transport("malformed link start response") }
        return LinkStart(code: code, expiresIn: expiresIn)
    }

    /// This device's active session state. `.notFound` = no active session
    /// (expired or resolved) — the show side regenerates on it.
    public func linkStatus() async throws -> LinkStatus {
        let obj = try await request(path: "/link/status", method: "POST", body: [:])
        let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue ?? 0
        switch obj["status"] as? String {
        case "waiting":
            return .waiting(expiresIn: expiresIn)
        case "claimed":
            guard let name = obj["device_name"] as? String,
                  let ip = obj["requester_ip"] as? String
            else { throw JournalAPIError.transport("malformed link status response") }
            return .claimed(deviceName: name, requesterIP: ip, expiresIn: expiresIn)
        default:
            throw JournalAPIError.transport("malformed link status response")
        }
    }

    /// Approves this device's claimed session. `.conflict` = nothing
    /// claimed yet or already resolved; `.notFound` = expired/gone.
    public func linkApprove(code: String) async throws {
        _ = try await request(path: "/link/approve", method: "POST", body: ["link_code": code])
    }

    public func linkDeny(code: String) async throws {
        _ = try await request(path: "/link/deny", method: "POST", body: ["link_code": code])
    }

    /// Claimant side: claims a scanned/typed code. Unauthenticated — this
    /// API instance belongs to the *target* server and has no token yet.
    /// `.conflict` = code already used; `.notFound` = unknown/expired.
    public func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
        let obj = try await request(path: "/link/claim", method: "POST",
                                    body: ["link_code": code, "device_name": deviceName],
                                    authenticated: false)
        guard let token = obj["claim_token"] as? String,
              let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
        else { throw JournalAPIError.transport("malformed link claim response") }
        return LinkClaim(claimToken: token, expiresIn: expiresIn)
    }

    /// Claimant poll loop body. `.notFound` after a successful claim means
    /// the session expired (or was replaced) — surface "Sign-in expired".
    public func linkPoll(claimToken: String) async throws -> LinkPollResult {
        let obj = try await request(path: "/link/poll", method: "POST",
                                    body: ["claim_token": claimToken], authenticated: false)
        switch obj["status"] as? String {
        case "pending": return .pending
        case "denied": return .denied
        case "approved":
            guard let token = obj["token"] as? String,
                  let deviceID = (obj["device_id"] as? NSNumber)?.int64Value,
                  let userID = (obj["user_id"] as? NSNumber)?.int64Value,
                  let username = obj["username"] as? String
            else { throw JournalAPIError.transport("malformed link poll response") }
            return .approved(LinkApproval(token: token, deviceID: deviceID, userID: userID, username: username))
        default:
            throw JournalAPIError.transport("malformed link poll response")
        }
    }
```

Also update the stale doc comment on `JournalAPIError.conflict` (line 21-23) to:

```swift
    /// 409 — exactly-once semantics: `pair/approve` (already approved),
    /// `link/claim` (code already claimed), `link/approve` (nothing to
    /// approve yet, or already resolved).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && swift test --filter JournalAPITests`
Expected: PASS (all, including the 6 new).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI.swift MatronShared/Tests/JournalTests/JournalAPITests.swift
git commit -m "Add /link/* device-link methods to JournalAPI

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: LinkURI parser + QR render helper

**Files:**
- Create: `MatronShared/Sources/Journal/LinkURI.swift`
- Create: `MatronShared/Sources/DesignSystem/QRCodeView.swift`
- Test: `MatronShared/Tests/JournalTests/LinkURITests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/QRCodeTests.swift`

**Interfaces:**
- Consumes: `PairingCode.normalize/display/isPlausible` (`MatronShared/Sources/Journal/PairingCode.swift`).
- Produces:
  - `LinkURI.format(server: URL, code: String) -> String`
  - `LinkURI.parse(_ raw: String) throws -> (server: URL, code: String)` throwing `LinkURI.ParseError` (`notALink` | `unsupportedVersion` | `malformed`) — code returned in display form
  - `QRCode.image(for: String, scale: CGFloat) -> CGImage?` and `QRCodeView(string:)` SwiftUI view

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/LinkURITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class LinkURITests: XCTestCase {
    func test_roundTrip() throws {
        let server = URL(string: "https://chat.example.com")!
        let uri = LinkURI.format(server: server, code: "KTNM-3VQ8")
        XCTAssertTrue(uri.hasPrefix("matron://link?"))
        let parsed = try LinkURI.parse(uri)
        XCTAssertEqual(parsed.server, server)
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_roundTrip_serverWithPathPrefixAndPort() throws {
        // The server URL is embedded exactly as the session stores it —
        // subpath-hosted and non-443 servers must survive the round trip.
        let server = URL(string: "http://127.0.0.1:9810/journal")!
        let parsed = try LinkURI.parse(LinkURI.format(server: server, code: "KTNM-3VQ8"))
        XCTAssertEqual(parsed.server, server)
    }

    func test_parse_normalizesSloppyCode() throws {
        let parsed = try LinkURI.parse("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=ktnm3vq8")
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_parse_wrongSchemeOrHost_isNotALink() {
        for raw in ["https://chat.example.com", "matron://pair?v=1", "otp://x", "not a uri at all"] {
            XCTAssertThrowsError(try LinkURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? LinkURI.ParseError, .notALink, raw)
            }
        }
    }

    func test_parse_otherVersion_isUnsupported() {
        XCTAssertThrowsError(try LinkURI.parse("matron://link?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")) {
            XCTAssertEqual($0 as? LinkURI.ParseError, .unsupportedVersion)
        }
    }

    func test_parse_missingOrBadParts_isMalformed() {
        for raw in [
            "matron://link?server=https%3A%2F%2Fx.example&code=KTNM-3VQ8", // no v
            "matron://link?v=1&code=KTNM-3VQ8",                            // no server
            "matron://link?v=1&server=ftp%3A%2F%2Fx.example&code=KTNM-3VQ8", // non-http(s) server
            "matron://link?v=1&server=https%3A%2F%2Fx.example",            // no code
            "matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTN",   // short code
        ] {
            XCTAssertThrowsError(try LinkURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? LinkURI.ParseError, .malformed, raw)
            }
        }
    }
}
```

Create `MatronShared/Tests/DesignSystemSnapshotTests/QRCodeTests.swift`:

```swift
import XCTest
@testable import MatronDesignSystem

final class QRCodeTests: XCTestCase {
    func test_image_rendersSquareCGImage() {
        let image = QRCode.image(for: "matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, image?.height)
        XCTAssertGreaterThan(image?.width ?? 0, 100) // scaled up, not the raw ~30px matrix
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && swift test --filter LinkURITests` then `swift test --filter QRCodeTests`
Expected: COMPILE FAILURE — `LinkURI` / `QRCode` don't exist.

- [ ] **Step 3: Implement `LinkURI.swift`**

```swift
import Foundation

/// The QR sign-in payload — the single place the format is known:
/// `matron://link?v=1&server=<URL-encoded base server URL>&code=XXXX-XXXX`.
/// Android carries an equivalent parser; the server never sees the URI.
public enum LinkURI {
    public enum ParseError: Error, Equatable {
        /// Not ours at all — scanner shows "Not a Matron sign-in code."
        case notALink
        /// Ours, but a future version — scanner shows "update the app".
        case unsupportedVersion
        /// Ours and v=1, but the parts don't parse.
        case malformed
    }

    public static func format(server: URL, code: String) -> String {
        var components = URLComponents()
        components.scheme = "matron"
        components.host = "link"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url!.absoluteString
    }

    public static func parse(_ raw: String) throws -> (server: URL, code: String) {
        guard let components = URLComponents(string: raw),
              components.scheme == "matron", components.host == "link"
        else { throw ParseError.notALink }
        let value = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        guard let version = value("v") else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let serverRaw = value("server"), let server = URL(string: serverRaw),
              server.scheme == "http" || server.scheme == "https",
              let codeRaw = value("code"), PairingCode.isPlausible(codeRaw)
        else { throw ParseError.malformed }
        return (server, PairingCode.display(codeRaw))
    }
}
```

- [ ] **Step 4: Implement `QRCodeView.swift`**

```swift
import SwiftUI
import CoreImage.CIFilterBuiltins

/// CoreImage QR rendering, shared by the iOS and Mac "Link a Device"
/// screens.
public enum QRCode {
    /// Renders `string` as a QR `CGImage`, scaled up `scale`× from the raw
    /// module matrix so it stays crisp (no interpolation) at display size.
    public static func image(for string: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

public struct QRCodeView: View {
    let string: String

    public init(string: String) {
        self.string = string
    }

    public var body: some View {
        if let image = QRCode.image(for: string) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel("Sign-in QR code")
        }
        // qrCodeGenerator only fails on un-encodable input; our payloads are
        // short ASCII, so there is no meaningful fallback to draw.
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd MatronShared && swift test --filter LinkURITests && swift test --filter QRCodeTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/LinkURI.swift MatronShared/Sources/DesignSystem/QRCodeView.swift \
        MatronShared/Tests/JournalTests/LinkURITests.swift MatronShared/Tests/DesignSystemSnapshotTests/QRCodeTests.swift
git commit -m "Add LinkURI payload parser and shared QR renderer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: DeviceLinkViewModel (show side)

**Files:**
- Create: `MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift`

**Interfaces:**
- Consumes: `LinkStart`, `LinkStatus`, `JournalAPIError`, `LinkURI` from MatronJournal (Tasks 1-2).
- Produces (Tasks 5-6 render against this):
  - `protocol DeviceLinking: Sendable` (`linkStart`, `linkStatus`, `linkApprove(code:)`, `linkDeny(code:)`) + `extension JournalAPI: DeviceLinking`
  - `DeviceLinkViewModel(api:serverURL:pollInterval:errorPollInterval:)`, `phase: Phase` (`loading | showing(code:) | claimed(deviceName:requesterIP:) | approved | denied | unsupported | error(String)`), `qrPayload: String?`, `noticeMessage: String?`, `isSubmitting: Bool`, `func start() async`, `func approve() async`, `func deny() async`, `func stop()`

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift`:

```swift
import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// Scriptable show-side fake: `statusScript` is consumed one result per
/// poll; when it runs dry the last result repeats.
private final class FakeDeviceLinker: DeviceLinking, @unchecked Sendable {
    var startResults: [Result<LinkStart, Error>] = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120))]
    var statusScript: [Result<LinkStatus, Error>] = [.success(.waiting(expiresIn: 100))]
    var approveResult: Result<Void, Error> = .success(())
    var denyResult: Result<Void, Error> = .success(())
    private(set) var startCount = 0
    private(set) var statusCount = 0
    private(set) var approvedCodes: [String] = []
    private(set) var deniedCodes: [String] = []

    func linkStart() async throws -> LinkStart {
        startCount += 1
        let result = startResults.count > 1 ? startResults.removeFirst() : startResults[0]
        return try result.get()
    }
    func linkStatus() async throws -> LinkStatus {
        statusCount += 1
        let result = statusScript.count > 1 ? statusScript.removeFirst() : statusScript[0]
        return try result.get()
    }
    func linkApprove(code: String) async throws {
        approvedCodes.append(code)
        try approveResult.get()
    }
    func linkDeny(code: String) async throws {
        deniedCodes.append(code)
        try denyResult.get()
    }
}

@MainActor
final class DeviceLinkViewModelTests: XCTestCase {
    private func makeVM(_ fake: FakeDeviceLinker) -> DeviceLinkViewModel {
        DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                            pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func test_start_showsCodeAndQRPayload() async {
        let vm = makeVM(FakeDeviceLinker())
        await vm.start()
        XCTAssertEqual(vm.phase, .showing(code: "KTNM-3VQ8"))
        XCTAssertEqual(vm.qrPayload,
                       LinkURI.format(server: URL(string: "https://chat.example.com")!, code: "KTNM-3VQ8"))
        vm.stop()
    }

    func test_start_notFound_meansServerTooOld() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.failure(JournalAPIError.notFound)]
        let vm = makeVM(fake)
        await vm.start()
        XCTAssertEqual(vm.phase, .unsupported)
    }

    func test_claimedStatus_flipsToApproveCard() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.waiting(expiresIn: 100)),
                             .success(.claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7"))
        XCTAssertEqual(vm.phase, .claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7"))
        vm.stop()
    }

    func test_statusNotFound_regeneratesSilently() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        fake.statusScript = [.failure(JournalAPIError.notFound),
                             .success(.waiting(expiresIn: 100))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .showing(code: "WXYZ-2345"))
        XCTAssertEqual(vm.phase, .showing(code: "WXYZ-2345"))
        XCTAssertEqual(fake.startCount, 2)
        XCTAssertNil(vm.noticeMessage) // expiry while waiting is routine, not an error
        vm.stop()
    }

    func test_approve_isTerminalAndStopsPolling() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.approve()
        XCTAssertEqual(vm.phase, .approved)
        XCTAssertEqual(fake.approvedCodes, ["KTNM-3VQ8"])
        let countAtApprove = fake.statusCount
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.statusCount, countAtApprove) // poll loop stopped
    }

    func test_approve_expired_regeneratesWithNotice() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 5))]
        fake.approveResult = .failure(JournalAPIError.notFound)
        fake.startResults = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.approve()
        XCTAssertEqual(vm.phase, .showing(code: "WXYZ-2345"))
        XCTAssertEqual(vm.noticeMessage, "Code expired — showing a fresh one")
        vm.stop()
    }

    func test_deny_isTerminal() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.deny()
        XCTAssertEqual(vm.phase, .denied)
        XCTAssertEqual(fake.deniedCodes, ["KTNM-3VQ8"])
    }

    func test_stop_haltsPolling() async {
        let fake = FakeDeviceLinker()
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(fake.statusCount >= 1)
        vm.stop()
        let count = fake.statusCount
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.statusCount, count)
    }

    func test_transportErrorOnStatus_keepsShowingAndKeepsPolling() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.failure(JournalAPIError.transport("offline")),
                             .success(.waiting(expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(fake.statusCount >= 2)
        XCTAssertEqual(vm.phase, .showing(code: "KTNM-3VQ8")) // never dropped to an error screen
        vm.stop()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && swift test --filter DeviceLinkViewModelTests`
Expected: COMPILE FAILURE — `DeviceLinkViewModel` / `DeviceLinking` don't exist.

- [ ] **Step 3: Implement `DeviceLinkViewModel.swift`**

```swift
import Foundation
import MatronJournal

/// The show-QR slice of `JournalAPI`, extracted so the view model tests
/// against a fake (same pattern as `DevicesProviding`).
public protocol DeviceLinking: Sendable {
    func linkStart() async throws -> LinkStart
    func linkStatus() async throws -> LinkStatus
    func linkApprove(code: String) async throws
    func linkDeny(code: String) async throws
}

extension JournalAPI: DeviceLinking {}

/// Drives the Settings → "Link a Device" screen: start a session, render
/// the QR, poll status, and on a claim show the approve card (claimant
/// name + IP — the mandatory confirm-tap of the design; scanning alone
/// never signs anything in).
///
/// Lifecycle: `start()` on appear, `stop()` on disappear. Status 404 while
/// on screen means the session expired — routine, so the QR silently
/// regenerates. Approve/deny are terminal; the approve side does not wait
/// for the claimant's final poll.
@Observable @MainActor
public final class DeviceLinkViewModel {
    public enum Phase: Equatable {
        case loading
        case showing(code: String)
        case claimed(deviceName: String, requesterIP: String)
        case approved
        case denied
        /// 404 on start: the server predates /link/*.
        case unsupported
        case error(String)
    }

    public private(set) var phase: Phase = .loading
    /// One-line banner above a regenerated QR ("Code expired — showing a
    /// fresh one") or under a failed tap ("Couldn't approve — try again.").
    public private(set) var noticeMessage: String?
    /// True while an approve/deny round-trip is in flight; reentrant taps
    /// are ignored and the poll loop skips regeneration to avoid racing
    /// the in-flight request.
    public private(set) var isSubmitting = false

    /// The full QR payload for the current code (nil unless `.showing`).
    public var qrPayload: String? {
        guard case .showing(let code) = phase else { return nil }
        return LinkURI.format(server: serverURL, code: code)
    }

    private let api: any DeviceLinking
    private let serverURL: URL
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// The active session's display code — what approve/deny send back as
    /// the belt-and-braces intent check.
    private var currentCode: String?

    public init(api: any DeviceLinking, serverURL: URL,
                pollInterval: Duration = .seconds(2),
                errorPollInterval: Duration = .seconds(5)) {
        self.api = api
        self.serverURL = serverURL
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func start() async {
        stop()
        noticeMessage = nil
        phase = .loading
        await startSession()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func approve() async {
        guard case .claimed = phase, !isSubmitting, let code = currentCode else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await api.linkApprove(code: code)
            stop()
            phase = .approved
        } catch JournalAPIError.notFound {
            noticeMessage = "Code expired — showing a fresh one"
            stop()
            await startSession()
        } catch JournalAPIError.conflict {
            // Nothing left to approve (raced expiry/replacement) — same
            // recovery as expiry: fresh code.
            noticeMessage = "Code expired — showing a fresh one"
            stop()
            await startSession()
        } catch {
            noticeMessage = "Couldn't approve — try again."
        }
    }

    public func deny() async {
        guard case .claimed = phase, !isSubmitting, let code = currentCode else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await api.linkDeny(code: code)
            stop()
            phase = .denied
        } catch JournalAPIError.notFound {
            stop()
            await startSession()
        } catch {
            noticeMessage = "Couldn't deny — try again."
        }
    }

    private func startSession() async {
        do {
            let started = try await api.linkStart()
            currentCode = started.code
            phase = .showing(code: started.code)
            startPolling()
        } catch JournalAPIError.notFound {
            phase = .unsupported
        } catch {
            phase = .error("Couldn't reach the server — try again.")
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if self.isSubmitting { continue } // don't race an in-flight tap
                do {
                    switch try await self.api.linkStatus() {
                    case .waiting:
                        break // phase already .showing
                    case .claimed(let deviceName, let requesterIP, _):
                        if case .claimed = self.phase {} else {
                            self.phase = .claimed(deviceName: deviceName, requesterIP: requesterIP)
                        }
                    }
                    interval = self.pollInterval
                } catch JournalAPIError.notFound {
                    // Expired (routine): regenerate silently. startSession
                    // spawns a fresh poll task; this one must end.
                    guard !Task.isCancelled, !self.isSubmitting else { return }
                    await self.startSession()
                    return
                } catch JournalAPIError.unauthenticated {
                    // Starter signed out / revoked mid-flow: the host view
                    // closes on its own sign-out path; stop quietly.
                    return
                } catch {
                    interval = self.errorPollInterval // network loss: back off, keep trying
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && swift test --filter DeviceLinkViewModelTests`
Expected: PASS, 9/9.

- [ ] **Step 5: Run the whole ViewModels test bundle (regression)**

Run: `cd MatronShared && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/ViewModels/DeviceLinkViewModel.swift MatronShared/Tests/ViewModelTests/DeviceLinkViewModelTests.swift
git commit -m "Add DeviceLinkViewModel (show-QR state machine)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: LinkSignInViewModel (claimant side)

**Files:**
- Create: `MatronShared/Sources/ViewModels/LinkSignInViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/LinkSignInViewModelTests.swift`

**Interfaces:**
- Consumes: `LinkClaim`, `LinkPollResult`, `LinkApproval`, `JournalAPIError`, `LinkURI`, `PairingCode` (MatronJournal); `AuthService`, `ServerURLValidator`, `AuthError` (MatronAuth); `UserSession` (MatronModels). The test fake for auth mirrors `MatronShared/Tests/AuthTests/FakeAuthService.swift` but lives in ViewModelTests (targets don't share test sources).
- Produces (Tasks 7-8 render against this):
  - `protocol LinkClaiming: Sendable` (`linkClaim(code:deviceName:)`, `linkPoll(claimToken:)`) + `extension JournalAPI: LinkClaiming`
  - `LinkSignInViewModel(auth:deviceDisplayName:apiFactory:pollInterval:errorPollInterval:)`, `phase: Phase` (`idle | claiming | waitingForApproval | error(String) | signedIn(UserSession)`), `serverURL: String`, `codeInput: String` (auto-formatting), `func handleScanned(_ payload: String) async`, `func submitManual() async`, `func cancel()`

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/LinkSignInViewModelTests.swift`:

```swift
import XCTest
@testable import MatronViewModels
@testable import MatronJournal
@testable import MatronAuth
import MatronModels

private final class FakeLinkClaimer: LinkClaiming, @unchecked Sendable {
    var claimResult: Result<LinkClaim, Error> = .success(LinkClaim(claimToken: "aa11", expiresIn: 60))
    /// Consumed one per poll; last repeats when dry.
    var pollScript: [Result<LinkPollResult, Error>] = [.success(.pending)]
    private(set) var claimedCodes: [String] = []
    private(set) var claimedDeviceNames: [String] = []
    private(set) var pollCount = 0

    func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
        claimedCodes.append(code)
        claimedDeviceNames.append(deviceName)
        return try claimResult.get()
    }
    func linkPoll(claimToken: String) async throws -> LinkPollResult {
        pollCount += 1
        let result = pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]
        return try result.get()
    }
}

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

@MainActor
final class LinkSignInViewModelTests: XCTestCase {
    private func makeVM(_ fake: FakeLinkClaimer, auth: FakeAuth = FakeAuth()) -> (LinkSignInViewModel, FakeAuth) {
        let vm = LinkSignInViewModel(auth: auth, deviceDisplayName: "Matron iOS",
                                     apiFactory: { _ in fake },
                                     pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        return (vm, auth)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isSignedIn(_ vm: LinkSignInViewModel) -> Bool {
        if case .signedIn = vm.phase { return true }
        return false
    }

    func test_scanned_happyPath_buildsAndPersistsSession() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.pending),
                           .success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, auth) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        await waitUntil(self.isSignedIn(vm))
        let expected = UserSession(userID: "dan", deviceID: "42",
                                   homeserverURL: URL(string: "https://chat.example.com")!,
                                   accessToken: "tok99")
        XCTAssertEqual(vm.phase, .signedIn(expected))
        XCTAssertEqual(auth.persistedSessions, [expected]) // persisted BEFORE phase flips
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"])
        XCTAssertEqual(fake.claimedDeviceNames, ["Matron iOS"]) // same name password login sends
    }

    func test_scanned_notALink_and_wrongVersion() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        await vm.handleScanned("https://a-random-website.example/qr")
        XCTAssertEqual(vm.phase, .error("Not a Matron sign-in code."))
        await vm.handleScanned("matron://link?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        XCTAssertEqual(vm.phase, .error("This QR code needs a newer version of Matron."))
    }

    func test_manual_happyPath_normalizesCodeAndURL() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, _) = makeVM(fake)
        vm.serverURL = "chat.example.com" // ServerURLValidator adds https://
        vm.codeInput = "ktnm3vq8"
        XCTAssertEqual(vm.codeInput, "KTNM-3VQ8") // auto-format like PairingViewModel
        await vm.submitManual()
        await waitUntil(self.isSignedIn(vm))
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"])
        guard case .signedIn(let session) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertEqual(session.homeserverURL.absoluteString, "https://chat.example.com")
    }

    func test_manual_invalidURL_errors() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        vm.serverURL = "not a url"
        vm.codeInput = "KTNM-3VQ8"
        await vm.submitManual()
        XCTAssertEqual(vm.phase, .error("That doesn't look like a valid server URL."))
    }

    func test_claim_conflict_notFound_rateLimited() async {
        for (error, message) in [
            (JournalAPIError.conflict, "This code was already used. Generate a new one on your signed-in device."),
            (JournalAPIError.notFound, "Code not recognized or expired. Show a fresh QR code and try again."),
            (JournalAPIError.rateLimited, "Too many attempts — try again in a minute."),
        ] {
            let fake = FakeLinkClaimer()
            fake.claimResult = .failure(error)
            let (vm, _) = makeVM(fake)
            await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
            XCTAssertEqual(vm.phase, .error(message))
        }
    }

    func test_poll_denied() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.denied)]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(vm.phase == .error("Sign-in was denied on the other device."))
        XCTAssertEqual(vm.phase, .error("Sign-in was denied on the other device."))
    }

    func test_poll_expired() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.failure(JournalAPIError.notFound)]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(vm.phase == .error("Sign-in expired. Scan again."))
        XCTAssertEqual(vm.phase, .error("Sign-in expired. Scan again."))
    }

    func test_poll_transportError_backsOffAndKeepsPolling() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.failure(JournalAPIError.transport("offline")),
                           .success(.approved(LinkApproval(token: "t", deviceID: 1, userID: 1, username: "dan")))]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(self.isSignedIn(vm))
        XCTAssertTrue(isSignedIn(vm)) // one dropped poll never kills the flow
    }

    func test_cancel_stopsPollingAndReturnsToIdle() async {
        let fake = FakeLinkClaimer()
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(fake.pollCount >= 1)
        vm.cancel()
        XCTAssertEqual(vm.phase, .idle)
        let count = fake.pollCount
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.pollCount, count)
    }

    func test_persistFailure_surfacesError() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "t", deviceID: 1, userID: 1, username: "dan")))]
        let auth = FakeAuth()
        auth.persistError = NSError(domain: "disk", code: 1)
        let (vm, _) = makeVM(fake, auth: auth)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil({ if case .error = vm.phase { return true }; return false }())
        XCTAssertEqual(vm.phase, .error("Signed in, but couldn't save the session — try again."))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd MatronShared && swift test --filter LinkSignInViewModelTests`
Expected: COMPILE FAILURE — `LinkSignInViewModel` / `LinkClaiming` don't exist.

- [ ] **Step 3: Implement `LinkSignInViewModel.swift`**

```swift
import Foundation
import MatronAuth
import MatronJournal
import MatronModels

/// The claimant slice of `JournalAPI` (both calls unauthenticated),
/// extracted so the view model tests against a fake.
public protocol LinkClaiming: Sendable {
    func linkClaim(code: String, deviceName: String) async throws -> LinkClaim
    func linkPoll(claimToken: String) async throws -> LinkPollResult
}

extension JournalAPI: LinkClaiming {}

/// Signs a NEW device in from a link code — the claimant half of QR
/// device-link login. Two entry points: `handleScanned` (camera, full
/// `matron://link` URI) and `submitManual` (typed server URL + code).
/// Both converge on claim → poll → build the same `UserSession` shape
/// password login builds (`userID` = the server-returned username) →
/// `auth.persist` → `.signedIn`, which the host view forwards to the
/// normal `onSignedIn` path.
@Observable @MainActor
public final class LinkSignInViewModel {
    public enum Phase: Equatable {
        case idle
        case claiming
        case waitingForApproval
        case error(String)
        case signedIn(UserSession)
    }

    /// Manual path. On iOS the sign-in form's server field seeds this; on
    /// Mac the code field lives on the sign-in form next to it.
    public var serverURL: String = ""
    /// Auto-formatted as `XXXX-XXXX` while typing, like PairingViewModel.
    public var codeInput: String = "" {
        didSet {
            let formatted = PairingCode.display(codeInput)
            if formatted != codeInput {
                codeInput = formatted // re-enters didSet once; equality stops it
            }
        }
    }

    public private(set) var phase: Phase = .idle

    private let auth: AuthService
    private let deviceDisplayName: String
    private let apiFactory: @Sendable (URL) -> any LinkClaiming
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    private var pollTask: Task<Void, Never>?

    /// `apiFactory` exists for tests; the default builds a real JournalAPI
    /// against whatever server the QR names.
    public init(auth: AuthService, deviceDisplayName: String,
                apiFactory: (@Sendable (URL) -> any LinkClaiming)? = nil,
                pollInterval: Duration = .seconds(2),
                errorPollInterval: Duration = .seconds(5)) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
        self.apiFactory = apiFactory ?? { JournalAPI(serverURL: $0) }
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func handleScanned(_ payload: String) async {
        do {
            let (server, code) = try LinkURI.parse(payload)
            await claim(server: server, code: code)
        } catch LinkURI.ParseError.unsupportedVersion {
            phase = .error("This QR code needs a newer version of Matron.")
        } catch {
            phase = .error("Not a Matron sign-in code.")
        }
    }

    public func submitManual() async {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, PairingCode.isPlausible(codeInput) else { return }
        let url: URL
        do {
            url = try ServerURLValidator.normalize(raw)
        } catch {
            phase = .error("That doesn't look like a valid server URL.")
            return
        }
        await claim(server: url, code: PairingCode.display(codeInput))
    }

    /// Back out: stop polling and return to the sign-in form. The show side
    /// still sees `claimed` and can deny or let the code expire.
    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func claim(server: URL, code: String) async {
        guard phase != .claiming, phase != .waitingForApproval else { return }
        phase = .claiming
        let api = apiFactory(server)
        do {
            let claim = try await api.linkClaim(code: code, deviceName: deviceDisplayName)
            phase = .waitingForApproval
            startPolling(api: api, server: server, claimToken: claim.claimToken)
        } catch JournalAPIError.conflict {
            phase = .error("This code was already used. Generate a new one on your signed-in device.")
        } catch JournalAPIError.notFound {
            phase = .error("Code not recognized or expired. Show a fresh QR code and try again.")
        } catch JournalAPIError.rateLimited {
            phase = .error("Too many attempts — try again in a minute.")
        } catch {
            phase = .error("Couldn't reach the server — try again.")
        }
    }

    private func startPolling(api: any LinkClaiming, server: URL, claimToken: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                do {
                    switch try await api.linkPoll(claimToken: claimToken) {
                    case .pending:
                        interval = self.pollInterval
                    case .denied:
                        self.phase = .error("Sign-in was denied on the other device.")
                        return
                    case .approved(let approval):
                        let session = UserSession(userID: approval.username,
                                                  deviceID: String(approval.deviceID),
                                                  homeserverURL: server,
                                                  accessToken: approval.token)
                        do {
                            try self.auth.persist(session)
                        } catch {
                            self.phase = .error("Signed in, but couldn't save the session — try again.")
                            return
                        }
                        self.phase = .signedIn(session)
                        return
                    }
                } catch JournalAPIError.notFound {
                    self.phase = .error("Sign-in expired. Scan again.")
                    return
                } catch {
                    interval = self.errorPollInterval // network loss: back off, keep trying
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd MatronShared && swift test --filter LinkSignInViewModelTests`
Expected: PASS, 10/10.

- [ ] **Step 5: Run the full package suite**

Run: `cd MatronShared && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/ViewModels/LinkSignInViewModel.swift MatronShared/Tests/ViewModelTests/LinkSignInViewModelTests.swift
git commit -m "Add LinkSignInViewModel (claimant state machine)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: iOS show side — "Link a Device" screen

**Files:**
- Create: `Matron/Features/Settings/DeviceLinkView.swift`
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (add `linkAPI` param + nav link, Devices section lines 27-35)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (DeviceSettingsView construction ~line 154)
- Modify: `Matron/App/AppDependencies.swift` (factory beside `devicesService(for:)` line 149)

**Interfaces:**
- Consumes: `DeviceLinkViewModel` + `DeviceLinking` (Task 3), `QRCodeView` (Task 2), `core(for: session).api` (AppDependencies).
- Produces: `AppDependencies.deviceLinkService(for:) -> any DeviceLinking` (this task, iOS side); the pattern Task 6 mirrors on Mac.

- [ ] **Step 1: Add the dependency factory**

In `Matron/App/AppDependencies.swift`, directly after `devicesService(for:)` (line 149-151):

```swift
    /// Show-QR surface (Settings → Link a Device). Same session-scoped
    /// `JournalAPI` as the devices surface; protocol slice for testability.
    func deviceLinkService(for session: UserSession) -> any DeviceLinking {
        core(for: session).api
    }
```

- [ ] **Step 2: Create `DeviceLinkView.swift`**

```swift
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → "Link a Device" (iOS): shows a QR the new device scans, then
/// the approve card once someone claims it. The QR self-refreshes on
/// expiry for as long as the screen is open.
struct DeviceLinkView: View {
    @State private var viewModel: DeviceLinkViewModel

    init(api: any DeviceLinking, serverURL: URL) {
        _viewModel = State(initialValue: DeviceLinkViewModel(api: api, serverURL: serverURL))
    }

    var body: some View {
        Form {
            if let notice = viewModel.noticeMessage {
                Section {
                    Text(notice).font(.callout).foregroundStyle(.orange)
                }
            }
            switch viewModel.phase {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .showing(let code):
                showing(code)
            case .claimed(let deviceName, let requesterIP):
                claimed(deviceName: deviceName, requesterIP: requesterIP)
            case .approved:
                Section {
                    Label("Approved — finishing sign-in on the other device.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .denied:
                Section {
                    Label("Denied. No device was signed in.", systemImage: "hand.raised.fill")
                        .foregroundStyle(.secondary)
                }
            case .unsupported:
                Section {
                    Text("Server doesn't support device linking yet.")
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { Task { await viewModel.start() } }
                }
            }
        }
        .navigationTitle("Link a Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    @ViewBuilder private func showing(_ code: String) -> some View {
        Section {
            VStack(spacing: 16) {
                if let payload = viewModel.qrPayload {
                    QRCodeView(string: payload)
                        .frame(width: 220, height: 220)
                }
                // The camera-less fallback: the code as selectable text,
                // typed into "Have a link code?" on the new device.
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } footer: {
            Text("On your new device, open Matron and choose “Scan QR code” — or type the code under “Have a link code?”. Codes refresh automatically.")
        }
    }

    @ViewBuilder private func claimed(deviceName: String, requesterIP: String) -> some View {
        Section {
            Text("**\(deviceName)** at **\(requesterIP)** wants to sign in to your account. Only approve if this is your device.")
                .font(.callout)
        }
        Section {
            Button("Approve") { Task { await viewModel.approve() } }
                .bold()
                .disabled(viewModel.isSubmitting)
            Button("Deny", role: .destructive) { Task { await viewModel.deny() } }
                .disabled(viewModel.isSubmitting)
        } footer: {
            Text("Approving signs that device in with full access to your account.")
        }
    }
}
```

- [ ] **Step 3: Add the Settings entry**

In `DeviceSettingsView.swift`, change the property block (lines 13-15) to:

```swift
    let session: UserSession
    var devicesAPI: (any DevicesProviding)? = nil
    var linkAPI: (any DeviceLinking)? = nil
    var onSignOut: (() -> Void)? = nil
```

and the Devices section (lines 27-35) to:

```swift
            if devicesAPI != nil || linkAPI != nil {
                Section("Devices") {
                    if let devicesAPI {
                        NavigationLink {
                            DevicesView(api: devicesAPI, onSelfRevoked: { onSignOut?() })
                        } label: {
                            Label("Manage Devices", systemImage: "laptopcomputer.and.iphone")
                        }
                    }
                    if let linkAPI {
                        NavigationLink {
                            DeviceLinkView(api: linkAPI, serverURL: session.homeserverURL)
                        } label: {
                            Label("Link a Device", systemImage: "qrcode")
                        }
                    }
                }
            }
```

In `ChatListView.swift` (~line 154), add the argument to the existing construction:

```swift
                    DeviceSettingsView(
                        session: session,
                        devicesAPI: deps?.devicesService(for: session),
                        linkAPI: deps?.deviceLinkService(for: session),
                        onSignOut: {
```

(`MatronViewModels` is already imported in both files.)

- [ ] **Step 4: Build the iOS app**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Settings/DeviceLinkView.swift Matron/Features/Settings/DeviceSettingsView.swift \
        Matron/Features/ChatList/ChatListView.swift Matron/App/AppDependencies.swift
git commit -m "Add iOS Link-a-Device screen (show QR + approve card)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Mac show side — Settings tab

**Files:**
- Create: `MatronMac/Features/Settings/MacDeviceLinkView.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (Settings `TabView`, lines ~153-166)
- Modify: `MatronMac/App/AppDependencies.swift` (factory beside its `devicesService(for:)`)

**Interfaces:**
- Consumes: `DeviceLinkViewModel`, `QRCodeView`, Mac `AppDependencies.core(for:)` (mirror of Task 5's factory).
- Produces: nothing new — Mac rendering of the Task 3 state machine.

- [ ] **Step 1: Add the Mac dependency factory**

In `MatronMac/App/AppDependencies.swift`, next to its `devicesService(for:)`:

```swift
    /// Show-QR surface (Settings → Link a Device). Same session-scoped
    /// `JournalAPI` as the devices surface; protocol slice for testability.
    func deviceLinkService(for session: UserSession) -> any DeviceLinking {
        core(for: session).api
    }
```

- [ ] **Step 2: Create `MacDeviceLinkView.swift`**

```swift
#if os(macOS)
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → "Link a Device" (Mac). Same state machine as iOS
/// (`DeviceLinkViewModel`); Mac only ever SHOWS codes — scanning is a
/// camera-device job, and the Mac claimant path is the manual code field
/// on the sign-in view.
struct MacDeviceLinkView: View {
    @State private var viewModel: DeviceLinkViewModel

    init(api: any DeviceLinking, serverURL: URL) {
        _viewModel = State(initialValue: DeviceLinkViewModel(api: api, serverURL: serverURL))
    }

    var body: some View {
        VStack(spacing: 16) {
            if let notice = viewModel.noticeMessage {
                Text(notice).font(.callout).foregroundStyle(.orange)
            }
            switch viewModel.phase {
            case .loading:
                ProgressView()
            case .showing(let code):
                if let payload = viewModel.qrPayload {
                    QRCodeView(string: payload)
                        .frame(width: 200, height: 200)
                }
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text("On your new device, open Matron and choose “Scan QR code” — or type the code under “Have a link code?”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .claimed(let deviceName, let requesterIP):
                Text("**\(deviceName)** at **\(requesterIP)** wants to sign in to your account. Only approve if this is your device.")
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Deny", role: .destructive) { Task { await viewModel.deny() } }
                        .disabled(viewModel.isSubmitting)
                    Button("Approve") { Task { await viewModel.approve() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isSubmitting)
                }
            case .approved:
                Label("Approved — finishing sign-in on the other device.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Denied. No device was signed in.", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
            case .unsupported:
                Text("Server doesn't support device linking yet.")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again") { Task { await viewModel.start() } }
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
#endif
```

- [ ] **Step 3: Add the Settings tab**

In `MatronMacApp.swift`, inside the signed-in `TabView` (after the Devices tab, ~line 162), add:

```swift
                    MacDeviceLinkView(
                        api: dependencies.deviceLinkService(for: session),
                        serverURL: session.homeserverURL
                    )
                    .tabItem { Label("Link a Device", systemImage: "qrcode") }
```

- [ ] **Step 4: Build the Mac app**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Settings/MacDeviceLinkView.swift MatronMac/App/MatronMacApp.swift MatronMac/App/AppDependencies.swift
git commit -m "Add Mac Link-a-Device settings tab

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: iOS scan side — camera sheet + sign-in integration

**Files:**
- Create: `Matron/Features/Onboarding/QRScannerView.swift`
- Modify: `Matron/Features/Onboarding/SignInView.swift`
- Modify: `Matron/App/MatronApp.swift` (SignInView construction, lines 124-137)
- Modify: `project.yml` (iOS target info block, beside `NSMicrophoneUsageDescription` ~line 98)

**Interfaces:**
- Consumes: `LinkSignInViewModel` (Task 4). `AVFoundation` (system).
- Produces: nothing downstream — final iOS integration.

- [ ] **Step 1: Add the camera usage string to `project.yml`**

In the **iOS** target's info properties, directly after the `NSMicrophoneUsageDescription` line (~line 98):

```yaml
        # Camera usage string for the sign-in QR scanner (device-link
        # login). Managed here so `xcodegen generate` keeps it in the
        # generated plist.
        NSCameraUsageDescription: Matron uses the camera to scan sign-in QR codes from your other devices.
```

(iOS target only — the Mac target has no scanner.)

- [ ] **Step 2: Create `QRScannerView.swift`**

```swift
import SwiftUI
import AVFoundation

/// Full-screen QR scanner for sign-in (device-link login). QR metadata
/// objects only; fires `onScanned` once per presentation with the raw
/// payload string. Camera-permission denial renders an explanation with a
/// Settings deep-link — the manual code path remains on the sign-in form.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    @State private var authorized: Bool?

    var body: some View {
        NavigationStack {
            Group {
                switch authorized {
                case .none:
                    ProgressView()
                case .some(true):
                    CameraPreview(onScanned: { payload in
                        dismiss()
                        onScanned(payload)
                    })
                    .ignoresSafeArea()
                case .some(false):
                    VStack(spacing: 12) {
                        Text("Matron needs camera access to scan sign-in codes.")
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        Text("Or type the code instead — it's shown under the QR on your other device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                authorized = true
            case .notDetermined:
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            default:
                authorized = false
            }
        }
    }
}

/// UIKit capture layer: session + metadata output restricted to `.qr`.
private struct CameraPreview: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScanned = onScanned
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var didFire = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // startRunning blocks; keep it off the main thread (Apple guidance).
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFire,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr, let payload = object.stringValue
        else { return }
        didFire = true // one payload per presentation — a QR in frame fires repeatedly
        onScanned?(payload)
    }
}
```

- [ ] **Step 3: Integrate into `SignInView.swift`**

Replace the whole file with:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct SignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    var onSignedIn: (UserSession) -> Void

    @State private var showingScanner = false
    @State private var showingManualCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("app-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                .listRowBackground(Color.clear)
                if case .waitingForApproval = linkViewModel.phase {
                    linkWaiting
                } else {
                    Section("Server") {
                        // Placeholder kept URL-shape-free because iOS Form's
                        // data detection styles `https://…` placeholders as
                        // tappable blue link text — looks like an error /
                        // link, not a hint.
                        TextField("Homeserver URL", text: $viewModel.serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("signin.server")
                    }
                    Section("Credentials") {
                        TextField("Username", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin.username")
                        SecureField("Password", text: $viewModel.password)
                            .accessibilityIdentifier("signin.password")
                    }
                    if case .error(let message) = viewModel.state {
                        Section {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                    Section {
                        Button {
                            Task { await viewModel.submit() }
                        } label: {
                            if case .busy = viewModel.state {
                                ProgressView()
                            } else {
                                Text("Sign in")
                            }
                        }
                        .disabled({
                            if case .busy = viewModel.state { return true }
                            return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
                        }())
                        .accessibilityIdentifier("signin.submit")
                    }
                    linkSignIn
                }
            }
            .navigationTitle("Sign in to Matron")
            .onChange(of: viewModel.state) { _, new in
                if case .signedIn(let session) = new {
                    onSignedIn(session)
                }
            }
            .onChange(of: linkViewModel.phase) { _, new in
                if case .signedIn(let session) = new {
                    onSignedIn(session)
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView { payload in
                    Task { await linkViewModel.handleScanned(payload) }
                }
            }
        }
    }

    /// "Or sign in from another device": camera scan + manual code entry.
    @ViewBuilder private var linkSignIn: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("signin.scan")
            Button(showingManualCode ? "Hide link code" : "Have a link code?") {
                showingManualCode.toggle()
            }
            .font(.callout)
            if showingManualCode {
                TextField("XXXX-XXXX", text: $linkViewModel.codeInput)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("signin.linkcode")
                Button("Sign in with code") {
                    // The manual path shares the form's server field.
                    linkViewModel.serverURL = viewModel.serverURL
                    Task { await linkViewModel.submitManual() }
                }
                .disabled(viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9)
            }
        } header: {
            Text("From another device")
        } footer: {
            if case .error(let message) = linkViewModel.phase {
                Text(message).foregroundStyle(.red)
            } else if showingManualCode {
                Text("On your signed-in device: Settings → Link a Device. Enter the server URL above and the code shown under the QR.")
            } else {
                Text("Signed in on another device? Show its QR under Settings → Link a Device and scan it here.")
            }
        }
    }

    @ViewBuilder private var linkWaiting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for approval on your other device…")
            }
            Button("Cancel", role: .cancel) { linkViewModel.cancel() }
        } footer: {
            Text("Approve the request on your signed-in device to finish.")
        }
    }
}
```

- [ ] **Step 4: Wire the view model in `MatronApp.swift`**

Change the SignInView construction (lines 124-126) to:

```swift
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        linkViewModel: LinkSignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        onSignedIn: { session in
```

(the `onSignedIn` closure body is unchanged — link sign-in reuses the same teardown-gated path).

- [ ] **Step 5: Build the iOS app**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED. Then run the iOS test bundle:

```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: TEST SUCCEEDED (no iOS tests reference SignInView's init directly today; if any fail on the new parameter, fix the call sites the same way as MatronApp.swift).

- [ ] **Step 6: Commit**

```bash
git add Matron/Features/Onboarding/QRScannerView.swift Matron/Features/Onboarding/SignInView.swift \
        Matron/App/MatronApp.swift project.yml
git commit -m "Add iOS QR-scan and link-code sign-in

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Mac manual link sign-in

**Files:**
- Modify: `MatronMac/Features/Onboarding/MacSignInView.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (MacSignInView construction, lines 113-115)

**Interfaces:**
- Consumes: `LinkSignInViewModel` (Task 4).
- Produces: nothing downstream — final Mac integration.

- [ ] **Step 1: Integrate into `MacSignInView.swift`**

Replace the body-relevant parts so the full file reads:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct MacSignInView: View {
    @State var viewModel: SignInViewModel
    @State var linkViewModel: LinkSignInViewModel
    var onSignedIn: (UserSession) -> Void

    @State private var showingLinkCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image("app-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("Sign in to Matron")
                .font(.title2.weight(.semibold))

            if case .waitingForApproval = linkViewModel.phase {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for approval on your other device…")
                    Button("Cancel") { linkViewModel.cancel() }
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField(label: "Server") {
                        TextField("https://matrix.example.com", text: $viewModel.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin.server")
                    }
                    LabeledField(label: "Username") {
                        TextField("alice", text: $viewModel.username)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin.username")
                    }
                    LabeledField(label: "Password") {
                        SecureField("", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("signin.password")
                    }
                }

                if case .error(let message) = viewModel.state {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if case .busy = viewModel.state {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Sign in")
                            .frame(maxWidth: .infinity)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("signin.submit")
                .disabled({
                    if case .busy = viewModel.state { return true }
                    return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
                }())

                // Camera-less claimant path: type the code shown under the
                // QR on a signed-in device (Settings → Link a Device).
                Button(showingLinkCode ? "Hide link code" : "Have a link code?") {
                    showingLinkCode.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)

                if showingLinkCode {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledField(label: "Link code") {
                            TextField("XXXX-XXXX", text: $linkViewModel.codeInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("signin.linkcode")
                        }
                        Button("Sign in with code") {
                            linkViewModel.serverURL = viewModel.serverURL
                            Task { await linkViewModel.submitManual() }
                        }
                        .disabled(viewModel.serverURL.isEmpty || linkViewModel.codeInput.count < 9)
                    }
                    if case .error(let message) = linkViewModel.phase {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 520)
        .onChange(of: viewModel.state) { _, new in
            if case .signedIn(let session) = new {
                onSignedIn(session)
            }
        }
        .onChange(of: linkViewModel.phase) { _, new in
            if case .signedIn(let session) = new {
                onSignedIn(session)
            }
        }
    }
}

private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field
        }
    }
}
```

- [ ] **Step 2: Wire the view model in `MatronMacApp.swift`**

Change the MacSignInView construction (lines 113-115) to:

```swift
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        linkViewModel: LinkSignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        onSignedIn: { session in
```

(closure body unchanged).

- [ ] **Step 3: Build the Mac app and run its tests**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED / TEST SUCCEEDED.

- [ ] **Step 4: Run the shared package suite one last time**

Run: `cd MatronShared && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Onboarding/MacSignInView.swift MatronMac/App/MatronMacApp.swift
git commit -m "Add Mac link-code sign-in path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
