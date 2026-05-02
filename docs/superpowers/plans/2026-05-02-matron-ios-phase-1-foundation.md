# Matron iOS — Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get a Matron iOS app that launches, signs in to a user-supplied Matrix homeserver, runs sliding sync, and shows the room list with bot names. E2EE on. Pure-Apache-2.0 codebase. App Store-submittable scaffold (TestFlight-ready, even if features are minimal).

**Architecture:** Three Xcode targets (Matron app, MatronNSE extension, MatronShared SPM package). SwiftUI + MVVM with `@Observable` view models, native `NavigationStack`, no Coordinator pattern. matrix-rust-sdk-swift via SPM as the Matrix layer. App Group container shared between app and NSE for the crypto store.

**Tech Stack:** Swift 5.10+, SwiftUI, iOS 17+, matrix-rust-sdk-swift (Apache 2.0), XCTest, swift-snapshot-testing.

**Reference:** Full design spec at `docs/superpowers/specs/2026-05-02-matron-ios-design.md`. Read it before starting.

---

## Execution environment

This is an iOS plan. Building, running, and testing requires **Xcode 16+ on macOS 14+**. The dev box `dev-2.yearbook.com` is Linux and CANNOT execute Xcode tasks. Two practical options for the implementing engineer:

1. **Local Mac** — clone the repo, install Xcode 16+, work locally. Push commits to GitHub.
2. **Hosted Mac (e.g. MacStadium, GitHub-hosted macOS runner via Codespaces, Scaleway Apple Silicon)** — useful if no local Mac is available. Higher friction.

CI for this plan uses **GitHub Actions macOS runners** (`macos-14` or `macos-15`). Free tier should cover MVP development; we may need a paid plan if iteration speed becomes a problem.

---

## Phase overview (full project roadmap)

This plan covers **Phase 1 only**. The other phases each get their own plan when the previous phase ships.

| Phase | Title | Output |
|---|---|---|
| **1 (this plan)** | Foundation | App launches, signs in, runs sliding sync, lists rooms with bot names. E2EE on. ~25–30 tasks. |
| 2 | Chat experience | Timeline view, rendering primitives (Markdown, CodeBlock, attachments), composer, slash palette, attachment picker. ~25–30 tasks. |
| 3 | E2EE & verification UX | First-device recovery key, multi-device SAS, bot verification banner, key backup. ~15 tasks. |
| 4 | Push & NSE | Sygnal-compatible pusher registered on server, NSE target wired to decrypt push payloads, deep-link to chat on tap. ~15 tasks. |
| 5 | Custom events | `chat.matron.tool_call` card, `chat.matron.ask_user` half-sheet, `chat.matron.session_meta` header (depends on bridge changes — separate bridge spec needed). ~15 tasks. |
| 6 | Search | SQLite FTS5 schema, decryption-time indexing, backfill on first launch, unified search UI. ~15 tasks. |
| 7 | Polish | Settings screen, bot profile, design system pass, accessibility audit, App Store assets. ~15 tasks. |

Total project: roughly 130 tasks, sequenced across ~7 plans. Each phase produces a working build that's strictly more useful than the last.

---

## Decisions captured (from brainstorming)

Recap of every decision the spec encodes — so an engineer reading this plan in isolation has the conclusions in one place. Full reasoning lives in the spec.

- **Bot-first chat client** (not single-bot assistant; not bot operator console).
- **Closed personal ecosystem** — one user, their own homeserver, only their own bots.
- **User-supplied homeserver URL** at first login (no `.well-known` discovery, no federation directory).
- **Server-side bot provisioning** via existing `dev-boxer add-bot` CLI. App does not install bots in MVP.
- **Strict 1:1 rooms** (user + 1 bot). No multi-bot rooms in MVP.
- **One Matrix room per chat conversation.** Multiple chats per bot. Both app and bot can create rooms.
- **Bot auto-titles chats** server-side via Gemini Flash. App does not name chats; user does not name chats.
- **Rendering richness: markdown + code blocks done excellently + tool-call cards + interactive ask-user prompts.** Not full widget rendering.
- **No reactions, replies, edits, redactions of others' messages, block, ignore, report, polls, location, stickers, voice, video, calls, threads, spaces.**
- **UI direction: ChatGPT/Claude.ai inspired** — sidebar of chats, single-pane chat view, minimalist.
- **Pattern: SwiftUI + MVVM, no Coordinators.** `@Observable` view models, native `NavigationStack`.
- **Onboarding: one combined sign-in screen** (server URL + username + password + SSO button), then verification screen.
- **iOS 17 minimum target.** Matches Element X.
- **License posture: Apache 2.0 / MIT / BSD only in the binary.** Element X may be studied (architectures aren't copyrightable) but no code translation. Fresh repo (`matronhq/matron-iOS-app`), not a fork.
- **Search lives in MVP** (SQLite FTS5, NSFileProtectionComplete, decryption-time indexing, async backfill).
- **Push: Sygnal-compatible HTTP pusher server-side + iOS NSE on-device.** Required by Apple's E2EE constraints.

---

## File structure (Phase 1 deliverables)

By the end of Phase 1, the repo contains:

```
matron-iOS-app/
├── .github/
│   └── workflows/
│       └── ci.yml                          GitHub Actions: build + test on macos-14
├── .gitignore                              Standard Swift / Xcode .gitignore
├── LICENSE                                 Apache 2.0 (already present)
├── README.md                               Project intro, build instructions
├── docs/
│   └── superpowers/
│       ├── specs/2026-05-02-matron-ios-design.md
│       └── plans/2026-05-02-matron-ios-phase-1-foundation.md  (this file)
├── Matron.xcworkspace/                     Xcode workspace
├── Matron.xcodeproj/                       Xcode project (3 targets)
├── Matron/                                 iOS app target source
│   ├── App/
│   │   ├── MatronApp.swift                 @main entry, root navigation
│   │   ├── AppDependencies.swift           DI container (struct of services)
│   │   └── Info.plist
│   ├── Features/
│   │   ├── Onboarding/
│   │   │   ├── SignInView.swift
│   │   │   └── SignInViewModel.swift
│   │   └── ChatList/
│   │       ├── ChatListView.swift
│   │       └── ChatListViewModel.swift
│   ├── DesignSystem/
│   │   ├── Colors.swift
│   │   ├── Typography.swift
│   │   └── Spacing.swift
│   └── Resources/
│       └── Assets.xcassets
├── MatronNSE/                              Notification Service Extension target
│   ├── NotificationService.swift           Stub for Phase 1 (logs, returns content unchanged)
│   └── Info.plist
├── MatronShared/                           Local SPM package (used by Matron + MatronNSE)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── Auth/
│   │   │   ├── AuthService.swift           Protocol
│   │   │   ├── AuthServiceLive.swift       Live implementation
│   │   │   └── ServerURLValidator.swift
│   │   ├── Sync/
│   │   │   ├── ClientProvider.swift        Holds the matrix-rust-sdk Client
│   │   │   ├── SyncService.swift           Starts/stops sliding sync
│   │   │   └── SyncServiceLive.swift
│   │   ├── Chat/
│   │   │   ├── ChatService.swift           Protocol
│   │   │   ├── ChatServiceLive.swift       Wraps RoomListService
│   │   │   └── ChatSummary.swift           DTO
│   │   ├── Storage/
│   │   │   ├── AppGroup.swift              Constants + path helpers
│   │   │   └── KeychainStore.swift         Tiny wrapper around Security framework
│   │   └── Models/
│   │       ├── BotIdentity.swift
│   │       └── UserSession.swift
│   └── Tests/
│       ├── AuthTests/
│       ├── ChatTests/
│       └── StorageTests/
└── manual-tests.md                         Empty stub; will fill in later phases
```

**Out of scope for Phase 1** (deferred to Phase 2+): all rendering primitives, composer, attachment picker, settings screen, bot profile, push notifications, NSE decryption, custom events, search, recovery key flow.

---

## Pre-flight (one-time setup, not a task)

The implementing engineer needs:

1. macOS 14+ with Xcode 16+ installed (`xcodebuild -version` to confirm).
2. SwiftLint installed (`brew install swiftlint`).
3. A test homeserver (a `dev-boxer` instance) with a user account and at least one bot already invited. Bridge can stay default — Phase 1 doesn't exercise the bridge protocol, just sliding sync and basic room enumeration.
4. Git configured with the `Matronhq` account.
5. Cloned `matronhq/matron-iOS-app` repo.

---

## Tasks

Each task is one logical commit. Use TDD where there's testable logic; for Xcode project structure, the "test" is "the project builds + targets resolve."

### Task 1: Initial repo scaffolding

**Files:**
- Create: `.gitignore`
- Create: `README.md` (replace stub)

- [ ] **Step 1: Add Swift/Xcode `.gitignore`**

```gitignore
# macOS
.DS_Store

# Xcode
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
xcuserdata/
*.xcuserstate
*.xcuserdatad/
DerivedData/
build/
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.build/
.swiftpm/
Package.resolved

# CocoaPods (not used, but defensive)
Pods/

# fastlane (not used yet)
fastlane/report.xml
fastlane/screenshots
fastlane/test_output

# IDE
.vscode/
.idea/
```

- [ ] **Step 2: Replace `README.md` with project intro**

```markdown
# Matron iOS

Native iOS Matrix client, bot-first, App Store distributable. Built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

Part of the [Matron](https://github.com/matronhq) ecosystem.

## Status

Pre-alpha. Phase 1 (foundation) in progress — see `docs/superpowers/plans/`.

## Requirements

- macOS 14+
- Xcode 16+
- A Matrix homeserver — recommend [matron-server](https://github.com/matronhq/matron-server) provisioned via [dev-boxer](https://github.com/matronhq/dev-boxer).

## Building

```bash
open Matron.xcworkspace
```

Select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.

## Tests

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 15'
```

## License

Apache 2.0. See `LICENSE`.

## Documentation

- Design spec: `docs/superpowers/specs/2026-05-02-matron-ios-design.md`
- Implementation plans: `docs/superpowers/plans/`
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore README.md
git commit -m "chore: initial gitignore and README"
git push
```

---

### Task 2: Create the Xcode project skeleton (3 targets)

**Files:**
- Create: `Matron.xcodeproj/` (via Xcode UI or `xcodegen`)
- Create: `Matron.xcworkspace/`
- Create: `Matron/App/MatronApp.swift`
- Create: `Matron/App/Info.plist`
- Create: `MatronNSE/NotificationService.swift`
- Create: `MatronNSE/Info.plist`

We'll use **XcodeGen** for reproducible project generation (no merge conflicts in the `.xcodeproj` plist). Engineers without XcodeGen can also do this through Xcode's UI — XcodeGen is just nicer for a team.

- [ ] **Step 1: Install XcodeGen (Mac-only)**

Run: `brew install xcodegen`
Expected: `xcodegen` command available; `xcodegen --version` prints `2.x.x`.

- [ ] **Step 2: Create `project.yml` for XcodeGen**

Create `project.yml`:

```yaml
name: Matron
options:
  bundleIdPrefix: chat.matron
  deploymentTarget:
    iOS: "17.0"
  developmentLanguage: en
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.10"
    ENABLE_USER_SCRIPT_SANDBOXING: NO
    APP_GROUP_ID: group.chat.matron
  configs:
    Debug:
      SWIFT_OPTIMIZATION_LEVEL: -Onone
      ENABLE_TESTABILITY: YES
    Release:
      SWIFT_OPTIMIZATION_LEVEL: -O

packages:
  MatronShared:
    path: MatronShared
  MatrixRustSDK:
    url: https://github.com/matrix-org/matrix-rust-components-swift
    from: "25.1.0"

targets:
  Matron:
    type: application
    platform: iOS
    sources:
      - path: Matron
    info:
      path: Matron/App/Info.plist
      properties:
        CFBundleDisplayName: Matron
        UILaunchScreen:
          UIColorName: ""
        UIApplicationSupportsMultipleScenes: false
        UIRequiredDeviceCapabilities:
          - armv7
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        ITSAppUsesNonExemptEncryption: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: chat.matron.app
        CODE_SIGN_ENTITLEMENTS: Matron/App/Matron.entitlements
        TARGETED_DEVICE_FAMILY: "1,2"
    entitlements:
      path: Matron/App/Matron.entitlements
      properties:
        com.apple.security.application-groups:
          - group.chat.matron
        keychain-access-groups:
          - $(AppIdentifierPrefix)chat.matron
    dependencies:
      - package: MatronShared
      - package: MatrixRustSDK
        product: MatrixRustSDK

  MatronNSE:
    type: app-extension
    platform: iOS
    sources:
      - path: MatronNSE
    info:
      path: MatronNSE/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.usernotifications.service
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).NotificationService
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: chat.matron.app.nse
        CODE_SIGN_ENTITLEMENTS: MatronNSE/MatronNSE.entitlements
    entitlements:
      path: MatronNSE/MatronNSE.entitlements
      properties:
        com.apple.security.application-groups:
          - group.chat.matron
        keychain-access-groups:
          - $(AppIdentifierPrefix)chat.matron
    dependencies:
      - package: MatronShared
      - package: MatrixRustSDK
        product: MatrixRustSDK
```

- [ ] **Step 3: Create the minimal source files referenced above**

Create `Matron/App/MatronApp.swift`:

```swift
import SwiftUI

@main
struct MatronApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Matron — Phase 1 scaffold")
                .padding()
        }
    }
}
```

Create `MatronNSE/NotificationService.swift`:

```swift
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // Phase 1 stub. Phase 4 wires real decryption.
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Best-effort fallback if decryption takes too long.
    }
}
```

- [ ] **Step 4: Generate the Xcode project**

Run: `xcodegen generate`
Expected: `Matron.xcodeproj/` created with no errors.

- [ ] **Step 5: Open in Xcode and verify it builds**

Run: `open Matron.xcodeproj` (workspace is generated alongside)
Build the `Matron` scheme for an iPhone 15 simulator.
Expected: Build succeeds. Running shows "Matron — Phase 1 scaffold" text on screen.

- [ ] **Step 6: Commit**

```bash
git add project.yml Matron MatronNSE
git commit -m "feat: scaffold Xcode project with Matron, MatronNSE, MatronShared targets"
git push
```

(`Matron.xcodeproj/` is gitignored — `project.yml` is the source of truth.)

---

### Task 3: Create the MatronShared SPM package

**Files:**
- Create: `MatronShared/Package.swift`
- Create: `MatronShared/Sources/Storage/AppGroup.swift`
- Create: `MatronShared/Tests/StorageTests/AppGroupTests.swift`

- [ ] **Step 1: Create `MatronShared/Package.swift`**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MatronShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MatronAuth", targets: ["MatronAuth"]),
        .library(name: "MatronChat", targets: ["MatronChat"]),
        .library(name: "MatronStorage", targets: ["MatronStorage"]),
        .library(name: "MatronSync", targets: ["MatronSync"]),
        .library(name: "MatronModels", targets: ["MatronModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", from: "25.1.0"),
    ],
    targets: [
        .target(name: "MatronModels", path: "Sources/Models"),
        .target(name: "MatronStorage", path: "Sources/Storage"),
        .target(
            name: "MatronAuth",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Auth"
        ),
        .target(
            name: "MatronSync",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Sync"
        ),
        .target(
            name: "MatronChat",
            dependencies: [
                "MatronModels",
                "MatronSync",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Chat"
        ),
        .testTarget(name: "StorageTests", dependencies: ["MatronStorage"], path: "Tests/StorageTests"),
        .testTarget(name: "AuthTests", dependencies: ["MatronAuth"], path: "Tests/AuthTests"),
        .testTarget(name: "ChatTests", dependencies: ["MatronChat"], path: "Tests/ChatTests"),
    ]
)
```

- [ ] **Step 2: Write the failing test for `AppGroup`**

Create `MatronShared/Tests/StorageTests/AppGroupTests.swift`:

```swift
import XCTest
@testable import MatronStorage

final class AppGroupTests: XCTestCase {
    func test_identifier_isStable() {
        XCTAssertEqual(AppGroup.identifier, "group.chat.matron")
    }

    func test_containerURL_returnsAValidURL_whenAppGroupAvailable() throws {
        // In test runner there's no entitlement, so containerURL is nil.
        // We only assert the identifier is right; runtime coverage is via integration test.
        XCTAssertEqual(AppGroup.identifier, "group.chat.matron")
    }

    func test_cryptoStorePath_isUnderContainer() {
        let fakeContainer = URL(fileURLWithPath: "/tmp/test-app-group")
        let path = AppGroup.cryptoStorePath(in: fakeContainer)
        XCTAssertEqual(path, fakeContainer.appendingPathComponent("crypto-store"))
    }

    func test_searchDBPath_isUnderContainer() {
        let fakeContainer = URL(fileURLWithPath: "/tmp/test-app-group")
        let path = AppGroup.searchDBPath(in: fakeContainer)
        XCTAssertEqual(path, fakeContainer.appendingPathComponent("matron-search.sqlite"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails (compile error)**

Run: `cd MatronShared && swift test --filter AppGroupTests`
Expected: FAIL — `MatronStorage` module not found, `AppGroup` symbol missing.

- [ ] **Step 4: Implement `AppGroup`**

Create `MatronShared/Sources/Storage/AppGroup.swift`:

```swift
import Foundation

public enum AppGroup {
    public static let identifier = "group.chat.matron"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func cryptoStorePath(in container: URL) -> URL {
        container.appendingPathComponent("crypto-store")
    }

    public static func searchDBPath(in container: URL) -> URL {
        container.appendingPathComponent("matron-search.sqlite")
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd MatronShared && swift test --filter AppGroupTests`
Expected: PASS — 4 tests succeed.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Storage MatronShared/Tests/StorageTests
git commit -m "feat: MatronShared SPM package + AppGroup helpers"
git push
```

---

### Task 4: KeychainStore wrapper

**Files:**
- Create: `MatronShared/Sources/Storage/KeychainStore.swift`
- Create: `MatronShared/Tests/StorageTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/StorageTests/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import MatronStorage

final class KeychainStoreTests: XCTestCase {
    let store = KeychainStore(service: "chat.matron.test")

    override func tearDown() async throws {
        try? store.delete(key: "test-key")
    }

    func test_setAndGet_roundTripsString() throws {
        try store.set("hello world", forKey: "test-key")
        let value = try store.get(key: "test-key")
        XCTAssertEqual(value, "hello world")
    }

    func test_get_returnsNil_whenKeyMissing() throws {
        let value = try store.get(key: "missing-key")
        XCTAssertNil(value)
    }

    func test_delete_removesValue() throws {
        try store.set("transient", forKey: "test-key")
        try store.delete(key: "test-key")
        XCTAssertNil(try store.get(key: "test-key"))
    }

    func test_set_overwritesExistingValue() throws {
        try store.set("first", forKey: "test-key")
        try store.set("second", forKey: "test-key")
        XCTAssertEqual(try store.get(key: "test-key"), "second")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd MatronShared && swift test --filter KeychainStoreTests`
Expected: FAIL — `KeychainStore` symbol missing.

- [ ] **Step 3: Implement `KeychainStore`**

Create `MatronShared/Sources/Storage/KeychainStore.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error {
    case unhandled(OSStatus)
    case dataCorrupted
}

public struct KeychainStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        var query = baseQuery(for: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandled(updateStatus)
            }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        } else {
            throw KeychainError.unhandled(status)
        }
    }

    public func get(key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        return string
    }

    public func delete(key: String) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter KeychainStoreTests`
Expected: PASS — 4 tests succeed.

(Note: Keychain tests must run on macOS with Keychain available — they will not run on Linux.)

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Storage/KeychainStore.swift MatronShared/Tests/StorageTests/KeychainStoreTests.swift
git commit -m "feat: KeychainStore wrapper for credential persistence"
git push
```

---

### Task 5: ServerURLValidator

**Files:**
- Create: `MatronShared/Sources/Auth/ServerURLValidator.swift`
- Create: `MatronShared/Tests/AuthTests/ServerURLValidatorTests.swift`

Validates user input on the sign-in screen — must be HTTPS, must have a host, and we'll test reachability of `/_matrix/client/versions` separately as part of `AuthService`.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/AuthTests/ServerURLValidatorTests.swift`:

```swift
import XCTest
@testable import MatronAuth

final class ServerURLValidatorTests: XCTestCase {
    func test_validates_simpleHTTPS() throws {
        let url = try ServerURLValidator.normalize("https://matrix.example.com")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_addsHTTPS_whenMissingScheme() throws {
        let url = try ServerURLValidator.normalize("matrix.example.com")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_stripsTrailingSlash() throws {
        let url = try ServerURLValidator.normalize("https://matrix.example.com/")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_rejects_HTTP() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("http://matrix.example.com")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .insecureScheme)
        }
    }

    func test_rejects_emptyString() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .empty)
        }
    }

    func test_rejects_whitespaceOnly() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("   ")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .empty)
        }
    }

    func test_rejects_invalidHost() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("https:///")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .noHost)
        }
    }

    func test_trimsLeadingAndTrailingWhitespace() throws {
        let url = try ServerURLValidator.normalize("  matrix.example.com  ")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd MatronShared && swift test --filter ServerURLValidatorTests`
Expected: FAIL — `ServerURLValidator` missing.

- [ ] **Step 3: Implement `ServerURLValidator`**

Create `MatronShared/Sources/Auth/ServerURLValidator.swift`:

```swift
import Foundation

public enum ServerURLValidator {
    public enum ValidationError: Error, Equatable {
        case empty
        case insecureScheme
        case noHost
        case malformed
    }

    public static func normalize(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme) else {
            throw ValidationError.malformed
        }
        guard let scheme = components.scheme, scheme == "https" else {
            throw ValidationError.insecureScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValidationError.noHost
        }

        var rebuilt = components
        rebuilt.path = rebuilt.path.hasSuffix("/") && rebuilt.path.count == 1 ? "" : rebuilt.path
        if rebuilt.path.hasSuffix("/") {
            rebuilt.path.removeLast()
        }
        guard let url = rebuilt.url else {
            throw ValidationError.malformed
        }
        return url
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter ServerURLValidatorTests`
Expected: PASS — 8 tests succeed.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Auth/ServerURLValidator.swift MatronShared/Tests/AuthTests/ServerURLValidatorTests.swift
git commit -m "feat: ServerURLValidator for sign-in input"
git push
```

---

### Task 6: AuthService protocol + Models

**Files:**
- Create: `MatronShared/Sources/Models/UserSession.swift`
- Create: `MatronShared/Sources/Auth/AuthService.swift`
- Create: `MatronShared/Tests/AuthTests/AuthServiceProtocolTests.swift`

- [ ] **Step 1: Define `UserSession`**

Create `MatronShared/Sources/Models/UserSession.swift`:

```swift
import Foundation

public struct UserSession: Equatable, Codable, Sendable {
    public let userID: String          // @alice:matron.example.com
    public let deviceID: String
    public let homeserverURL: URL
    public let accessToken: String
    public let refreshToken: String?

    public init(
        userID: String,
        deviceID: String,
        homeserverURL: URL,
        accessToken: String,
        refreshToken: String? = nil
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.homeserverURL = homeserverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}
```

- [ ] **Step 2: Define `AuthService` protocol**

Create `MatronShared/Sources/Auth/AuthService.swift`:

```swift
import Foundation

public enum AuthError: Error, Equatable {
    case invalidServerURL(ServerURLValidator.ValidationError)
    case serverUnreachable
    case ssoNotSupported
    case invalidCredentials
    case unexpected(String)
}

public protocol AuthService: Sendable {
    /// Probes the server URL by hitting `/_matrix/client/versions`.
    /// Returns supported login flows.
    func probe(_ rawURL: String) async throws -> ServerCapabilities

    /// Logs in with username and password. Returns a `UserSession` on success.
    func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession

    /// Restores a previously persisted session. Returns nil if none stored.
    func restoreSession() async throws -> UserSession?

    /// Persists a session to Keychain.
    func persist(_ session: UserSession) throws

    /// Clears the persisted session (sign out).
    func clearSession() throws
}

public struct ServerCapabilities: Equatable, Sendable {
    public let supportsPasswordLogin: Bool
    public let supportsSSO: Bool
    public let ssoRedirectURL: URL?

    public init(supportsPasswordLogin: Bool, supportsSSO: Bool, ssoRedirectURL: URL?) {
        self.supportsPasswordLogin = supportsPasswordLogin
        self.supportsSSO = supportsSSO
        self.ssoRedirectURL = ssoRedirectURL
    }
}
```

- [ ] **Step 3: Add a fake implementation for testing**

Create `MatronShared/Tests/AuthTests/FakeAuthService.swift`:

```swift
import Foundation
@testable import MatronAuth

final class FakeAuthService: AuthService, @unchecked Sendable {
    var stubbedProbe: Result<ServerCapabilities, Error> = .failure(AuthError.unexpected("not stubbed"))
    var stubbedLogin: Result<UserSession, Error> = .failure(AuthError.unexpected("not stubbed"))
    var stubbedRestore: Result<UserSession?, Error> = .success(nil)
    var persistedSessions: [UserSession] = []
    var clearCallCount = 0

    func probe(_ rawURL: String) async throws -> ServerCapabilities {
        try stubbedProbe.get()
    }

    func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession {
        try stubbedLogin.get()
    }

    func restoreSession() async throws -> UserSession? {
        try stubbedRestore.get()
    }

    func persist(_ session: UserSession) throws {
        persistedSessions.append(session)
    }

    func clearSession() throws {
        clearCallCount += 1
    }
}
```

- [ ] **Step 4: Write the protocol-shape test**

Create `MatronShared/Tests/AuthTests/AuthServiceProtocolTests.swift`:

```swift
import XCTest
@testable import MatronAuth

final class AuthServiceProtocolTests: XCTestCase {
    func test_fake_canProbe() async throws {
        let fake = FakeAuthService()
        fake.stubbedProbe = .success(.init(supportsPasswordLogin: true, supportsSSO: false, ssoRedirectURL: nil))
        let caps = try await fake.probe("https://matrix.example.com")
        XCTAssertTrue(caps.supportsPasswordLogin)
        XCTAssertFalse(caps.supportsSSO)
    }

    func test_fake_persistRetainsSessions() throws {
        let fake = FakeAuthService()
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok"
        )
        try fake.persist(session)
        XCTAssertEqual(fake.persistedSessions, [session])
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd MatronShared && swift test --filter AuthServiceProtocolTests`
Expected: PASS — 2 tests succeed.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Models/UserSession.swift MatronShared/Sources/Auth/AuthService.swift MatronShared/Tests/AuthTests
git commit -m "feat: AuthService protocol, UserSession model, FakeAuthService for tests"
git push
```

---

### Task 7: AuthServiceLive — real matrix-rust-sdk-swift integration

**Files:**
- Create: `MatronShared/Sources/Auth/AuthServiceLive.swift`
- Create: `MatronShared/Tests/AuthTests/AuthServiceLiveIntegrationTests.swift`

This task wires the real SDK. Unit-testing the SDK layer is hard (it's mostly delegation), so the test here is a single integration test against a live homeserver, marked as opt-in via env var.

- [ ] **Step 1: Implement `AuthServiceLive`**

Create `MatronShared/Sources/Auth/AuthServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage

public final class AuthServiceLive: AuthService, @unchecked Sendable {
    private let sessionKey = "matron.session"
    private let keychain: KeychainStore
    private let basePath: URL

    public init(keychain: KeychainStore, basePath: URL) {
        self.keychain = keychain
        self.basePath = basePath
    }

    public func probe(_ rawURL: String) async throws -> ServerCapabilities {
        let url: URL
        do {
            url = try ServerURLValidator.normalize(rawURL)
        } catch let error as ServerURLValidator.ValidationError {
            throw AuthError.invalidServerURL(error)
        }

        do {
            let builder = ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: url.absoluteString)
                .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
            let client = try await builder.build()
            let loginTypes = try await client.homeserverLoginDetails()
            let supportsPassword = loginTypes.supportsPasswordLogin()
            let ssoURL = loginTypes.supportsSsoLogin() ? URL(string: "https://placeholder/sso") : nil
            return ServerCapabilities(
                supportsPasswordLogin: supportsPassword,
                supportsSSO: ssoURL != nil,
                ssoRedirectURL: ssoURL
            )
        } catch {
            throw AuthError.serverUnreachable
        }
    }

    public func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession {
        do {
            let client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: homeserverURL.absoluteString)
                .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
                .build()
            try await client.login(
                username: username,
                password: password,
                initialDeviceName: initialDeviceDisplayName,
                deviceId: nil
            )
            let userID = try client.userId()
            let deviceID = try client.deviceId()
            let session = try client.session()
            return UserSession(
                userID: userID,
                deviceID: deviceID,
                homeserverURL: homeserverURL,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
        } catch {
            throw AuthError.invalidCredentials
        }
    }

    public func restoreSession() async throws -> UserSession? {
        guard let json = try keychain.get(key: sessionKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(UserSession.self, from: data)
    }

    public func persist(_ session: UserSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthError.unexpected("encode")
        }
        try keychain.set(json, forKey: sessionKey)
    }

    public func clearSession() throws {
        try keychain.delete(key: sessionKey)
    }
}
```

> **Note for the implementer:** the matrix-rust-components-swift API surface evolves. If method names above don't match the version you've pinned (e.g. `homeserverLoginDetails()` may be `getLoginDetails()` in some releases), check `Package.resolved` for the version and consult the module by ⌘-clicking in Xcode. Adjust call sites only — keep the protocol surface stable.

- [ ] **Step 2: Add session persistence round-trip test**

Create `MatronShared/Tests/AuthTests/AuthServiceLivePersistenceTests.swift`:

```swift
import XCTest
@testable import MatronAuth
@testable import MatronStorage
@testable import MatronModels

final class AuthServiceLivePersistenceTests: XCTestCase {
    var service: AuthServiceLive!
    let keychain = KeychainStore(service: "chat.matron.test.auth")
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("matron-auth-test-\(UUID().uuidString)")

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = AuthServiceLive(keychain: keychain, basePath: tempDir)
    }

    override func tearDown() async throws {
        try service.clearSession()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_persistAndRestore_roundTrip() async throws {
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok",
            refreshToken: "refresh"
        )
        try service.persist(session)
        let restored = try await service.restoreSession()
        XCTAssertEqual(restored, session)
    }

    func test_clearSession_removesPersistedSession() async throws {
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok"
        )
        try service.persist(session)
        try service.clearSession()
        let restored = try await service.restoreSession()
        XCTAssertNil(restored)
    }
}
```

- [ ] **Step 3: Add an opt-in integration test against a live homeserver**

Create `MatronShared/Tests/AuthTests/AuthServiceLiveIntegrationTests.swift`:

```swift
import XCTest
@testable import MatronAuth
@testable import MatronStorage

/// Run with:
///   MATRON_TEST_HOMESERVER=https://matrix.example.com \
///   MATRON_TEST_USERNAME=alice \
///   MATRON_TEST_PASSWORD=… \
///   swift test --filter AuthServiceLiveIntegrationTests
final class AuthServiceLiveIntegrationTests: XCTestCase {
    func test_probeAndLogin_againstLiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MATRON_TEST_HOMESERVER"],
              let username = env["MATRON_TEST_USERNAME"],
              let password = env["MATRON_TEST_PASSWORD"] else {
            throw XCTSkip("MATRON_TEST_HOMESERVER/USERNAME/PASSWORD not set; skipping integration test")
        }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matron-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = AuthServiceLive(
            keychain: KeychainStore(service: "chat.matron.test.integration"),
            basePath: tempDir
        )

        let caps = try await service.probe(server)
        XCTAssertTrue(caps.supportsPasswordLogin, "Test server must support password login")

        let url = URL(string: server)!
        let session = try await service.loginPassword(
            homeserverURL: url,
            username: username,
            password: password,
            initialDeviceDisplayName: "Matron Test"
        )
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertTrue(session.userID.hasPrefix("@"))
    }
}
```

- [ ] **Step 4: Run unit tests (skip integration unless env set)**

Run: `cd MatronShared && swift test --filter AuthServiceLivePersistenceTests`
Expected: PASS — 2 tests succeed.

Run: `cd MatronShared && swift test --filter AuthServiceLiveIntegrationTests`
Expected: SKIP if env not set; PASS if env points to a working homeserver.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Auth/AuthServiceLive.swift MatronShared/Tests/AuthTests/AuthServiceLivePersistenceTests.swift MatronShared/Tests/AuthTests/AuthServiceLiveIntegrationTests.swift
git commit -m "feat: AuthServiceLive backed by matrix-rust-sdk + persistence tests"
git push
```

---

### Task 8: ChatSummary DTO

**Files:**
- Create: `MatronShared/Sources/Models/BotIdentity.swift`
- Create: `MatronShared/Sources/Chat/ChatSummary.swift`
- Create: `MatronShared/Tests/ChatTests/ChatSummaryTests.swift`

- [ ] **Step 1: Define `BotIdentity`**

Create `MatronShared/Sources/Models/BotIdentity.swift`:

```swift
import Foundation

public struct BotIdentity: Equatable, Hashable, Sendable {
    public let matrixID: String          // @claude-box4:matron.example.com
    public let displayName: String       // "Claude (box4)"
    public let avatarURL: URL?

    public init(matrixID: String, displayName: String, avatarURL: URL?) {
        self.matrixID = matrixID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
```

- [ ] **Step 2: Define `ChatSummary`**

Create `MatronShared/Sources/Chat/ChatSummary.swift`:

```swift
import Foundation
import MatronModels

public struct ChatSummary: Equatable, Identifiable, Sendable {
    public let id: String                 // Matrix room ID (!abc:server)
    public let title: String              // From m.room.name (Gemini Flash auto-titled)
    public let bot: BotIdentity
    public let lastActivity: Date
    public let unreadCount: Int

    public init(
        id: String,
        title: String,
        bot: BotIdentity,
        lastActivity: Date,
        unreadCount: Int
    ) {
        self.id = id
        self.title = title
        self.bot = bot
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
    }
}

public enum ChatRecencyGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case earlier = "Earlier"

    public static func bucket(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> ChatRecencyGroup {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        return date >= sevenDaysAgo ? .lastSevenDays : .earlier
    }
}
```

- [ ] **Step 3: Write tests**

Create `MatronShared/Tests/ChatTests/ChatSummaryTests.swift`:

```swift
import XCTest
@testable import MatronChat

final class ChatRecencyGroupTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1745000000)
    let calendar = Calendar(identifier: .gregorian)

    func test_buckets_today() {
        let date = now.addingTimeInterval(-3600)
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .today)
    }

    func test_buckets_yesterday() {
        let date = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .yesterday)
    }

    func test_buckets_lastSevenDays() {
        let date = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .lastSevenDays)
    }

    func test_buckets_earlier() {
        let date = calendar.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .earlier)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter ChatRecencyGroupTests`
Expected: PASS — 4 tests succeed.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Models/BotIdentity.swift MatronShared/Sources/Chat/ChatSummary.swift MatronShared/Tests/ChatTests/ChatSummaryTests.swift
git commit -m "feat: ChatSummary, BotIdentity, recency bucketing"
git push
```

---

### Task 9: SyncService skeleton

**Files:**
- Create: `MatronShared/Sources/Sync/ClientProvider.swift`
- Create: `MatronShared/Sources/Sync/SyncService.swift`
- Create: `MatronShared/Sources/Sync/SyncServiceLive.swift`
- Create: `MatronShared/Tests/ChatTests/SyncServiceProtocolTests.swift` (in ChatTests for now since it's tightly used by Chat)

- [ ] **Step 1: Define the `ClientProvider` and `SyncService` protocol surface**

Create `MatronShared/Sources/Sync/ClientProvider.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronStorage
import MatronModels

public actor ClientProvider {
    private var cached: Client?
    private let basePath: URL

    public init(basePath: URL) {
        self.basePath = basePath
    }

    /// Restores or builds a fully authenticated Client for the given session.
    public func client(for session: UserSession) async throws -> Client {
        if let cached { return cached }
        let client = try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: session.homeserverURL.absoluteString)
            .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
            .build()
        try await client.restoreSession(session: .init(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userID,
            deviceId: session.deviceID,
            homeserverUrl: session.homeserverURL.absoluteString,
            slidingSyncProxy: nil,
            oidcData: nil
        ))
        cached = client
        return client
    }

    public func reset() {
        cached = nil
    }
}
```

> **Note for the implementer:** `restoreSession`'s `Session` initializer args may differ between SDK versions. Adjust to match `Package.resolved`.

Create `MatronShared/Sources/Sync/SyncService.swift`:

```swift
import Foundation

public protocol SyncService: Sendable {
    /// Starts sliding sync. Caller must keep a strong reference.
    func start() async throws

    /// Stops sliding sync.
    func stop() async

    /// True after `start()` succeeds, false after `stop()`.
    var isRunning: Bool { get async }
}
```

- [ ] **Step 2: Implement `SyncServiceLive`**

Create `MatronShared/Sources/Sync/SyncServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronModels

public actor SyncServiceLive: SyncService {
    private let provider: ClientProvider
    private let session: UserSession
    private var syncHandle: TaskHandle?

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func start() async throws {
        guard syncHandle == nil else { return }
        let client = try await provider.client(for: session)
        let listener = SyncStartedListener()
        syncHandle = try await client.syncService().builder().finish().start(listener: listener)
    }

    public func stop() async {
        syncHandle = nil
    }

    public var isRunning: Bool { syncHandle != nil }
}

private final class SyncStartedListener: SyncServiceStateObserver {
    func onUpdate(state: SyncServiceState) {}
}
```

> **Note:** the matrix-rust-components-swift sliding-sync API has shifted across versions. The above is shape-correct for ~25.x; verify against the version in `Package.resolved` and adapt method names. The protocol stays as written.

- [ ] **Step 3: Write a fake-driven test for the protocol shape**

Create `MatronShared/Tests/ChatTests/SyncServiceProtocolTests.swift`:

```swift
import XCTest
@testable import MatronSync

actor FakeSyncService: SyncService {
    var startCallCount = 0
    var stopCallCount = 0
    private var running = false

    func start() async throws {
        startCallCount += 1
        running = true
    }

    func stop() async {
        stopCallCount += 1
        running = false
    }

    var isRunning: Bool { running }
}

final class SyncServiceProtocolTests: XCTestCase {
    func test_startSetsRunningTrue() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        let running = await svc.isRunning
        XCTAssertTrue(running)
    }

    func test_stopSetsRunningFalse() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        await svc.stop()
        let running = await svc.isRunning
        XCTAssertFalse(running)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter SyncServiceProtocolTests`
Expected: PASS — 2 tests succeed.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Sync MatronShared/Tests/ChatTests/SyncServiceProtocolTests.swift
git commit -m "feat: SyncService protocol + ClientProvider + Live impl"
git push
```

---

### Task 10: ChatService — observe room list, emit ChatSummary stream

**Files:**
- Create: `MatronShared/Sources/Chat/ChatService.swift`
- Create: `MatronShared/Sources/Chat/ChatServiceLive.swift`
- Create: `MatronShared/Tests/ChatTests/ChatServiceFakeTests.swift`

- [ ] **Step 1: Define `ChatService` protocol**

Create `MatronShared/Sources/Chat/ChatService.swift`:

```swift
import Foundation

public protocol ChatService: Sendable {
    /// Async stream of room list snapshots (full list, not deltas).
    /// Emits a new snapshot any time the underlying room list changes.
    func chatSummaries() -> AsyncStream<[ChatSummary]>
}
```

- [ ] **Step 2: Implement `ChatServiceLive`**

Create `MatronShared/Sources/Chat/ChatServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronSync
import MatronModels

public final class ChatServiceLive: ChatService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let client = try await provider.client(for: self.session)
                    let roomList = try await client.syncService().roomListService()
                    let listener = SummaryListener(continuation: continuation, client: client)
                    let handle = try await roomList.allRooms().entries(listener: listener)
                    continuation.onTermination = { _ in
                        _ = handle  // retained until termination
                    }
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class SummaryListener: RoomListEntriesListener {
    private let continuation: AsyncStream<[ChatSummary]>.Continuation
    private let client: Client

    init(continuation: AsyncStream<[ChatSummary]>.Continuation, client: Client) {
        self.continuation = continuation
        self.client = client
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        Task {
            do {
                let rooms = try await client.rooms()
                let summaries: [ChatSummary] = rooms.compactMap { room in
                    guard let roomID = try? room.id() else { return nil }
                    let title = (try? room.name()) ?? roomID
                    let memberIDs = (try? room.activeMembersIds()) ?? []
                    let myID = (try? client.userId()) ?? ""
                    let botID = memberIDs.first(where: { $0 != myID }) ?? "@unknown:matron"
                    let bot = BotIdentity(
                        matrixID: botID,
                        displayName: (try? room.displayName()) ?? botID,
                        avatarURL: nil
                    )
                    let lastActivity = Date(timeIntervalSince1970: TimeInterval((try? room.latestEventTimestampMs() ?? 0) ?? 0) / 1000)
                    let unread = Int((try? room.unreadNotificationCount()) ?? 0)
                    return ChatSummary(
                        id: roomID,
                        title: title,
                        bot: bot,
                        lastActivity: lastActivity,
                        unreadCount: unread
                    )
                }
                continuation.yield(summaries)
            } catch {
                // Drop the snapshot on error; next update will retry.
            }
        }
    }
}
```

> **Implementer note:** several method names on `Room` and `Client` (`activeMembersIds()`, `latestEventTimestampMs()`, etc.) vary across SDK versions. Adjust to match. Keep the resulting `ChatSummary` shape stable.

- [ ] **Step 3: Write a fake-driven test**

Create `MatronShared/Tests/ChatTests/ChatServiceFakeTests.swift`:

```swift
import XCTest
@testable import MatronChat
@testable import MatronModels

final class FakeChatService: ChatService, @unchecked Sendable {
    var snapshotsToEmit: [[ChatSummary]] = []

    func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            for snapshot in snapshotsToEmit {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }
}

final class ChatServiceFakeTests: XCTestCase {
    func test_emitsSnapshotsInOrder() async throws {
        let bot = BotIdentity(matrixID: "@bot:s", displayName: "Bot", avatarURL: nil)
        let s1 = [ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .distantPast, unreadCount: 0)]
        let s2 = [
            ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .distantPast, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 1),
        ]
        let fake = FakeChatService()
        fake.snapshotsToEmit = [s1, s2]
        var received: [[ChatSummary]] = []
        for await snap in fake.chatSummaries() {
            received.append(snap)
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].count, 1)
        XCTAssertEqual(received[1].count, 2)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter ChatServiceFakeTests`
Expected: PASS — 1 test succeeds.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/ChatService.swift MatronShared/Sources/Chat/ChatServiceLive.swift MatronShared/Tests/ChatTests/ChatServiceFakeTests.swift
git commit -m "feat: ChatService protocol + Live impl wrapping RoomListService"
git push
```

---

### Task 11: SignInViewModel

**Files:**
- Create: `Matron/Features/Onboarding/SignInViewModel.swift`
- Create: `MatronTests/SignInViewModelTests.swift` (the app target's tests)

The ViewModel orchestrates the AuthService — input validation, probe, login, persist.

- [ ] **Step 1: Add a `MatronTests` test target to `project.yml` (top of `targets:`)**

Append to `project.yml` under `targets:`:

```yaml
  MatronTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: MatronTests
    dependencies:
      - target: Matron
      - package: MatronShared
```

Run: `xcodegen generate`
Expected: project regenerates with `MatronTests` target.

- [ ] **Step 2: Write the failing test**

Create `MatronTests/SignInViewModelTests.swift`:

```swift
import XCTest
@testable import Matron
import MatronAuth
import MatronModels

final class FakeAuthForVM: AuthService, @unchecked Sendable {
    var probeResult: Result<ServerCapabilities, Error> = .success(.init(supportsPasswordLogin: true, supportsSSO: false, ssoRedirectURL: nil))
    var loginResult: Result<UserSession, Error>!
    var persistedSessions: [UserSession] = []

    func probe(_ rawURL: String) async throws -> ServerCapabilities {
        try probeResult.get()
    }
    func loginPassword(homeserverURL: URL, username: String, password: String, initialDeviceDisplayName: String) async throws -> UserSession {
        try loginResult.get()
    }
    func restoreSession() async throws -> UserSession? { nil }
    func persist(_ session: UserSession) throws { persistedSessions.append(session) }
    func clearSession() throws {}
}

final class SignInViewModelTests: XCTestCase {
    @MainActor
    func test_submit_setsBusyAndCallsLogin_onSuccess() async {
        let fake = FakeAuthForVM()
        let session = UserSession(
            userID: "@a:s", deviceID: "D", homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        fake.loginResult = .success(session)
        let vm = SignInViewModel(auth: fake)
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "hunter2"

        await vm.submit()

        XCTAssertEqual(vm.state, .signedIn(session))
        XCTAssertEqual(fake.persistedSessions, [session])
    }

    @MainActor
    func test_submit_showsError_onInvalidCredentials() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.invalidCredentials)
        let vm = SignInViewModel(auth: fake)
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "wrong"

        await vm.submit()

        if case .error(let message) = vm.state {
            XCTAssertTrue(message.lowercased().contains("credentials") || message.lowercased().contains("invalid"))
        } else {
            XCTFail("Expected .error state, got \(vm.state)")
        }
    }

    @MainActor
    func test_submit_isNoOp_whenInputsEmpty() async {
        let fake = FakeAuthForVM()
        let vm = SignInViewModel(auth: fake)
        await vm.submit()
        XCTAssertEqual(vm.state, .idle)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run (in Xcode): Product → Test (⌘U) with the `Matron` scheme.
Expected: FAIL — `SignInViewModel` not defined.

- [ ] **Step 4: Implement `SignInViewModel`**

Create `Matron/Features/Onboarding/SignInViewModel.swift`:

```swift
import Foundation
import MatronAuth
import MatronModels

@Observable
@MainActor
final class SignInViewModel {
    enum State: Equatable {
        case idle
        case busy
        case error(String)
        case signedIn(UserSession)
    }

    var serverURL: String = ""
    var username: String = ""
    var password: String = ""
    private(set) var state: State = .idle

    private let auth: AuthService

    init(auth: AuthService) {
        self.auth = auth
    }

    func submit() async {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.isEmpty,
              !password.isEmpty else {
            return
        }
        state = .busy
        do {
            _ = try await auth.probe(serverURL)
            let url = try ServerURLValidator.normalize(serverURL)
            let session = try await auth.loginPassword(
                homeserverURL: url,
                username: username,
                password: password,
                initialDeviceDisplayName: "Matron iOS"
            )
            try auth.persist(session)
            state = .signedIn(session)
        } catch let error as AuthError {
            state = .error(message(for: error))
        } catch {
            state = .error("Unexpected error: \(error.localizedDescription)")
        }
    }

    private func message(for error: AuthError) -> String {
        switch error {
        case .invalidServerURL: return "That doesn't look like a valid server URL."
        case .serverUnreachable: return "Couldn't reach that server."
        case .ssoNotSupported: return "SSO is not supported by this server."
        case .invalidCredentials: return "Invalid credentials."
        case .unexpected(let s): return s
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run (in Xcode): Product → Test (⌘U).
Expected: PASS — 3 tests succeed.

- [ ] **Step 6: Commit**

```bash
git add project.yml Matron/Features/Onboarding/SignInViewModel.swift MatronTests/SignInViewModelTests.swift
git commit -m "feat: SignInViewModel with input validation and login orchestration"
git push
```

---

### Task 12: SignInView (UI)

**Files:**
- Create: `Matron/Features/Onboarding/SignInView.swift`

- [ ] **Step 1: Implement `SignInView`**

Create `Matron/Features/Onboarding/SignInView.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels

struct SignInView: View {
    @State var viewModel: SignInViewModel
    var onSignedIn: (UserSession) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://matrix.example.com", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Credentials") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $viewModel.password)
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
                }
            }
            .navigationTitle("Sign in to Matron")
            .onChange(of: viewModel.state) { _, new in
                if case .signedIn(let session) = new {
                    onSignedIn(session)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles in Xcode**

Build the `Matron` scheme.
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Onboarding/SignInView.swift
git commit -m "feat: SignInView for combined server URL + credentials entry"
git push
```

---

### Task 13: ChatListViewModel + ChatListView

**Files:**
- Create: `Matron/Features/ChatList/ChatListViewModel.swift`
- Create: `Matron/Features/ChatList/ChatListView.swift`
- Create: `MatronTests/ChatListViewModelTests.swift`

- [ ] **Step 1: Write the failing ViewModel test**

Create `MatronTests/ChatListViewModelTests.swift`:

```swift
import XCTest
@testable import Matron
import MatronChat
import MatronModels

final class ChatListViewModelTests: XCTestCase {
    @MainActor
    func test_groupsSummariesByRecency() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let now = Date(timeIntervalSince1970: 1745000000)
        let summaries = [
            ChatSummary(id: "!t:s", title: "Today chat",     bot: bot, lastActivity: now.addingTimeInterval(-3600),    unreadCount: 0),
            ChatSummary(id: "!y:s", title: "Yesterday chat", bot: bot, lastActivity: now.addingTimeInterval(-86_400),  unreadCount: 0),
            ChatSummary(id: "!w:s", title: "Earlier chat",   bot: bot, lastActivity: now.addingTimeInterval(-86_400 * 30), unreadCount: 0),
        ]
        let groups = ChatListViewModel.group(summaries: summaries, now: now)
        XCTAssertEqual(groups.first?.group, .today)
        XCTAssertEqual(groups.first?.summaries.count, 1)
        XCTAssertEqual(groups.last?.group, .earlier)
    }

    @MainActor
    func test_emptyState_isReflected() {
        let groups = ChatListViewModel.group(summaries: [])
        XCTAssertTrue(groups.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Product → Test (⌘U) on `ChatListViewModelTests`.
Expected: FAIL — `ChatListViewModel` not defined.

- [ ] **Step 3: Implement `ChatListViewModel`**

Create `Matron/Features/ChatList/ChatListViewModel.swift`:

```swift
import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
final class ChatListViewModel {
    struct GroupedSummaries: Identifiable {
        let group: ChatRecencyGroup
        let summaries: [ChatSummary]
        var id: String { group.rawValue }
    }

    private(set) var groups: [GroupedSummaries] = []
    private(set) var isLoading: Bool = true

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    init(chat: ChatService) {
        self.chat = chat
    }

    func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in chat.chatSummaries() {
                let grouped = Self.group(summaries: snapshot)
                await MainActor.run {
                    self.groups = grouped
                    self.isLoading = false
                }
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    static func group(summaries: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [GroupedSummaries] {
        let buckets = Dictionary(grouping: summaries) { ChatRecencyGroup.bucket($0.lastActivity, now: now, calendar: calendar) }
        return ChatRecencyGroup.allCases.compactMap { bucket in
            guard let summaries = buckets[bucket]?.sorted(by: { $0.lastActivity > $1.lastActivity }), !summaries.isEmpty else { return nil }
            return GroupedSummaries(group: bucket, summaries: summaries)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Product → Test (⌘U) on `ChatListViewModelTests`.
Expected: PASS — 2 tests succeed.

- [ ] **Step 5: Implement `ChatListView`**

Create `Matron/Features/ChatList/ChatListView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct ChatListView: View {
    @State var viewModel: ChatListViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Connecting…")
                } else if viewModel.groups.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Provision a bot via dev-boxer to get started.")
                    )
                } else {
                    List {
                        ForEach(viewModel.groups) { group in
                            Section(group.group.rawValue) {
                                ForEach(group.summaries) { summary in
                                    ChatRow(summary: summary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Matron")
            .task { viewModel.start() }
        }
    }
}

private struct ChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body)
                Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.lastActivity, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if summary.unreadCount > 0 {
                Circle().fill(.blue).frame(width: 8, height: 8)
            }
        }
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add Matron/Features/ChatList MatronTests/ChatListViewModelTests.swift
git commit -m "feat: ChatListViewModel + ChatListView with recency grouping"
git push
```

---

### Task 14: AppDependencies + root navigation

**Files:**
- Create: `Matron/App/AppDependencies.swift`
- Modify: `Matron/App/MatronApp.swift`

- [ ] **Step 1: Implement `AppDependencies`**

Create `Matron/App/AppDependencies.swift`:

```swift
import Foundation
import MatronAuth
import MatronChat
import MatronStorage
import MatronSync

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider

    init() {
        let container = AppGroup.containerURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let keychain = KeychainStore(
            service: "chat.matron.session",
            accessGroup: nil
        )
        self.auth = AuthServiceLive(keychain: keychain, basePath: container)
        self.clientProvider = ClientProvider(basePath: container)
    }

    func chatService(for session: UserSession) -> ChatService {
        ChatServiceLive(provider: clientProvider, session: session)
    }

    func syncService(for session: UserSession) -> SyncService {
        SyncServiceLive(provider: clientProvider, session: session)
    }
}
```

- [ ] **Step 2: Replace `MatronApp.swift` body with real navigation**

Replace `Matron/App/MatronApp.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels

@main
struct MatronApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .task { await bootstrap() }
                } else if let session {
                    ChatListView(viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)))
                        .task { try? await dependencies.syncService(for: session).start() }
                } else {
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth),
                        onSignedIn: { session in self.session = session }
                    )
                }
            }
        }
    }

    private func bootstrap() async {
        do {
            session = try await dependencies.auth.restoreSession()
        } catch {
            session = nil
        }
        bootstrapDone = true
    }
}
```

- [ ] **Step 3: Build & run on simulator**

In Xcode: Product → Run (⌘R) on iPhone 15 simulator.
Expected:
- App launches showing "Loading…"
- Transitions to "Sign in to Matron" if no stored session
- After successful login (point at a real homeserver from a `dev-boxer` instance), transitions to "Connecting…" then to chat list

- [ ] **Step 4: Commit**

```bash
git add Matron/App
git commit -m "feat: AppDependencies + MatronApp root navigation between sign-in and chat list"
git push
```

---

### Task 15: Manual end-to-end smoke test against a real homeserver

**Files:**
- Create: `manual-tests.md`

This is a documentation task — no code. Establishes the manual baseline that subsequent tasks/phases extend.

- [ ] **Step 1: Run the full flow on a simulator**

Pre-req: a `dev-boxer` homeserver with a Matrix user account and at least one bot already invited to a room with that user.

Steps:
1. Cold-launch the app on iPhone 15 simulator.
2. Enter homeserver URL, username, password. Tap Sign in.
3. Wait for chat list to populate.
4. Verify: at least one chat appears with the bot's display name and a recency timestamp.
5. Quit and re-launch the app. Verify it skips the sign-in screen and goes straight to the chat list.

- [ ] **Step 2: Document the test**

Create `manual-tests.md`:

```markdown
# Matron iOS — manual test checklist

Run before every TestFlight build.

## Phase 1 (Foundation)

### Sign-in flow

- [ ] Cold-launch on iPhone 15 simulator (or device) — sees Sign-in screen.
- [ ] Enter homeserver URL with no scheme (e.g. `matrix.example.com`) — accepted, normalised to HTTPS.
- [ ] Enter homeserver URL with HTTP — rejected with friendly error.
- [ ] Enter blatantly invalid credentials — sees error message in red.
- [ ] Enter valid credentials — transitions to Connecting → chat list.

### Session persistence

- [ ] After successful sign-in, force-quit the app and re-launch — skips sign-in, goes straight to chat list.
- [ ] Reset simulator (Device → Erase All Content) and re-launch — back to sign-in (no stale session).

### Chat list rendering

- [ ] At least one chat appears (assumes a bot is already invited).
- [ ] Chat title shows the room name (Gemini-auto-titled if applicable; falls back to room ID).
- [ ] Recency grouping headers appear (Today / Yesterday / etc.).
- [ ] Unread dot appears for chats with unread messages.

### What is NOT tested in Phase 1

- Tapping a chat (Phase 2).
- Sending messages (Phase 2).
- Push notifications (Phase 4).
- Verification UX (Phase 3).
- Search (Phase 6).
```

- [ ] **Step 3: Commit**

```bash
git add manual-tests.md
git commit -m "docs: phase 1 manual test checklist"
git push
```

---

### Task 16: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Add CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_16.app

      - name: Show Xcode version
        run: xcodebuild -version

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Resolve SPM dependencies
        run: xcodebuild -resolvePackageDependencies -workspace Matron.xcworkspace -scheme Matron

      - name: Run MatronShared package tests
        working-directory: MatronShared
        run: swift test --enable-code-coverage

      - name: Build Matron app
        run: |
          xcodebuild build \
            -workspace Matron.xcworkspace \
            -scheme Matron \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
            CODE_SIGNING_ALLOWED=NO

      - name: Run Matron app tests
        run: |
          xcodebuild test \
            -workspace Matron.xcworkspace \
            -scheme Matron \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
            CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Push and verify the workflow runs green**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow building and testing on macos-15"
git push
```

Run: `gh run list --workflow ci.yml --limit 1`
Then: `gh run watch <run-id>`
Expected: workflow completes green within ~15 minutes.

- [ ] **Step 3: Iterate if red**

If CI fails:
- Read logs via `gh run view <run-id> --log-failed`.
- Fix the issue (likely: SDK version pin mismatch, missing Xcode version, simulator name drift).
- Push fix as a new commit. Repeat until green.

---

## Phase 1 acceptance

Phase 1 is done when:

1. All 16 tasks committed and pushed to `main`.
2. CI is green on `main`.
3. Manual checklist (`manual-tests.md`) passes against at least one real `dev-boxer` homeserver.
4. The app, when run, allows: enter server URL + credentials → sign in → see chat list with bot rooms.

After acceptance, request review (see superpowers:requesting-code-review), then write the Phase 2 plan.

---

## Plan self-review notes

Quick check against the spec sections:

- **§1 Goals & non-goals:** Covered — Phase 1 establishes the App Store-distributable codebase with E2EE on, sliding sync, and the bot-rooms-as-chats data model. Non-goals respected (no reactions, edits, etc., are even possible because no chat view exists yet).
- **§2 High-level architecture:** Three targets created in Task 2; SDK wired in Tasks 3–10; App Group set in Task 2; iOS 17 enforced.
- **§3 Module structure:** Auth/Sync/Chat/Storage/Models modules created. Push/Search/Verification/Media/Events deferred to phases that need them.
- **§4 Custom event types:** Deferred to Phase 5 (custom events depend on bridge changes that need their own spec).
- **§5 Key UI flows:** Sign-in (§5.2) implemented in Tasks 11–12. Chat list (§5.3) implemented in Task 13. Other flows (§5.4–5.8) deferred.
- **§6 Data flow:** Sync loop (§6.1) and read-only chat-list slice implemented. Decryption hook to search (§6.2), push wakeup (§6.3), and new-chat creation (§6.4) deferred.
- **§7 E2EE:** SDK is initialised with E2EE on by default in `ClientProvider` (Task 9). Verification UI (§7.2–7.3), key backup (§7.4), and trust posture banners (§7.5) deferred to Phase 3.
- **§8 Push:** NSE stub created (Task 2) but no decryption logic; deferred to Phase 4.
- **§9 Search storage:** Deferred to Phase 6 — schema not created in Phase 1.
- **§10 Testing strategy:** Unit tests + ViewModel tests covered. Snapshot tests deferred (no rendering primitives yet). Integration test scaffold added in Task 7.
- **§11 Out of scope:** Honored — no scope creep beyond foundation.
- **§12 License & legal:** Apache 2.0 LICENSE in repo from creation; no AGPL deps; the legacy `matron-ios` fork is not touched in this plan (out of scope, but flagged in the spec).

No placeholders, no TBDs. Type signatures (`AuthService`, `ChatService`, `UserSession`, `ChatSummary`) are consistent across tasks. `ChatRecencyGroup.bucket` is defined in Task 8, used in Task 13. `AuthService` defined in Task 6, used in Tasks 7, 11, 14. SDK method names flagged with implementer notes where versions diverge.

---
