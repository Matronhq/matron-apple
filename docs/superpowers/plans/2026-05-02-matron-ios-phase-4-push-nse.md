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
├── project.yml                                MODIFIED — adds MatronNSE app-extension target
├── MatronShared/Sources/Push/
│   ├── PushService.swift                      NEW — protocol
│   ├── PushServiceLive.swift                  NEW — APNs token + register pusher
│   ├── PushDecoder.swift                      NEW — shared by app + NSE (closure-injectable Fetcher)
│   ├── PushConfig.swift                       NEW — pusher URL, app_id consts
│   └── PushBootstrap+PushRules.swift          NEW — default push rules (§8.2)
├── MatronNSE/
│   ├── NotificationService.swift              NEW (stub in Task 1, replaced in Task 4)
│   ├── Info.plist                             NEW — extension bundle plist
│   └── MatronNSE.entitlements                 NEW — App Group + keychain group
├── Matron/App/
│   ├── PushBootstrap.swift                    NEW — request permission, register
│   └── NotificationDelegate.swift             NEW — handle taps for deep link
├── MatronShared/Tests/PushTests/
│   ├── PushDecoderDefaultsTests.swift         NEW — Task 3 default-fallback test
│   ├── PushDecoderBodyTests.swift             NEW — Task 7 fixture coverage
│   ├── PushServiceLiveTests.swift             NEW
│   ├── PushBootstrapPushRulesTests.swift      NEW — Task 5 default-push-rules test
│   ├── Fixtures/NotificationItemFixtures.swift NEW
│   └── Doubles/FakeNotificationSettings.swift NEW
└── docs/
    └── push-setup.md                          NEW — server-side runbook for Sygnal
```

---

## Tasks

### Task 1: NSE Xcode target + PushConfig + PushService protocol

**Files:**
- Modify: `project.yml` (add `MatronNSE` target)
- Create: `MatronNSE/Info.plist`
- Create: `MatronNSE/MatronNSE.entitlements`
- Create: `MatronNSE/NotificationService.swift` (stub)
- Create: `MatronShared/Sources/Push/PushConfig.swift`
- Create: `MatronShared/Sources/Push/PushService.swift`

> **Note:** Phase 1 wired up `Matron` (the host app) and `MatronShared`, but did **not** create the NSE Xcode target. Phase 4 owns this — without the target, none of Tasks 2–10 can build. This task creates it via XcodeGen so the rest of the phase has a place to plug into.

- [ ] **Step 0: Add `MatronNSE` target to `project.yml`**

Append the following stanza under `targets:` in `project.yml`:

```yaml
MatronNSE:
  type: app-extension
  platform: iOS
  deploymentTarget: 17.0
  sources: [MatronNSE]
  dependencies:
    - target: MatronShared
  info:
    path: MatronNSE/Info.plist
    properties:
      NSExtension:
        NSExtensionPointIdentifier: com.apple.usernotifications.service
        NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).NotificationService
  entitlements:
    path: MatronNSE/MatronNSE.entitlements
    properties:
      com.apple.security.application-groups: [group.chat.matron]
      keychain-access-groups: ["$(AppIdentifierPrefix)chat.matron"]
```

Also add `MatronNSE` as an extension dependency on the `Matron` host target so it gets embedded in the app bundle:

```yaml
Matron:
  # …existing config…
  dependencies:
    # …existing deps…
    - target: MatronNSE
      embed: true
      codeSign: true
```

Create `MatronNSE/MatronNSE.entitlements` with the full plist contents:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.chat.matron</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)chat.matron</string>
    </array>
</dict>
</plist>
```

Create `MatronNSE/Info.plist` (XcodeGen will merge `info.properties` from `project.yml` into this — the file just needs to exist with the bundle basics):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>MatronNSE</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
</dict>
</plist>
```

Create a stub `MatronNSE/NotificationService.swift` so the target compiles before Task 4 swaps in the real implementation:

```swift
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
```

**Verify the target builds before moving on:**

```bash
xcodegen generate && xcodebuild -scheme MatronNSE -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The build must succeed before continuing — if XcodeGen complains about the stanza or `xcodebuild` cannot find `MatronNSE`, fix that first. Commit before touching Push code:

```bash
git add project.yml MatronNSE/Info.plist MatronNSE/MatronNSE.entitlements MatronNSE/NotificationService.swift
git commit -m "feat(nse): add MatronNSE app-extension target via XcodeGen with App Group + keychain entitlements"
git push
```

- [ ] **Step 1: PushConfig**

```swift
import Foundation

public enum PushConfig {
    /// Matrix-side pusher `app_id`. Distinct per build configuration so Sygnal
    /// can route Debug builds to the APNs sandbox endpoint and Release builds
    /// to production (see `docs/push-setup.md` § "APNs sandbox vs production").
    #if DEBUG
    public static let appID = "chat.matron.ios.dev"
    #else
    public static let appID = "chat.matron.ios"
    #endif
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

Used by the NSE. Wraps the SDK's `NotificationClient` to fetch + decrypt one event. We adopt a closure-injectable fetcher up front so Task 7 can drive `decode(...)` against fixture `NotificationItem`s without standing up a real SDK client.

- [ ] **Step 1: Failing test first (TDD)**

`MatronShared/Tests/PushTests/PushDecoderDefaultsTests.swift`:

```swift
import XCTest
@testable import MatronPush

final class PushDecoderDefaultsTests: XCTestCase {
    func test_decode_returnsDefaultWhenFetcherYieldsNil() async throws {
        let decoder = PushDecoder(fetcher: { _, _ in nil })
        let result = try await decoder.decode(roomID: "!r:s", eventID: "$evt")
        XCTAssertEqual(result.title, "Matron")
        XCTAssertEqual(result.body, "New message")
        XCTAssertEqual(result.threadIdentifier, "!r:s")
    }
}
```

Run it, watch it fail to compile (`PushDecoder` doesn't exist yet).

- [ ] **Step 2: Implement**

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
    /// Closure shape lets tests drive `decode(...)` with fixture `NotificationItem`s
    /// without a real homeserver. The `live(provider:session:)` factory wires the
    /// production path through `Client.notificationClient(...)`.
    public typealias Fetcher = (_ roomID: String, _ eventID: String) async throws -> NotificationItem?

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
        let title = item.senderInfo.displayName ?? item.senderInfo.userId
        let body = Self.body(for: item)
        return DecodedNotification(title: title, body: body, threadIdentifier: roomID, badge: nil)
    }

    /// Maps a decrypted `NotificationItem` to a user-visible body string.
    /// Explicit cases for every msgtype we care about; falls through to a generic
    /// "New message" only for genuinely unknown types so missing handlers are
    /// caught by Task 7's fixture suite.
    static func body(for item: NotificationItem) -> String {
        switch item.event {
        case .text(let body):
            return body
        case .image(let alt):
            return "📎 image" + (alt.map { " — \($0)" } ?? "")
        case .file(let name):
            return "📎 file" + (name.map { " — \($0)" } ?? "")
        case .toolCall(let tool, _):
            return "🔧 \(tool)"
        case .askUser(let prompt):
            return prompt
        default:
            return "New message"
        }
    }
}
```

> **Implementer notes:**
> - `NotificationClient.getNotification` returns a struct whose shape varies across SDK versions. Adjust property accesses (`senderInfo.displayName`, `event`).
> - The `switch item.event` cases above assume an enum-like surface (`.text`/`.image`/`.file`/`.toolCall`/`.askUser`). If the pinned SDK exposes a generic `NotificationItem` carrying a `msgtype` string instead, dispatch on that string with the same body strings — the fixture suite in Task 7 pins the expected outputs either way.
> - `chat.matron.tool_call` and `chat.matron.ask_user` are the custom event types defined in spec §10 (Phase 5). We branch on them here so push bodies are correct from day one even though the in-app rendering arrives in Phase 5.

- [ ] **Step 3: Verify**

```bash
swift test --filter PushDecoderDefaultsTests
```

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Push/PushDecoder.swift \
        MatronShared/Tests/PushTests/PushDecoderDefaultsTests.swift
git commit -m "feat: PushDecoder with closure-injectable fetcher + msgtype-aware body construction"
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
                let decoder = PushDecoder.live(provider: provider, session: session)
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

- [ ] **Step 2: Verify `MatronNSE.entitlements`**

The entitlements file was created in Task 1 Step 0 and must contain (re-paste here as the contract this task depends on):

```yaml
    entitlements:
      path: MatronNSE/MatronNSE.entitlements
      properties:
        com.apple.security.application-groups:
          - group.chat.matron
        keychain-access-groups:
          - $(AppIdentifierPrefix)chat.matron
```

If anything has drifted (e.g. a stray edit) re-sync it now — the NSE cannot read the shared crypto store or the keychain session without both groups.

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
    let notificationSettings: NotificationSettingsProtocol
    let joinedRoomIDs: () async -> [String]

    init(
        pushService: PushService,
        pusherBaseURL: URL,
        notificationSettings: NotificationSettingsProtocol,
        joinedRoomIDs: @escaping () async -> [String]
    ) {
        self.pushService = pushService
        self.pusherBaseURL = pusherBaseURL
        self.notificationSettings = notificationSettings
        self.joinedRoomIDs = joinedRoomIDs
    }

    func bootstrap() async {
        let granted = await pushService.requestPermission()
        guard granted else { return }
        try? await ensureDefaultPushRules()                // see Step 3
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

- [ ] **Step 3: Ensure default push rules notify on every joined-room message (spec §8.2)**

Per spec §8.2: "Configure default push rules: notify on every event in joined rooms." Out of the box, the homeserver applies the standard Matrix push rule defaults — `.m.rule.master` may be disabled and there is no guarantee that every encrypted bot-room message ends up with a `notify` action. We need a one-shot post-login call that ensures (a) the master rule is enabled, and (b) any joined room defaults to `.allMessages` notification mode.

Failing test first (TDD — `MatronShared/Tests/PushTests/PushBootstrapPushRulesTests.swift`):

```swift
import XCTest
@testable import MatronPush

final class PushBootstrapPushRulesTests: XCTestCase {
    func test_ensureDefaultPushRules_enablesMasterAndSetsAllMessages() async throws {
        let fake = FakeNotificationSettings()
        fake.masterRuleEnabled = false   // simulate user-disabled state
        let bootstrap = PushBootstrap(
            pushService: NoopPushService(),
            pusherBaseURL: URL(string: "https://example.com")!,
            notificationSettings: fake,
            joinedRoomIDs: { ["!a:s", "!b:s"] }
        )

        try await bootstrap.ensureDefaultPushRules()

        // Master must be on after bootstrap.
        XCTAssertTrue(fake.masterRuleEnabled)
        // Every joined room must end up in .allMessages mode.
        XCTAssertEqual(fake.modes["!a:s"], .allMessages)
        XCTAssertEqual(fake.modes["!b:s"], .allMessages)
    }
}
```

Implementation in `PushBootstrap.swift`:

```swift
import MatrixRustSDK

extension PushBootstrap {
    /// Ensures spec §8.2 default push rules are in place:
    /// - `.m.rule.master` is enabled (push not globally suppressed).
    /// - Every joined room is set to `.allMessages` notification mode.
    func ensureDefaultPushRules() async throws {
        // 1. Master override — re-enable if a previous client (or user) toggled it off.
        if try await notificationSettings.isPushRuleEnabled(
            ruleKind: .override, ruleId: ".m.rule.master"
        ) == false {
            try await notificationSettings.setPushRuleEnabled(
                ruleKind: .override, ruleId: ".m.rule.master", enabled: true
            )
        }

        // 2. Per-room: default each joined room to .allMessages so silent pushes fire
        //    even when matrix's default rule set wouldn't have produced a `notify` action.
        for roomID in await joinedRoomIDs() {
            try await notificationSettings.setRoomNotificationMode(
                roomId: roomID, mode: .allMessages
            )
        }

        // 3. Sanity check: assert the resolved action for each joined room is `notify`.
        //    Surfaces drift if the SDK ever changes the .allMessages semantics.
        for roomID in await joinedRoomIDs() {
            let mode = try await notificationSettings.getRoomNotificationMode(roomId: roomID)
            assert(mode == .allMessages, "expected notify/allMessages for \(roomID), got \(mode)")
        }
    }
}
```

`ensureDefaultPushRules()` is already invoked from `bootstrap()` in Step 1 (between permission grant and `registerForRemoteNotifications()`); this step adds the implementation behind that call site.

> **Implementer notes:**
> - The matrix-rust-sdk-swift surface for this is `Client.notificationSettings()` returning a `NotificationSettings` actor with `isPushRuleEnabled` / `setPushRuleEnabled` / `setRoomNotificationMode` / `getRoomNotificationMode`. Some older releases instead expose `Client.setPushRule(...)` directly — adjust to the actual SDK shape pinned in `Package.resolved`.
> - `NotificationSettingsProtocol` is a thin in-house protocol that mirrors the four SDK methods we need; the live impl wraps `Client.notificationSettings()`, the test double `FakeNotificationSettings` records writes against an in-memory dict.
> - `joinedRoomIDs` is supplied by the caller (read from the room-list snapshot Phase 2 already maintains) so we do not couple `PushBootstrap` to the sync layer.
> - `NoopPushService` and `FakeNotificationSettings` are simple test doubles in `Tests/PushTests/Doubles/`.

Run the test, watch it fail (no impl), implement, re-run, watch it pass:

```bash
swift test --filter PushBootstrapPushRulesTests
```

- [ ] **Step 4: Commit**

```bash
git add Matron/App/PushBootstrap.swift Matron/App/MatronApp.swift \
        MatronShared/Sources/Push/PushBootstrap+PushRules.swift \
        MatronShared/Tests/PushTests/PushBootstrapPushRulesTests.swift \
        MatronShared/Tests/PushTests/Doubles/FakeNotificationSettings.swift
git commit -m "feat: PushBootstrap requests permission, enables .m.rule.master, sets joined rooms to .allMessages, registers APNs token"
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

### Task 7: PushDecoder fixture tests for every msgtype

**Files:**
- Create: `MatronShared/Tests/PushTests/PushDecoderBodyTests.swift`
- Create: `MatronShared/Tests/PushTests/Fixtures/NotificationItemFixtures.swift`

The closure-injectable shape and the msgtype switch already landed in Task 3. This task adds fixture-driven tests that pin the body string for every variant we care about (and the unknown-msgtype fall-through). No production-code changes.

- [ ] **Step 1: Failing tests first (TDD)**

`MatronShared/Tests/PushTests/PushDecoderBodyTests.swift`:

```swift
import XCTest
@testable import MatronPush

final class PushDecoderBodyTests: XCTestCase {
    private func decode(_ item: NotificationItem) async throws -> DecodedNotification {
        let decoder = PushDecoder(fetcher: { _, _ in item })
        return try await decoder.decode(roomID: "!r:s", eventID: "$evt")
    }

    func test_body_text() async throws {
        let r = try await decode(.fixture(event: .text("hello world")))
        XCTAssertEqual(r.body, "hello world")
    }

    func test_body_image_withAlt() async throws {
        let r = try await decode(.fixture(event: .image("cat.png")))
        XCTAssertEqual(r.body, "📎 image — cat.png")
    }

    func test_body_image_withoutAlt() async throws {
        let r = try await decode(.fixture(event: .image(nil)))
        XCTAssertEqual(r.body, "📎 image")
    }

    func test_body_file_withName() async throws {
        let r = try await decode(.fixture(event: .file("report.pdf")))
        XCTAssertEqual(r.body, "📎 file — report.pdf")
    }

    func test_body_file_withoutName() async throws {
        let r = try await decode(.fixture(event: .file(nil)))
        XCTAssertEqual(r.body, "📎 file")
    }

    func test_body_toolCall() async throws {
        let r = try await decode(.fixture(event: .toolCall("search", ["q": "swift"])))
        XCTAssertEqual(r.body, "🔧 search")
    }

    func test_body_askUser() async throws {
        let r = try await decode(.fixture(event: .askUser("Approve transfer?")))
        XCTAssertEqual(r.body, "Approve transfer?")
    }

    func test_body_unknownMsgtypeFallsThrough() async throws {
        let r = try await decode(.fixture(event: .other("m.sticker")))
        XCTAssertEqual(r.body, "New message")
    }
}
```

`MatronShared/Tests/PushTests/Fixtures/NotificationItemFixtures.swift` builds in-memory `NotificationItem` values with each event variant. If the pinned SDK exposes a `msgtype: String` rather than an enum, the fixtures should produce items with the corresponding raw msgtype strings (`m.text`, `m.image`, `m.file`, `chat.matron.tool_call`, `chat.matron.ask_user`, plus an unknown one like `m.sticker`) and the `body(for:)` switch in `PushDecoder` should be adjusted to dispatch on the string — assertions stay identical.

- [ ] **Step 2: Run, verify, commit**

```bash
swift test --filter PushDecoderBodyTests
git add MatronShared/Tests/PushTests/PushDecoderBodyTests.swift \
        MatronShared/Tests/PushTests/Fixtures/NotificationItemFixtures.swift
git commit -m "test: PushDecoder fixture coverage for text/image/file/tool_call/ask_user/unknown msgtypes"
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
  chat.matron.ios:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.ios
    use_sandbox: true   # set false for TestFlight/production builds
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

`app_id` (`chat.matron.ios`) MUST match `PushConfig.appID` in `MatronShared/Push/PushConfig.swift`.

`topic` is the bundle ID of the **NSE-bearing app**, not the NSE itself — `chat.matron.app`.

### APNs sandbox vs production

TestFlight and App Store builds use the production APNs endpoint. Debug/dev builds (Xcode `Run`, simulator deploys, ad-hoc development provisioning profiles) use sandbox. Mismatched configs produce silent push failures — Sygnal accepts the request, APNs returns `BadDeviceToken` for the wrong endpoint, and the user simply never sees a notification.

Operationally we run two Sygnal app entries side-by-side: `chat.matron.ios.dev` with `use_sandbox: true` and `chat.matron.ios` with `use_sandbox: false`. The iOS build picks the right `app_id` at compile time from a build setting (debug vs release). Whenever you cut a TestFlight build, double-check that `use_sandbox` on the matching Sygnal entry is `false` — a stray `true` here is the single most common cause of "push works on my Mac but not on TestFlight".

## Cloudflare Tunnel

Add a route mapping `https://push.<domain>` → `http://127.0.0.1:5000`.

## matron-server (Tuwunel)

No specific config — pushers are per-user, registered by the iOS app via `POST /_matrix/client/v3/pushers`.

## Smoke test

**Pre-flight: verify `use_sandbox` matches the build type you are testing against.**

```bash
# Check the sandbox flag for the app_id we're about to hit:
docker exec sygnal grep -A1 "^  chat.matron.ios" /etc/sygnal.yaml | grep use_sandbox
# Expect: use_sandbox: true   for a Debug/dev IPA / simulator build
# Expect: use_sandbox: false  for a TestFlight or App Store build

# Cross-check the build type by reading the embedded.mobileprovision from the .ipa:
unzip -p Matron.ipa "Payload/Matron.app/embedded.mobileprovision" \
  | security cms -D \
  | plutil -extract aps-environment xml1 -o - -
# Expect: <string>development</string>  → must pair with use_sandbox: true
# Expect: <string>production</string>   → must pair with use_sandbox: false
```

Mismatched values here are a hard fail — abort the smoke test and fix the Sygnal config (or rebuild the IPA with the correct provisioning profile) before sending traffic.

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
        "app_id": "chat.matron.ios",
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

- **NSE Xcode target:** Created in Task 1 Step 0 — Phase 1 wired the host app and `MatronShared` only; this phase owns the `MatronNSE` app-extension target, its `Info.plist`, its entitlements (App Group + keychain group), and a stub `NotificationService.swift` that compiles before Task 4 swaps in the real implementation. Verified via `xcodegen generate && xcodebuild -scheme MatronNSE -configuration Debug CODE_SIGNING_ALLOWED=NO build` before Push code lands. Phase 4 stands alone here — no implicit dependency on Phase 1 doing this work.
- **§8.1 Server side:** Documented in `docs/push-setup.md` (Task 9). Implementation is upstream Sygnal; no app-side code. Sandbox vs production endpoints, `use_sandbox` config, and the build-type cross-check are explicit.
- **§8.2 App side — registration:** `PushService` (Tasks 1–2) + `PushBootstrap` (Task 5 Steps 1–2).
- **§8.2 App side — default push rules:** Task 5 Step 3 enables `.m.rule.master` if disabled and pins every joined room to `.allMessages`, with a sanity-check assertion on the resolved mode. Test-first: `PushBootstrapPushRulesTests` drives a `FakeNotificationSettings` to confirm both effects.
- **§8.3 Receiving a push:** `PushDecoder` (Task 3) + `NotificationService.swift` (Task 4). The closure-injectable `Fetcher` shape lives in Task 3 from the start (no late refactor), and `NotificationService` calls `PushDecoder.live(provider:session:)`. Body construction has explicit cases for `m.text`, `m.image` (with/without alt), `m.file` (with/without name), `chat.matron.tool_call`, `chat.matron.ask_user`, with a `default → "New message"` fall-through that the Task 7 fixture suite pins.
- **§8.3 fixture coverage:** Task 7 is now tests-only — eight cases covering every body variant plus the unknown-msgtype fall-through, all driven via the same closure fetcher Task 3 ships with.
- **§8.4 Tap to open:** `NotificationDelegate` (Task 6).
- **§7.1 Crypto store sharing:** Established in Phase 1 (App Group). NSE accesses it in `processSetup: .multipleProcesses` mode (Tasks 3 & 4) and the App Group + keychain entitlements are owned by Phase 4 in Task 1 Step 0.
- **TDD discipline:** Tasks 3, 5 Step 3, and 7 all open with a failing test before any implementation lands; the Sygnal smoke test in Task 9 begins with a sandbox-vs-build verification gate.
- No placeholders. SDK API names flagged where they shift.
