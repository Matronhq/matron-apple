# Matron iOS — Phase 4 (Push & NSE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 3 (E2EE & verification UX) merged and CI green.

**Goal:** End-to-end push notifications on **both** iOS and macOS. Server-side runs a Sygnal-compatible HTTP pusher with four app entries (`chat.matron.ios`, `chat.matron.ios.dev`, `chat.matron.mac`, `chat.matron.mac.dev`). Each app registers an APNs token with the user's homeserver under its own `app_id`. Inbound silent pushes are decrypted on-device — **iOS** via the Notification Service Extension, **macOS** in-process via `UNUserNotificationCenterDelegate` (Mac apps run their full process for delivered notifications, so no extension is needed and no App Group complications arise). The user sees a clear-text notification with sender + body. Tapping a notification deep-links into the chat (iOS: NavigationStack push; Mac: focuses main window + selects sidebar room).

**Architecture:** Server-side: deploy upstream Sygnal (Apache 2.0) alongside `matron-server`; configure with an APNs auth key and four app entries. App-side: `PushService` (in MatronShared) handles permission + token registration on both platforms. **iOS**: `MatronNSE/NotificationService.swift` opens a read-only SDK client, calls `NotificationClient.getNotification(roomID, eventID)`, builds a rewritten notification, and the host app listens for `UNUserNotificationCenterDelegate.didReceive` to deep-link. **Mac**: `MatronMac/App/MacNotificationHandler.swift` (a `UNUserNotificationCenterDelegate`) handles `willPresent` for foreground silent pushes and `didReceive` for taps — calling the **same** `MatronShared.Push.PushDecoder` (closure-injectable) in-process. No NSE on Mac.

**Tech Stack:** Same as prior phases. APNs auth key (`.p8`) stored in 1Password / your secrets manager — provisioning is out of scope here, but we document the format. `NSApplication.registerForRemoteNotifications()` (Mac) is a distinct API from `UIApplication.registerForRemoteNotifications()` (iOS); permission requests via `UNUserNotificationCenter.requestAuthorization(...)` are identical on both.

**Reference:** Spec §8 (push notifications, all four `app_id`s), §6.3 (push wakeup — separate iOS and Mac paths), §2 (NSE target setup — iOS-only; Mac handles in-process), §10 (manual tests, per-platform).

---

## Server-side prerequisites (out of plan, doc-only)

Before push can work end-to-end on either platform:

1. **Apple Developer:** create an APNs auth key (`.p8`) — a single key covers both `chat.matron.ios` and `chat.matron.mac` bundle IDs (APNs auth keys are per-team, not per-app). Record the Key ID and Team ID. Both bundle IDs must exist in App Store Connect with Push Notifications capability enabled.
2. **`matron-server` host:** run **Sygnal** (`pip install sygnal` or the Docker image) at e.g. `https://push.<domain>/`, configured with **four app entries** — `chat.matron.ios` (production iOS, `use_sandbox: false`), `chat.matron.ios.dev` (sandbox iOS, `use_sandbox: true`), `chat.matron.mac` (production Mac, `use_sandbox: false`), `chat.matron.mac.dev` (sandbox Mac, `use_sandbox: true`). Each entry references the same `.p8` keyfile but with its own `topic` (`chat.matron.ios` or `chat.matron.mac`). Sygnal must be reachable from the homeserver. See Task 9 for the full `sygnal.yaml`.
3. **Cloudflare Tunnel** route for `push.<domain>` → Sygnal port (or run Sygnal on the same Tuwunel host with a separate Cloudflared route).
4. **Server config note:** Tuwunel needs the pusher base URL configured (`pusher_base_url` style setting, or per-pusher via the Matrix `POST /_matrix/client/v3/pushers` flow which both apps do themselves).

These are **bridge/server-side** changes; track them in a separate `dev-boxer` / `matron-server` issue. The plan below assumes Sygnal is reachable with all four entries live.

---

## File structure (Phase 4 deliverables)

```
matron-apple/
├── project.yml                                MODIFIED — adds MatronNSE app-extension target (iOS-only)
├── MatronShared/Sources/Push/
│   ├── PushService.swift                      NEW — protocol (cross-platform)
│   ├── PushServiceLive.swift                  NEW — APNs token + register pusher (cross-platform)
│   ├── PushDecoder.swift                      NEW — shared by iOS app + NSE + Mac app (closure-injectable Fetcher)
│   ├── PushConfig.swift                       NEW — pusher URL, four-way app_id switch (iOS/Mac × debug/release)
│   ├── PushBootstrap.swift                    NEW — cross-platform bootstrap; #if os(iOS) / #if os(macOS) branches
│   │                                                  the registerForRemoteNotifications call
│   └── PushBootstrap+PushRules.swift          NEW — default push rules (§8.2)
├── MatronNSE/                                 iOS-ONLY — macOS does not have NSEs
│   ├── NotificationService.swift              NEW (stub in Task 1, replaced in Task 4)
│   ├── Info.plist                             NEW — extension bundle plist
│   └── MatronNSE.entitlements                 NEW — App Group + keychain group
├── Matron/App/                                iOS host
│   ├── NotificationDelegate.swift             NEW — handle taps for deep link (NavigationStack push)
│   └── (PushBootstrap glue lives in MatronApp.swift via UIApplicationDelegateAdaptor)
├── MatronMac/App/                             Mac host — in-process push handling, no NSE
│   ├── MacNotificationHandler.swift           NEW — UNUserNotificationCenterDelegate; willPresent re-presents
│   │                                                  cleartext, didReceive focuses window + posts
│   │                                                  matronCommand(.openRoom) NotificationCenter event
│   ├── MacPushBootstrap.swift                 NEW — Mac-side glue: NSApplication.registerForRemoteNotifications
│   │                                                  + applicationDidRegisterForRemoteNotifications token capture
│   └── MatronMac.entitlements                 MODIFIED — adds aps-environment (development | production)
├── MatronShared/Tests/PushTests/
│   ├── PushDecoderDefaultsTests.swift         NEW — Task 3 default-fallback test
│   ├── PushDecoderBodyTests.swift             NEW — Task 7 fixture coverage
│   ├── PushServiceLiveTests.swift             NEW
│   ├── PushBootstrapPushRulesTests.swift      NEW — Task 5 default-push-rules test
│   ├── MacNotificationHandlerTests.swift      NEW — Task 10 fake-decoder + fake-center coverage (Mac scheme)
│   ├── MacPushBootstrapTests.swift            NEW — Task 11 token-capture coverage (Mac scheme)
│   ├── Fixtures/NotificationItemFixtures.swift NEW
│   └── Doubles/FakeNotificationSettings.swift NEW
└── docs/
    └── push-setup.md                          NEW — server-side runbook for Sygnal (four app entries)
```

> **NSE is iOS-only.** macOS apps receive notifications in-process via `UNUserNotificationCenterDelegate` — there is no `UNNotificationServiceExtension` equivalent on the Mac, and none is needed (the app's full process is alive when notifications are delivered, so it can decrypt + re-present synchronously). The `MatronMac` target therefore has no extension — only the `MacNotificationHandler` + `MacPushBootstrap` files above.

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

> **Note:** Phase 1 wired up `Matron` (the iOS host), `MatronMac` (the Mac host), and `MatronShared`, but did **not** create the NSE Xcode target. Phase 4 owns this — without the target, none of the iOS-side push tasks (Tasks 2–8) can build on iOS. This task creates it via XcodeGen so the rest of the phase has a place to plug into. **`MatronMac` does not get an NSE target — Mac handles pushes in-process (Tasks 10–12 below).**

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
    /// Matrix-side pusher `app_id`. Distinct per platform AND build configuration
    /// so Sygnal can route iOS-debug, iOS-release, Mac-debug, and Mac-release
    /// builds to the right APNs endpoint with the right bundle topic
    /// (see `docs/push-setup.md` § "APNs sandbox vs production").
    public static let appID: String = {
        #if os(iOS)
            #if DEBUG
            return "chat.matron.ios.dev"
            #else
            return "chat.matron.ios"
            #endif
        #elseif os(macOS)
            #if DEBUG
            return "chat.matron.mac.dev"
            #else
            return "chat.matron.mac"
            #endif
        #endif
    }()
    public static let appDisplayName = "Matron"
    public static let pushFormat = "event_id_only"           // silent payload — decrypted on-device
                                                              // (iOS: NSE; Mac: in-process delegate)
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

Add `MatronPush` to **all three** of `Matron`, `MatronNSE`, and `MatronMac` dependencies in `project.yml`. `MatronMac` consumes the same shared `PushDecoder` + `PushService` + `PushConfig` + cross-platform `PushBootstrap` from this library — there is no Mac-specific clone.

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
import UserNotifications
import MatrixRustSDK
import MatronModels
import MatronSync
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        // Mac uses .singleProcess — no NSE means the crypto store is owned solely
        // by the host app process. iOS uses .multipleProcesses so the NSE can
        // open the same App-Group-shared store concurrently.
        #if os(iOS)
        let processSetup = NotificationProcessSetup.multipleProcesses
        let deviceDisplayName = UIDevice.current.name
        #elseif os(macOS)
        let processSetup = NotificationProcessSetup.singleProcess
        let deviceDisplayName = Host.current().localizedName ?? "Mac"
        #endif
        try await client.notificationClient(processSetup: processSetup).setHttpPusher(
            identifiers: PusherIdentifiers(pushkey: tokenHex, appId: PushConfig.appID),
            kind: .http(data: HttpPusherData(
                url: pusherBaseURL.absoluteString,
                format: PushConfig.pushFormat,
                defaultPayload: nil
            )),
            appDisplayName: PushConfig.appDisplayName,
            deviceDisplayName: deviceDisplayName,
            profileTag: nil,
            lang: PushConfig.language
        )
    }

    public func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {
        let client = try await provider.client(for: session)
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if os(iOS)
        let processSetup = NotificationProcessSetup.multipleProcesses
        #elseif os(macOS)
        let processSetup = NotificationProcessSetup.singleProcess
        #endif
        // SDK exposes a deletePusher analogue; check Package.resolved for exact API.
        try await client.notificationClient(processSetup: processSetup).deletePusher(
            identifiers: PusherIdentifiers(pushkey: tokenHex, appId: PushConfig.appID)
        )
    }
}
```

> **Implementer notes:**
> - `setHttpPusher` / `deletePusher` argument shapes vary across SDK versions. Some releases call this `setPusher` with a `PusherKind` enum; check `Package.resolved`.
> - **iOS:** runs in `.multipleProcesses` so the NSE can also open the same store. **Mac:** runs in `.singleProcess` since there is no NSE — the host app is the only consumer of the crypto store on Mac.

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
                guard let container = StoragePaths.groupContainer else {
                    fallback(); return
                }
                // Match the main app's storage layout (Phase 1 AppDependencies):
                // sdk-store holds the SDK's SQLite + crypto store; sessions/
                // holds the persisted UserSession JSON via FileSessionStore.
                // KeychainStore conforms to SessionStore — once Phase 4 wires
                // the keychain-access-groups entitlement, swap FileSessionStore
                // for KeychainStore here so iOS app and NSE share session state.
                let sdkStore = container.appendingPathComponent("sdk-store")
                let sessionsDir = container.appendingPathComponent("sessions")
                let sessionStore = FileSessionStore(directory: sessionsDir)
                let auth = AuthServiceLive(sessionStore: sessionStore, basePath: sdkStore)
                guard let session = try await auth.restoreSession() else {
                    fallback(); return
                }
                let provider = ClientProvider(basePath: sdkStore)
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
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
git add MatronNSE/NotificationService.swift project.yml
git commit -m "feat: NSE decrypts event via PushDecoder and rewrites notification"
git push
```

---

### Task 5: PushBootstrap (cross-platform launch hook)

**Files:**
- Create: `MatronShared/Sources/Push/PushBootstrap.swift` (cross-platform; lives in MatronShared so both apps consume the same type)
- Modify: `Matron/App/MatronApp.swift` (iOS host wires `UIApplicationDelegateAdaptor`)
- Modify: `MatronMac/App/MatronMacApp.swift` (Mac host wires `NSApplicationDelegateAdaptor` — see also Task 11)

- [ ] **Step 1: Implement**

```swift
import Foundation
import UserNotifications
import MatronModels
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public final class PushBootstrap {
    private let pushService: PushService
    private let pusherBaseURL: URL
    let notificationSettings: NotificationSettingsProtocol
    let joinedRoomIDs: () async -> [String]

    public init(
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

    public func bootstrap() async throws {
        let granted = await pushService.requestPermission()
        guard granted else { return }
        try await ensureDefaultPushRules()                  // see Step 3
        // Platform-specific APNs registration. Both end up triggering an
        // application-delegate callback (UIApplicationDelegate on iOS,
        // NSApplicationDelegate on Mac) with the device token, which the
        // host app caches in PushTokenStore.
        #if os(iOS)
        await UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    public func register(token: Data) async {
        do {
            try await pushService.registerToken(token, pusherBaseURL: pusherBaseURL)
        } catch {
            // Log and surface as a Settings warning. Phase 4 doesn't gate UX on this.
        }
    }
}

@MainActor
public final class PushTokenStore {
    public static let shared = PushTokenStore()
    public var latestToken: Data?
    public var observers: [(Data) -> Void] = []
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
git add MatronShared/Sources/Push/PushBootstrap.swift Matron/App/MatronApp.swift \
        MatronShared/Sources/Push/PushBootstrap+PushRules.swift \
        MatronShared/Tests/PushTests/PushBootstrapPushRulesTests.swift \
        MatronShared/Tests/PushTests/Doubles/FakeNotificationSettings.swift
git commit -m "feat: cross-platform PushBootstrap requests permission, enables .m.rule.master, sets joined rooms to .allMessages, registers APNs token via UIApplication (iOS) / NSApplication (macOS)"
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

`sygnal.yaml` — **four app entries**, one per (platform × build-type):

```yaml
apps:
  chat.matron.ios:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.ios
    use_sandbox: false   # production iOS (TestFlight + App Store)
    push_type: alert
  chat.matron.ios.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.ios
    use_sandbox: true    # iOS debug/dev builds (Xcode Run, simulator, ad-hoc)
    push_type: alert
  chat.matron.mac:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac
    use_sandbox: false   # production Mac (Mac App Store + notarized)
    push_type: alert
  chat.matron.mac.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac
    use_sandbox: true    # Mac debug/dev builds (Xcode Run, locally signed)
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

The four `app_id` keys MUST match the four-way switch in `PushConfig.appID`
(`MatronShared/Sources/Push/PushConfig.swift`). All four entries reference the
same `.p8` keyfile (one APNs auth key covers the whole team) but split on
`topic` (bundle ID — `chat.matron.ios` for iOS, `chat.matron.mac` for Mac) and
on `use_sandbox` (debug builds → APNs sandbox, release builds → APNs production).

### APNs sandbox vs production

TestFlight, App Store, and notarized Mac App Store builds use the production APNs endpoint. Debug/dev builds on either platform (Xcode `Run`, iOS simulator deploys, ad-hoc development provisioning profiles, locally-signed Mac builds) use sandbox. Mismatched configs produce silent push failures — Sygnal accepts the request, APNs returns `BadDeviceToken` for the wrong endpoint, and the user simply never sees a notification.

Operationally we run **four** Sygnal app entries side-by-side (see `sygnal.yaml` above): `chat.matron.ios` + `chat.matron.ios.dev` + `chat.matron.mac` + `chat.matron.mac.dev`. Each app build picks the right `app_id` at compile time from `PushConfig.appID` (a `#if os(iOS)` / `#if os(macOS)` × `#if DEBUG` switch). Whenever you cut a TestFlight or Mac App Store build, double-check that `use_sandbox` on the matching Sygnal entry is `false` — a stray `true` here is the single most common cause of "push works on my Mac dev build but not in TestFlight" (or its Mac analogue).

## Cloudflare Tunnel

Add a route mapping `https://push.<domain>` → `http://127.0.0.1:5000`.

## matron-server (Tuwunel)

No specific config — pushers are per-user, registered by the iOS app via `POST /_matrix/client/v3/pushers`.

## Smoke test

**Pre-flight: verify all four app entries are reachable, AND that `use_sandbox` matches the build type you are testing against.**

```bash
# 1. All four app_ids must be present in the running config:
docker exec sygnal grep -E "^  chat\.matron\.(ios|mac)(\.dev)?:" /etc/sygnal.yaml
# Expect four matching lines: chat.matron.ios:, chat.matron.ios.dev:,
#                             chat.matron.mac:, chat.matron.mac.dev:
# A missing entry is a hard fail — Sygnal will respond with a 200 but
# {"rejected": ["<token>"]} and no APNs traffic ever leaves the host.

# 2. Sandbox flag for the specific app_id we're about to hit:
APP_ID=chat.matron.ios.dev    # or .ios, .mac, .mac.dev — pick one per smoke run
docker exec sygnal awk -v id="$APP_ID:" '$0 ~ id {found=1} found && /use_sandbox/ {print; exit}' /etc/sygnal.yaml
# Expect: use_sandbox: true   for a Debug/dev build of either platform
# Expect: use_sandbox: false  for a TestFlight / App Store / Mac App Store build

# 3a. iOS: cross-check by reading the embedded.mobileprovision from the .ipa:
unzip -p Matron.ipa "Payload/Matron.app/embedded.mobileprovision" \
  | security cms -D \
  | plutil -extract aps-environment xml1 -o - -
# Expect: <string>development</string>  → must pair with use_sandbox: true
# Expect: <string>production</string>   → must pair with use_sandbox: false

# 3b. Mac: read aps-environment out of the embedded provisioning profile or
#     directly out of the signed .app:
codesign -d --entitlements :- MatronMac.app 2>/dev/null \
  | plutil -extract aps-environment xml1 -o - -
# Expect the same development/production string with the same pairing rule.
```

Mismatched values here are a hard fail — abort the smoke test and fix the Sygnal config (or rebuild the IPA / `.app` with the correct provisioning profile) before sending traffic. Run the cURL below once per platform (substitute `app_id` and `pushkey` accordingly) to confirm both iOS and Mac entries route end-to-end.

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

### Task 9b: Manual test additions

> Renumbered to free up "Task 10" / "Task 11" for the Mac in-process push handler and Mac APNs registration tasks below. The manual-test additions stay co-located with the runbook task.

Append to `manual-tests.md`:

```markdown
## Phase 4 (Push & NSE)

### iOS — permission + token registration

- [ ] Fresh sign-in → notification permission prompt appears.
- [ ] Allow → no error in logs; `PushTokenStore.shared.latestToken` is non-nil.
- [ ] Background the app. Send a message from another Matrix client to the user.
- [ ] Notification appears with sender name + message body (decrypted by NSE).

### iOS — notification tap

- [ ] Tap the notification → app opens to that chat directly (NavigationStack push).

### iOS — multiple chats

- [ ] Receive notifications from two different bots → notifications stack as separate threads (per `threadIdentifier`).

### iOS — failure modes

- [ ] Disable notifications in iOS Settings → Settings → Device shows the warning.
- [ ] Sign out → notifications stop arriving (confirm by sending another message).

### Mac — permission + token registration

- [ ] Fresh sign-in on Mac → `UNUserNotificationCenter` permission prompt appears.
- [ ] Allow → no error in logs; `PushTokenStore.shared.latestToken` is non-nil after `applicationDidRegisterForRemoteNotifications` fires.

### Mac — push delivery (in-process, no NSE)

- [ ] Background the Mac app (or leave it foregrounded — both must work; `MacNotificationHandler.willPresent` re-presents the cleartext notification in either state).
- [ ] Send a message from another Matrix client to the user.
- [ ] Notification arrives on a real Mac with the app backgrounded; body is the decrypted text (not "New message").

### Mac — tap to open

- [ ] Tap notification → main window focuses (NSWorkspace activates the app), sidebar selects the right room, detail column shows that chat.
- [ ] If the app was hidden (`⌘H`) prior to the tap, it un-hides and activates first, then the room selection happens.

### Mac — failure modes

- [ ] Disable notifications for Matron at the OS level (System Settings → Notifications → Matron → Allow Notifications: off) → registration still completes without crashing; subsequent silent pushes are dropped silently by the OS, with no user-visible error.
- [ ] Sign out → notifications stop arriving on Mac too.

### Cross-platform smoke

- [ ] Same account signed in on iOS + Mac. Send a message from a third client. Both devices receive a decrypted push notification within seconds of each other.
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 4 manual test additions (iOS + Mac)"
git push
```

---

### Task 10: Mac in-process notification handler (`MacNotificationHandler`)

**Files:**
- Create: `MatronMac/App/MacNotificationHandler.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (register the handler as `UNUserNotificationCenter.current().delegate` in `init`)
- Create: `MatronShared/Tests/PushTests/MacNotificationHandlerTests.swift`

Mac handles silent pushes in-process — no NSE. The handler conforms to `UNUserNotificationCenterDelegate` and reuses the **same** `PushDecoder` shipped in Task 3 (closure-injectable design). There is no Mac-specific decoder; the only Mac-specific code is the delegate wrapper that bridges UN callbacks to `decoder.decode(...)` and the cleartext re-presentation.

- [ ] **Step 1: Failing test first (TDD)**

`MatronShared/Tests/PushTests/MacNotificationHandlerTests.swift` (Mac test scheme only):

```swift
#if os(macOS)
import XCTest
import UserNotifications
@testable import MatronPush

final class MacNotificationHandlerTests: XCTestCase {
    func test_willPresent_rewritesBodyWithDecodedText() async throws {
        // Fake fetcher returns a fixture text item.
        let item = NotificationItem.fixture(event: .text("hello mac"))
        let decoder = PushDecoder(fetcher: { _, _ in item })
        let handler = MacNotificationHandler(decoder: decoder)

        // Build a notification carrying room_id + event_id userInfo (mirrors the silent APNs payload).
        let content = UNMutableNotificationContent()
        content.userInfo = ["room_id": "!r:s", "event_id": "$evt"]
        let request = UNNotificationRequest(identifier: "x", content: content, trigger: nil)
        let notification = TestNotification(request: request)   // tiny shim — see Doubles/

        var presented: UNNotificationPresentationOptions?
        let captured = await withCheckedContinuation { cont in
            // Capture the cleartext content the handler chooses to present.
            handler.userNotificationCenter(
                UNUserNotificationCenter.current(),
                willPresent: notification
            ) { options in
                presented = options
                cont.resume(returning: notification.request.content)
            }
        }

        XCTAssertEqual(captured.body, "hello mac")
        XCTAssertEqual(captured.threadIdentifier, "!r:s")
        XCTAssertNotNil(presented)
    }

    func test_didReceive_postsOpenRoomCommand() async throws {
        let decoder = PushDecoder(fetcher: { _, _ in nil })
        let handler = MacNotificationHandler(decoder: decoder)

        let content = UNMutableNotificationContent()
        content.userInfo = ["room_id": "!r:s", "event_id": "$evt"]
        let request = UNNotificationRequest(identifier: "x", content: content, trigger: nil)
        let response = TestNotificationResponse(notification: TestNotification(request: request))

        let exp = expectation(description: "matronCommand posted")
        let token = NotificationCenter.default.addObserver(
            forName: .matronCommand, object: nil, queue: nil
        ) { note in
            if case .openRoom(let id) = note.userInfo?["command"] as? MatronCommand,
               id == "!r:s" { exp.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await withCheckedContinuation { cont in
            handler.userNotificationCenter(
                UNUserNotificationCenter.current(),
                didReceive: response
            ) { cont.resume() }
        }

        await fulfillment(of: [exp], timeout: 1.0)
    }
}
#endif
```

`TestNotification` / `TestNotificationResponse` are minimal stand-ins under `Tests/PushTests/Doubles/` that wrap a `UNNotificationRequest` (UN's concrete types are not directly constructible in tests). `MatronCommand.openRoom(String)` and `Notification.Name.matronCommand` are the cross-feature plumbing observed by `MacChatListView` (defined alongside this task; trivial enum + typed-userInfo helper).

Run the test, watch it fail (no impl).

- [ ] **Step 2: Implement**

```swift
#if os(macOS)
import AppKit
import UserNotifications
import MatronPush

public enum MatronCommand: Sendable {
    case openRoom(String)
}

public extension Notification.Name {
    static let matronCommand = Notification.Name("chat.matron.mac.command")
}

public extension Notification {
    static func matronCommand(_ command: MatronCommand) -> Notification {
        Notification(name: .matronCommand, object: nil, userInfo: ["command": command])
    }
}

@MainActor
public final class MacNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    private let decoder: PushDecoder

    public init(decoder: PushDecoder) {
        self.decoder = decoder
        super.init()
    }

    /// Foreground / silent: re-present the notification with cleartext body.
    /// Mac apps own the full process when notifications are delivered, so we
    /// can synchronously decrypt + rewrite content before UN displays it.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard let userInfo = notification.request.content.userInfo as? [String: Any],
              let roomID = userInfo["room_id"] as? String,
              let eventID = userInfo["event_id"] as? String,
              let mutable = notification.request.content.mutableCopy() as? UNMutableNotificationContent else {
            completionHandler([.banner, .sound, .list])
            return
        }
        Task {
            if let decoded = try? await decoder.decode(roomID: roomID, eventID: eventID) {
                mutable.title = decoded.title
                mutable.body = decoded.body
                mutable.threadIdentifier = decoded.threadIdentifier ?? roomID
                if let badge = decoded.badge { mutable.badge = NSNumber(value: badge) }
            }
            completionHandler([.banner, .sound, .list])
        }
    }

    /// Tap-to-open: focus main window + post matronCommand(.openRoom) for
    /// MacChatListView to observe and select the right sidebar row.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let roomID = response.notification.request.content.userInfo["room_id"] as? String else { return }
        // Activate the app (un-hides if hidden, brings main window to front).
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isMainWindow || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(.matronCommand(.openRoom(roomID)))
    }
}
#endif
```

Wire in `MatronMacApp.init`:

```swift
#if os(macOS)
import AppKit
@main
struct MatronMacApp: App {
    private let notificationHandler: MacNotificationHandler

    init() {
        let decoder = PushDecoder.live(provider: AppDependencies.shared.clientProvider,
                                       session: AppDependencies.shared.session)
        let handler = MacNotificationHandler(decoder: decoder)
        UNUserNotificationCenter.current().delegate = handler
        self.notificationHandler = handler
        // …rest of init…
    }
    // …scenes…
}
#endif
```

`MacChatListView` observes `Notification.Name.matronCommand` and selects the matching `ChatSummary` in its `NavigationSplitView` selection binding. (Wiring is one `.onReceive(NotificationCenter.default.publisher(for: .matronCommand))` block — trivial; included in the same commit.)

- [ ] **Step 3: Verify (both presentation paths)**

```bash
swift test --filter MacNotificationHandlerTests
```

Both tests must pass — `willPresent` rewrites cleartext, `didReceive` posts the open-room command.

- [ ] **Step 4: Commit**

```bash
git add MatronMac/App/MacNotificationHandler.swift MatronMac/App/MatronMacApp.swift \
        MatronShared/Tests/PushTests/MacNotificationHandlerTests.swift \
        MatronShared/Tests/PushTests/Doubles/TestNotification.swift
git commit -m "feat(mac): in-process UNUserNotificationCenterDelegate decrypts via shared PushDecoder, focuses window + selects room on tap"
git push
```

---

### Task 11: Mac APNs registration (`MacPushBootstrap`)

**Files:**
- Create: `MatronMac/App/MacPushBootstrap.swift` (Mac-side glue: `NSApplicationDelegateAdaptor` capturing the device token)
- Modify: `MatronMac/App/MatronMacApp.swift` (attach the adaptor + invoke shared `PushBootstrap.bootstrap()` post-login)
- Create: `MatronShared/Tests/PushTests/MacPushBootstrapTests.swift`

The shared cross-platform `PushBootstrap` from Task 5 handles everything except the device-token callback, which is platform-specific: iOS uses `UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, Mac uses `NSApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. This task adds the Mac side.

- [ ] **Step 1: Failing test first (TDD)**

`MatronShared/Tests/PushTests/MacPushBootstrapTests.swift` (Mac test scheme only):

```swift
#if os(macOS)
import XCTest
@testable import MatronPush

@MainActor
final class MacPushBootstrapTests: XCTestCase {
    func test_didRegisterForRemoteNotifications_storesTokenAndNotifiesObservers() async {
        let bytes: [UInt8] = [0xab, 0xcd, 0xef, 0x01]
        let token = Data(bytes)

        let exp = expectation(description: "observer called")
        PushTokenStore.shared.observers.append { received in
            XCTAssertEqual(received, token)
            exp.fulfill()
        }
        defer { PushTokenStore.shared.observers.removeAll() }

        let delegate = MatronMacAppDelegate()
        delegate.application(NSApp, didRegisterForRemoteNotificationsWithDeviceToken: token)

        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(PushTokenStore.shared.latestToken, token)
    }
}
#endif
```

Watch it fail (no `MatronMacAppDelegate` yet).

- [ ] **Step 2: Implement**

```swift
#if os(macOS)
import AppKit
import MatronPush

final class MatronMacAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushTokenStore.shared.latestToken = deviceToken
            PushTokenStore.shared.observers.forEach { $0(deviceToken) }
        }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Phase 4: log only. Likely cause on Mac: notifications disabled at OS level (System Settings → Notifications).
        // Surface as a Settings warning later (Phase 7).
    }
}
#endif
```

Attach in `MatronMacApp`:

```swift
#if os(macOS)
@NSApplicationDelegateAdaptor(MatronMacAppDelegate.self) var appDelegate
#endif
```

Then in the post-login branch of `MatronMacApp` (mirrors the iOS branch in Task 5 Step 2), invoke the shared `PushBootstrap.bootstrap()` once and observe `PushTokenStore` for the token, then `register(token:)`. The shared bootstrap calls `NSApplication.shared.registerForRemoteNotifications()` under `#if os(macOS)` — no Mac-specific bootstrap method needed.

- [ ] **Step 3: Verify**

```bash
swift test --filter MacPushBootstrapTests
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Commit**

```bash
git add MatronMac/App/MacPushBootstrap.swift MatronMac/App/MatronMacApp.swift \
        MatronShared/Tests/PushTests/MacPushBootstrapTests.swift
git commit -m "feat(mac): NSApplicationDelegateAdaptor captures APNs token and feeds shared PushBootstrap"
git push
```

---

### Task 12: Mac entitlements — `aps-environment`

**Files:**
- Modify: `MatronMac/MatronMac.entitlements`

Mac requires the same `aps-environment` entitlement as iOS to receive APNs traffic. The value is `development` for Xcode `Run` / locally signed builds and `production` for Mac App Store / notarized builds — XcodeGen flips it per build configuration. (iOS gets the same flip via the existing `Matron.entitlements`; this task is the Mac analogue.)

- [ ] **Step 1: Update `MatronMac.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>aps-environment</key>
    <string>development</string>   <!-- Release builds override to "production" via build setting -->
</dict>
</plist>
```

In `project.yml`, configure the per-configuration override on the `MatronMac` target so Release builds emit `production`:

```yaml
MatronMac:
  # …existing config…
  settings:
    base:
      CODE_SIGN_ENTITLEMENTS: MatronMac/MatronMac.entitlements
    configs:
      Debug:
        APS_ENVIRONMENT: development
      Release:
        APS_ENVIRONMENT: production
```

(Alternative: keep two separate entitlements files — `MatronMac.Debug.entitlements` + `MatronMac.Release.entitlements` — and select via `CODE_SIGN_ENTITLEMENTS` per config. Either works; the inline build-setting override is shown above for compactness.)

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git add MatronMac/MatronMac.entitlements project.yml
git commit -m "chore(mac): add aps-environment entitlement (development/production per build config)"
git push
```

---

## Phase 4 acceptance

1. All 12 tasks committed and pushed (Tasks 1–9 + 9b manual-tests + Tasks 10–12 Mac).
2. CI green for **both** iOS and macOS schemes.
3. Server-side: Sygnal smoke test returns `200 {"rejected":[]}` for **all four** app entries (`chat.matron.ios`, `chat.matron.ios.dev`, `chat.matron.mac`, `chat.matron.mac.dev`); pre-flight `awk` check confirms all four are in the running config.
4. Manual checklist passes on a physical iPhone (TestFlight build) **and** a real Mac (locally signed Debug build at minimum, ideally a TestFlight Mac build too) — simulator does not receive real APNs on either platform.

After acceptance, write Phase 5 plan (custom events).

---

## Plan self-review

- **NSE Xcode target (iOS-only):** Created in Task 1 Step 0 — Phase 1 wired the iOS host, the Mac host, and `MatronShared`; this phase owns the `MatronNSE` app-extension target, its `Info.plist`, its entitlements (App Group + keychain group), and a stub `NotificationService.swift` that compiles before Task 4 swaps in the real implementation. Verified via `xcodegen generate && xcodebuild -scheme MatronNSE -configuration Debug CODE_SIGNING_ALLOWED=NO build` before Push code lands. **No NSE on Mac** — macOS apps run their full process for delivered notifications, so decryption happens in-process via `MacNotificationHandler` (Task 10) without any extension target, App Group, or shared crypto store concern.
- **§8.1 Server side:** Documented in `docs/push-setup.md` (Task 9). Implementation is upstream Sygnal with **four app entries** (`chat.matron.ios`, `chat.matron.ios.dev`, `chat.matron.mac`, `chat.matron.mac.dev`); no app-side code. Sandbox vs production endpoints, `use_sandbox` config, and the build-type cross-check are explicit; the smoke-test pre-flight verifies all four entries are in the running config and that `aps-environment` (extracted from both iOS `embedded.mobileprovision` and Mac `codesign --entitlements`) matches `use_sandbox` per platform.
- **§8.2 App side — registration:** Cross-platform `PushService` (Tasks 1–2; `PushServiceLive` branches on `#if os(iOS)` / `#if os(macOS)` for `processSetup` mode and device display name) + cross-platform `PushBootstrap` (Task 5 Steps 1–2; the `bootstrap()` method calls `UIApplication.shared.registerForRemoteNotifications()` on iOS and `NSApplication.shared.registerForRemoteNotifications()` on Mac under `#if` branches).
- **§8.2 App side — four-way `appID`:** `PushConfig.appID` is a computed `String` with a nested `#if os(iOS)` / `#if os(macOS)` × `#if DEBUG` switch yielding one of `chat.matron.ios`, `chat.matron.ios.dev`, `chat.matron.mac`, `chat.matron.mac.dev`. Pinned to the four Sygnal entries in Task 9.
- **§8.2 App side — default push rules:** Task 5 Step 3 enables `.m.rule.master` if disabled and pins every joined room to `.allMessages`, with a sanity-check assertion on the resolved mode. Test-first: `PushBootstrapPushRulesTests` drives a `FakeNotificationSettings` to confirm both effects. Cross-platform — same logic on iOS and Mac.
- **§8.3 Receiving a push (iOS):** `PushDecoder` (Task 3) + `NotificationService.swift` (Task 4). The closure-injectable `Fetcher` shape lives in Task 3 from the start (no late refactor), and `NotificationService` calls `PushDecoder.live(provider:session:)`. Body construction has explicit cases for `m.text`, `m.image` (with/without alt), `m.file` (with/without name), `chat.matron.tool_call`, `chat.matron.ask_user`, with a `default → "New message"` fall-through that the Task 7 fixture suite pins.
- **§8.3 Receiving a push (Mac, in-process):** `MacNotificationHandler` (Task 10) reuses the **same** `PushDecoder` from Task 3 — closure-injectable design lets the Mac delegate call `decoder.decode(...)` synchronously inside `willPresent`, then re-presents the notification with cleartext body via the completion handler. No new decoder, no NSE, no App Group. Single-process crypto store access only.
- **§8.3 fixture coverage:** Task 7 is tests-only — eight cases covering every body variant plus the unknown-msgtype fall-through, all driven via the same closure fetcher Task 3 ships with. The same fixtures back the Mac handler tests in Task 10.
- **§8.4 Tap to open (iOS):** `NotificationDelegate` (Task 6) — `didReceive` deep-links via `NavigationStack` push.
- **§8.4 Tap to open (Mac):** `MacNotificationHandler.didReceive` (Task 10) — activates the app (`NSApp.activate(ignoringOtherApps: true)`), brings the main window to front (`makeKeyAndOrderFront`), and posts `Notification.Name.matronCommand` carrying `MatronCommand.openRoom(roomID)`. `MacChatListView` observes the notification and updates its `NavigationSplitView` selection. Task 10 Step 1 includes a coverage step asserting both willPresent (cleartext re-present) AND didReceive (open-room post) paths.
- **§7.1 Crypto store sharing:** Established in Phase 1 — iOS uses App Group; Mac uses single-process Application Support directory. NSE on iOS accesses the store in `processSetup: .multipleProcesses` mode (Tasks 3 & 4); Mac uses `processSetup: .singleProcess` (no concurrent NSE). The App Group + keychain entitlements are owned by Phase 4 in Task 1 Step 0 (iOS-only); Mac's `aps-environment` entitlement is owned by Task 12.
- **Mac entitlements (Task 12):** `MatronMac.entitlements` adds `aps-environment` with per-build-config override (`development` for Debug, `production` for Release) via XcodeGen build settings. Required for APNs traffic to reach the Mac app at all.
- **No snapshot tests:** Push notifications don't have snapshot test surfaces — they render via UN's system UI, not in-app SwiftUI. Skipped intentionally.
- **TDD discipline:** Tasks 3, 5 Step 3, 7, 10, and 11 all open with a failing test before any implementation lands; the Sygnal smoke test in Task 9 begins with a sandbox-vs-build + four-entry-presence verification gate.
- **Manual test coverage:** Task 9b splits per-platform — five iOS sections, five Mac sections (including the OS-level disabled-notifications failure mode and the un-hide-on-tap flow), plus a cross-platform smoke item.
- No placeholders. SDK API names flagged where they shift.
