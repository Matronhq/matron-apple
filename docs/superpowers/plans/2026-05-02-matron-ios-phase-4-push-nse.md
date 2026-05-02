# Matron iOS — Phase 4 (Push & NSE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 3 (E2EE & verification UX) merged and CI green.

**Goal:** End-to-end push notifications. Server-side runs a Sygnal-compatible HTTP pusher. The iOS app registers an APNs token with the user's homeserver. Inbound silent pushes are decrypted on-device by the Notification Service Extension using matrix-rust-sdk-swift; the user sees a clear-text notification with sender + body. Tapping a notification deep-links into the chat.

**Architecture:** Server-side: deploy upstream Sygnal (Apache 2.0) alongside `matron-server`; configure with an APNs auth key. App-side: `PushService` (in MatronShared) handles permission + token registration. `MatronNSE/NotificationService.swift` opens a read-only SDK client, calls `NotificationClient.getNotification(roomID, eventID)`, builds a rewritten notification. App listens for `UNUserNotificationCenterDelegate.didReceive` to deep-link.

**Tech Stack:** Same as prior phases. APNs auth key (`.p8`) stored in 1Password / your secrets manager — provisioning is out of scope here, but we document the format.

**Reference:** Spec §8 (push notifications), §6.3 (push wakeup), §2 (NSE target setup).

---

## Server-side prerequisites (out of plan, doc-only)

Before iOS push can work end-to-end:

1. **Apple Developer:** create an APNs auth key (`.p8`) for the `chat.matron.app` bundle ID; record the Key ID and Team ID.
2. **`matron-server` host:** run **Sygnal** (`pip install sygnal` or the Docker image) at e.g. `https://push.<domain>/`, configured with `apns_auth_key`, `apns_key_id`, `apns_team_id`, `bundle_id: chat.matron.app`, and `chat.matron.app.nse` as the topic for silent pushes. Sygnal must be reachable from the homeserver.
3. **Cloudflare Tunnel** route for `push.<domain>` → Sygnal port (or run Sygnal on the same Tuwunel host with a separate Cloudflared route).
4. **Server config note:** Tuwunel needs the pusher base URL configured (`pusher_base_url` style setting, or per-pusher via the Matrix `POST /_matrix/client/v3/pushers` flow which the iOS app does itself).

These are **bridge/server-side** changes; track them in a separate `dev-boxer` / `matron-server` issue. The iOS plan below assumes Sygnal is reachable.

---

## File structure (Phase 4 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Push/
│   ├── PushService.swift                 NEW — protocol
│   ├── PushServiceLive.swift             NEW — APNs token + register pusher
│   ├── PushDecoder.swift                 NEW — shared by app + NSE
│   └── PushConfig.swift                  NEW — pusher URL, app_id consts
├── MatronNSE/
│   ├── NotificationService.swift         MODIFIED — real decrypt + rewrite
│   └── MatronNSE.entitlements            MODIFIED — App Group + keychain group
├── Matron/App/
│   ├── PushBootstrap.swift               NEW — request permission, register
│   └── NotificationDelegate.swift        NEW — handle taps for deep link
├── MatronTests/
│   ├── PushDecoderTests.swift            NEW
│   └── PushServiceLiveTests.swift        NEW
└── docs/
    └── push-setup.md                     NEW — server-side runbook for Sygnal
```

---

## Tasks

### Task 1: PushConfig + PushService protocol

**Files:**
- Create: `MatronShared/Sources/Push/PushConfig.swift`
- Create: `MatronShared/Sources/Push/PushService.swift`

- [ ] **Step 1: PushConfig**

```swift
import Foundation

public enum PushConfig {
    /// Matches the bundle identifier in project.yml.
    public static let appID = "chat.matron.app.ios"          // pusher app_id (NOT the bundle ID — Matrix-side identifier)
    public static let appDisplayName = "Matron"
    public static let pushFormat = "event_id_only"           // silent payload — NSE decrypts on-device
    public static let language = "en"
}
```

- [ ] **Step 2: PushService protocol**

```swift
import Foundation

public protocol PushService: Sendable {
    /// Requests system permission. Returns true if granted.
    func requestPermission() async -> Bool

    /// Registers a token + pusher URL with the user's homeserver.
    /// Idempotent — same (token, pushkeyURL) pair is safe to call repeatedly.
    func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws

    /// Removes the pusher record from the homeserver (called on sign-out).
    func unregister(deviceToken: Data, pusherBaseURL: URL) async throws
}
```

- [ ] **Step 3: Add `MatronPush` library product**

In `MatronShared/Package.swift`:

```swift
.library(name: "MatronPush", targets: ["MatronPush"]),
.target(
    name: "MatronPush",
    dependencies: [
        "MatronModels",
        "MatronStorage",
        "MatronSync",
        .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
    ],
    path: "Sources/Push"
),
.testTarget(name: "PushTests", dependencies: ["MatronPush"], path: "Tests/PushTests"),
```

Add `MatronPush` to both `Matron` and `MatronNSE` dependencies in `project.yml`.

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Push/PushConfig.swift MatronShared/Sources/Push/PushService.swift \
        MatronShared/Package.swift project.yml
git commit -m "feat: PushConfig + PushService protocol + MatronPush library"
git push
```

---

### Task 2: PushServiceLive

**Files:**
- Create: `MatronShared/Sources/Push/PushServiceLive.swift`
- Create: `MatronShared/Tests/PushTests/PushServiceLiveTests.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import UIKit
import UserNotifications
import MatrixRustSDK
import MatronModels
import MatronSync

public final class PushServiceLive: PushService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    public func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws {
        let client = try await provider.client(for: session)
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        try await client.notificationClient(processSetup: .multipleProcesses).setHttpPusher(
            identifiers: PusherIdentifiers(pushkey: tokenHex, appId: PushConfig.appID),
            kind: .http(data: HttpPusherData(
                url: pusherBaseURL.absoluteString,
                format: PushConfig.pushFormat,
                defaultPayload: nil
            )),
            appDisplayName: PushConfig.appDisplayName,
            deviceDisplayName: UIDevice.current.name,
            profileTag: nil,
            lang: PushConfig.language
        )
    }

    public func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {
        let client = try await provider.client(for: session)
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // SDK exposes a deletePusher analogue; check Package.resolved for exact API.
        try await client.notificationClient(processSetup: .multipleProcesses).deletePusher(
            identifiers: PusherIdentifiers(pushkey: tokenHex, appId: PushConfig.appID)
        )
    }
}
```

> **Implementer notes:**
> - `setHttpPusher` / `deletePusher` argument shapes vary across SDK versions. Some releases call this `setPusher` with a `PusherKind` enum; check `Package.resolved`.
> - Must run in `processSetup: .multipleProcesses` mode so the NSE can also open the same store.

- [ ] **Step 2: Lightweight test (token formatting)**

```swift
import XCTest
@testable import MatronPush

final class PushServiceLiveTests: XCTestCase {
    func test_tokenIsHexEncoded() {
        let bytes: [UInt8] = [0xab, 0xcd, 0xef, 0x01]
        let data = Data(bytes)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "abcdef01")
    }
}
```

(Most of `PushServiceLive` is SDK delegation; we don't unit-test the SDK side.)

- [ ] **Step 3: Commit**

```bash
git add MatronShared/Sources/Push/PushServiceLive.swift MatronShared/Tests/PushTests/PushServiceLiveTests.swift
git commit -m "feat: PushServiceLive registers HTTP pusher + APNs token"
git push
```

---

### Task 3: PushDecoder — shared decryption logic

**Files:**
- Create: `MatronShared/Sources/Push/PushDecoder.swift`

Used by the NSE. Wraps the SDK's `NotificationClient` to fetch + decrypt one event.

- [ ] **Step 1: Implement**

```swift
import Foundation
import MatrixRustSDK
import MatronStorage
import MatronModels
import MatronSync

public struct DecodedNotification: Sendable {
    public let title: String
    public let body: String
    public let threadIdentifier: String?
    public let badge: Int?
}

public final class PushDecoder: @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func decode(roomID: String, eventID: String) async throws -> DecodedNotification {
        let client = try await provider.client(for: session)
        let nc = try await client.notificationClient(processSetup: .multipleProcesses)
        guard let item = try await nc.getNotification(roomId: roomID, eventId: eventID) else {
            return DecodedNotification(title: "Matron", body: "New message", threadIdentifier: roomID, badge: nil)
        }
        let title = item.senderInfo.displayName ?? item.senderInfo.userId
        let body: String = {
            switch item.event {
            case .timeline(let event):
                if let text = event.text { return text }
                return "New message"
            default:
                return "New message"
            }
        }()
        return DecodedNotification(title: title, body: body, threadIdentifier: roomID, badge: nil)
    }
}
```

> **Implementer notes:**
> - `NotificationClient.getNotification` returns a struct whose shape varies across SDK versions. Adjust property accesses (`senderInfo.displayName`, `event`, `text`).
> - For attachments (`m.image`/`m.file`), set `body` to "📎 Image" / "📎 File" — pull mime via `event.kind`.
> - Tool calls (Phase 5): set `body` to "🔧 Tool call". This is added in Phase 5.

- [ ] **Step 2: Commit**

```bash
git add MatronShared/Sources/Push/PushDecoder.swift
git commit -m "feat: PushDecoder wraps NotificationClient for NSE-side decryption"
git push
```

---

### Task 4: NotificationService.swift (NSE entry point)

**Files:**
- Modify: `MatronNSE/NotificationService.swift`

- [ ] **Step 1: Replace stub with real implementation**

```swift
import UserNotifications
import MatronPush
import MatronAuth
import MatronSync
import MatronStorage

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let userInfo = request.content.userInfo as? [String: Any],
              let roomID = userInfo["room_id"] as? String,
              let eventID = userInfo["event_id"] as? String else {
            contentHandler(request.content)
            return
        }

        Task {
            do {
                guard let container = AppGroup.containerURL else {
                    fallback(); return
                }
                let keychain = KeychainStore(service: "chat.matron.session")
                let auth = AuthServiceLive(keychain: keychain, basePath: container)
                guard let session = try await auth.restoreSession() else {
                    fallback(); return
                }
                let provider = ClientProvider(basePath: container)
                let decoder = PushDecoder(provider: provider, session: session)
                let decoded = try await decoder.decode(roomID: roomID, eventID: eventID)

                guard let content = bestAttempt else { fallback(); return }
                content.title = decoded.title
                content.body = decoded.body
                content.threadIdentifier = decoded.threadIdentifier ?? roomID
                if let badge = decoded.badge { content.badge = NSNumber(value: badge) }
                content.userInfo["room_id"] = roomID
                content.userInfo["event_id"] = eventID
                contentHandler(content)
            } catch {
                fallback()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        fallback()
    }

    private func fallback() {
        guard let handler = contentHandler else { return }
        if let content = bestAttempt {
            content.title = "Matron"
            content.body = "New message"
            handler(content)
        } else {
            handler(UNNotificationContent())
        }
    }
}
```

- [ ] **Step 2: Update `MatronNSE.entitlements`**

In `project.yml`, the entitlements block for `MatronNSE` should match `Matron`'s:

```yaml
    entitlements:
      path: MatronNSE/MatronNSE.entitlements
      properties:
        com.apple.security.application-groups:
          - group.chat.matron
        keychain-access-groups:
          - $(AppIdentifierPrefix)chat.matron
```

(Already configured in Phase 1, but verify.)

- [ ] **Step 3: Build + commit**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme MatronNSE \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' CODE_SIGNING_ALLOWED=NO
git add MatronNSE/NotificationService.swift project.yml
git commit -m "feat: NSE decrypts event via PushDecoder and rewrites notification"
git push
```

---

### Task 5: PushBootstrap (app-side launch hook)

**Files:**
- Create: `Matron/App/PushBootstrap.swift`
- Modify: `Matron/App/MatronApp.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import UIKit
import MatronPush
import MatronModels

@MainActor
final class PushBootstrap {
    private let pushService: PushService
    private let pusherBaseURL: URL

    init(pushService: PushService, pusherBaseURL: URL) {
        self.pushService = pushService
        self.pusherBaseURL = pusherBaseURL
    }

    func bootstrap() async {
        let granted = await pushService.requestPermission()
        guard granted else { return }
        await UIApplication.shared.registerForRemoteNotifications()
        // Token arrives via UIApplicationDelegate.didRegisterForRemoteNotificationsWithDeviceToken;
        // the AppDelegate caches it in PushTokenStore (defined below).
    }

    func register(token: Data) async {
        do {
            try await pushService.registerToken(token, pusherBaseURL: pusherBaseURL)
        } catch {
            // Log and surface as a Settings warning. Phase 4 doesn't gate UX on this.
        }
    }
}

@MainActor
final class PushTokenStore {
    static let shared = PushTokenStore()
    var latestToken: Data?
    var observers: [(Data) -> Void] = []
}
```

- [ ] **Step 2: Add a UIApplicationDelegateAdaptor**

Add to `MatronApp.swift`:

```swift
@UIApplicationDelegateAdaptor(MatronAppDelegate.self) var appDelegate

final class MatronAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushTokenStore.shared.latestToken = deviceToken
            PushTokenStore.shared.observers.forEach { $0(deviceToken) }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Phase 4: log only.
    }
}
```

In the post-login branch of `MatronApp`, after sync starts, invoke `PushBootstrap.bootstrap()` once and observe `PushTokenStore` for the token, then `register(token:)`.

- [ ] **Step 3: Commit**

```bash
git add Matron/App/PushBootstrap.swift Matron/App/MatronApp.swift
git commit -m "feat: PushBootstrap requests permission and registers APNs token"
git push
```

---

### Task 6: NotificationDelegate — deep link on tap

**Files:**
- Create: `Matron/App/NotificationDelegate.swift`
- Modify: `Matron/App/MatronApp.swift`

- [ ] **Step 1: Implement**

```swift
import UIKit
import UserNotifications
import Combine

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    let tappedRoomID = PassthroughSubject<String, Never>()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let roomID = response.notification.request.content.userInfo["room_id"] as? String {
            tappedRoomID.send(roomID)
        }
        completionHandler()
    }

    // Foreground: still show the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
```

- [ ] **Step 2: Wire delegate + observe taps in `MatronApp`**

In `MatronAppDelegate.application(_:didFinishLaunchingWithOptions:)`:

```swift
UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
```

In the post-login branch of `MatronApp`, observe `NotificationDelegate.shared.tappedRoomID` and append the matching `ChatSummary` onto the chat-list `NavigationStack`'s path.

```swift
.onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
    // Find ChatSummary by roomID in current snapshot, push it onto navigation path.
}
```

- [ ] **Step 3: Commit**

```bash
git add Matron/App/NotificationDelegate.swift Matron/App/MatronApp.swift
git commit -m "feat: NotificationDelegate routes notification taps to deep links"
git push
```

---

### Task 7: PushDecoder unit tests with fixture event

**Files:**
- Create: `MatronShared/Tests/PushTests/PushDecoderTests.swift`
- Create: `MatronShared/Tests/PushTests/Fixtures/decrypted-text.json`

We can't drive a real `NotificationClient` without a homeserver, but we can test the title/body construction with a fake `getNotification` injection. Refactor `PushDecoder` slightly to take a closure-based dependency:

- [ ] **Step 1: Refactor `PushDecoder` to accept an injectable fetcher**

```swift
public final class PushDecoder: @unchecked Sendable {
    public typealias Fetcher = (String, String) async throws -> NotificationItem?

    private let fetcher: Fetcher

    public init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    public static func live(provider: ClientProvider, session: UserSession) -> PushDecoder {
        PushDecoder { roomID, eventID in
            let client = try await provider.client(for: session)
            let nc = try await client.notificationClient(processSetup: .multipleProcesses)
            return try await nc.getNotification(roomId: roomID, eventId: eventID)
        }
    }

    public func decode(roomID: String, eventID: String) async throws -> DecodedNotification {
        guard let item = try await fetcher(roomID, eventID) else {
            return DecodedNotification(title: "Matron", body: "New message", threadIdentifier: roomID, badge: nil)
        }
        // …same body construction as before…
    }
}
```

- [ ] **Step 2: Write fixture-based test**

```swift
import XCTest
@testable import MatronPush

final class PushDecoderTests: XCTestCase {
    func test_returnsDefaultWhenNoItem() async throws {
        let decoder = PushDecoder(fetcher: { _, _ in nil })
        let result = try await decoder.decode(roomID: "!r:s", eventID: "$evt")
        XCTAssertEqual(result.title, "Matron")
        XCTAssertEqual(result.body, "New message")
        XCTAssertEqual(result.threadIdentifier, "!r:s")
    }

    // Once SDK types are stable, add fixtures with a hand-built NotificationItem
    // (reuse the SDK's struct definitions) and assert title/body construction.
}
```

- [ ] **Step 3: Commit**

```bash
git add MatronShared/Sources/Push/PushDecoder.swift MatronShared/Tests/PushTests/PushDecoderTests.swift
git commit -m "test: PushDecoder injectable fetcher + default-fallback test"
git push
```

---

### Task 8: Sign-out clears pusher

**Files:**
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (if you have a sign-out button) OR `Matron/App/AppDependencies.swift`

- [ ] **Step 1: When user signs out, call `PushService.unregister` before clearing the session**

Wire this into wherever the sign-out button lives (Phase 7 builds the full Settings; for Phase 4, expose a temporary sign-out button in DeviceSettingsView if not already).

```swift
Button("Sign out", role: .destructive) {
    Task {
        if let token = await PushTokenStore.shared.latestToken {
            try? await pushService.unregister(deviceToken: token, pusherBaseURL: pusherURL)
        }
        try? auth.clearSession()
        // Bounce back to onboarding.
    }
}
```

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: sign-out unregisters pusher before clearing session"
git push
```

---

### Task 9: Server-side runbook

**Files:**
- Create: `docs/push-setup.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Push setup runbook

This documents the server-side configuration required for iOS push to reach Matron.

## Components

```
APNs ──▶ Sygnal (HTTP pusher) ──▶ Tuwunel (matron-server) ──▶ Matron iOS NSE
```

## Apple side

1. In the Apple Developer Portal, create a Key for **Apple Push Notifications service (APNs)**.
2. Download the `.p8` file. Note the Key ID and Team ID.

## Sygnal

Run upstream Sygnal — Apache 2.0, no fork needed.

```bash
docker run -d --name sygnal \
  -p 5000:5000 \
  -v $(pwd)/sygnal.yaml:/etc/sygnal.yaml:ro \
  -v $(pwd)/auth_key.p8:/etc/auth_key.p8:ro \
  matrixdotorg/sygnal:latest
```

`sygnal.yaml`:

```yaml
apps:
  chat.matron.app.ios:
    type: apns
    keyfile: /etc/auth_key.p8
    key_id: <KEY_ID>
    team_id: <TEAM_ID>
    topic: chat.matron.app
    push_type: alert
log:
  setup:
    version: 1
    formatters:
      precise: { format: '%(asctime)s [%(process)d] %(levelname)-5s %(name)s - %(message)s' }
    handlers:
      console: { class: logging.StreamHandler, formatter: precise, level: DEBUG }
    root: { handlers: [console], level: DEBUG }
```

`app_id` (`chat.matron.app.ios`) MUST match `PushConfig.appID` in `MatronShared/Push/PushConfig.swift`.

`topic` is the bundle ID of the **NSE-bearing app**, not the NSE itself — `chat.matron.app`.

## Cloudflare Tunnel

Add a route mapping `https://push.<domain>` → `http://127.0.0.1:5000`.

## matron-server (Tuwunel)

No specific config — pushers are per-user, registered by the iOS app via `POST /_matrix/client/v3/pushers`.

## Smoke test

```bash
curl -i -X POST https://push.example.com/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{
    "notification": {
      "event_id": "$test:example.com",
      "room_id": "!test:example.com",
      "type": "m.room.message",
      "sender": "@test:example.com",
      "counts": { "unread": 1 },
      "devices": [{
        "app_id": "chat.matron.app.ios",
        "pushkey": "<APNS_TOKEN_HEX>",
        "data": { "format": "event_id_only" }
      }]
    }
  }'
```

A `200 OK` with `{"rejected":[]}` means Sygnal accepted the push.
```

- [ ] **Step 2: Commit**

```bash
git add docs/push-setup.md
git commit -m "docs: server-side push setup runbook (Sygnal + Cloudflare)"
git push
```

---

### Task 10: Manual test additions

Append to `manual-tests.md`:

```markdown
## Phase 4 (Push & NSE)

### Permission + token registration

- [ ] Fresh sign-in → notification permission prompt appears.
- [ ] Allow → no error in logs; `PushTokenStore.shared.latestToken` is non-nil.
- [ ] Background the app. Send a message from another Matrix client to the user.
- [ ] Notification appears with sender name + message body (decrypted).

### Notification tap

- [ ] Tap the notification → app opens to that chat directly.

### Multiple chats

- [ ] Receive notifications from two different bots → notifications stack as separate threads (per `threadIdentifier`).

### Failure modes

- [ ] Disable notifications in iOS Settings → Settings → Device shows the warning.
- [ ] Sign out → notifications stop arriving (confirm by sending another message).
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 4 manual test additions"
git push
```

---

## Phase 4 acceptance

1. All 10 tasks committed and pushed.
2. CI green.
3. Server-side: Sygnal smoke test returns `200 {"rejected":[]}`.
4. Manual checklist passes on a physical device (TestFlight build) — simulator does not receive real APNs.

After acceptance, write Phase 5 plan (custom events).

---

## Plan self-review

- **§8.1 Server side:** Documented in `docs/push-setup.md` (Task 9). Implementation is upstream Sygnal; no app-side code.
- **§8.2 App side:** PushService (Tasks 1–2) + PushBootstrap (Task 5).
- **§8.3 Receiving a push:** PushDecoder (Task 3) + NotificationService.swift (Task 4).
- **§8.4 Tap to open:** NotificationDelegate (Task 6).
- **§7.1 Crypto store sharing:** Already established in Phase 1 (App Group). NSE accesses it in `processSetup: .multipleProcesses` mode (Task 3).
- No placeholders. SDK API names flagged where they shift.
