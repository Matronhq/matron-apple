# Matron iOS — Phase 3 (E2EE & Verification UX) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 2 (Chat experience) merged and CI green.

**Goal:** Wire the encryption UX on **both iOS and macOS**. After Phase 3, users on either platform can: (a) generate + save a recovery key on first device, (b) verify a new device via SAS with another device, (c) verify each bot via SAS, (d) restore from recovery key on a fresh install. Banners surface verification state and link into the right flow. iCloud Keychain auto-syncs the recovery key from iOS to Mac (and vice versa) so a Mac install can pull existing keys without re-entry when iCloud Keychain is enabled (spec §7.1, §7.2 Scenario A).

**Architecture:** New `VerificationService` in `MatronShared` wraps the SDK's verification machinery. ViewModels (`SasViewModel`, `RecoveryKeyViewModel`) live in `MatronShared/Sources/ViewModels/` and are imported by both apps. UI flows live in `Matron/Features/Verification/` (iOS, half-sheet + `NavigationStack` chrome) and `MatronMac/Features/Verification/` (Mac, fixed-size sheets + `NSPasteboard` integration + Help menu wire-up). Two screens per platform: `RecoveryKeyView` / `MacRecoveryKeyView` (show/save/restore) and `SasView` / `MacSasView` (emoji compare). Banners are SwiftUI overlays driven by a top-level `VerificationCenter` shared by both apps. Trust posture from spec §7.5: nothing auto-trusted. The `SessionVerificationControlling` protocol seam (Task 4) is shared — both iOS and Mac use the same `LiveSessionVerificationController` from `MatronShared`; the SDK Client API is identical on both platforms.

**Tech Stack:** Same as Phase 2. No new third-party deps — matrix-rust-sdk-swift exposes the verification primitives natively.

**Reference:** Spec §7 (E2EE), §5.7 (verification banner UX), §5.9 (Mac chrome — Help menu, fixed-size sheets), §7.1 (Mac crypto store + iCloud Keychain auto-sync).

---

## File structure (Phase 3 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Verification/
│   ├── VerificationService.swift                       NEW
│   ├── VerificationServiceLive.swift                   NEW
│   ├── VerificationDTOs.swift                          NEW — DTOs (DeviceInfo, SasFlowState, SasEmoji, VerificationRequestSummary)
│   ├── SessionVerificationControlling.swift            NEW — protocol seam over MatrixRustSDK.SessionVerificationController
│   ├── RecoveryKeyManager.swift                        NEW — generate/store/restore
│   └── DeviceVerificationRequestObserver.swift         NEW — adapts SDK callbacks into IncomingVerificationListener events
├── MatronShared/Tests/VerificationTests/
│   ├── FakeSessionVerificationController.swift         NEW — test fake for the controller protocol
│   ├── VerificationServiceFakeTests.swift              NEW
│   ├── VerificationServiceLiveTests.swift              NEW — exercises live impl against the fake controller
│   └── DeviceVerificationRequestObserverTests.swift    NEW
├── MatronShared/Sources/ViewModels/
│   ├── RecoveryKeyViewModel.swift                      NEW — shared by iOS + Mac
│   └── SasViewModel.swift                              NEW — shared by iOS + Mac
├── Matron/Features/Verification/
│   ├── RecoveryKeyView.swift                           NEW — iOS view (UIPasteboard + half-sheet chrome)
│   ├── SasView.swift                                   NEW — iOS view
│   ├── VerificationBanner.swift                        NEW — iOS top-of-list overlay
│   └── VerificationCenter.swift                        NEW — orchestrates incoming requests, cancels on dismiss (used by both apps)
├── Matron/Features/Onboarding/
│   └── PostLoginVerificationView.swift                 NEW — second onboarding step
├── Matron/Features/Settings/
│   └── DeviceSettingsView.swift                        NEW — minimal device info + recovery reveal
├── MatronMac/Features/Verification/
│   ├── MacSasView.swift                                NEW — fixed-size Mac sheet (480×400), keyboard shortcuts
│   ├── MacRecoveryKeyView.swift                        NEW — three phases (show / re-enter / confirmed); NSPasteboard
│   ├── MacVerificationBanner.swift                     NEW — top-of-window banner above the chat list
│   └── NSPasteboardWrapper.swift                       NEW — protocol seam for paste detection (live + fake)
├── MatronMac/App/
│   └── MatronMacCommands.swift                         MODIFY — wire Help menu placeholders ("Verify This Device…", "Show Recovery Key…") to NotificationCenter posts
├── MatronTests/
│   ├── RecoveryKeyViewModelTests.swift                 NEW
│   ├── SasViewModelTests.swift                         NEW
│   └── VerificationCenterTests.swift                   NEW
├── MatronMacTests/
│   ├── MacRecoveryKeyViewTests.swift                   NEW — paste-detection test against fake NSPasteboard
│   └── MacVerificationBannerSnapshotTests.swift        NEW — Mac snapshot variants
```

---

## Tasks

### Task 1: Verification DTOs

**Files:**
- Create: `MatronShared/Sources/Verification/VerificationDTOs.swift`

> **Why this name:** the matrix-rust-sdk-swift module exposes a `VerificationState` enum of its own. Naming our file `VerificationState.swift` causes a confusing collision. None of our DTOs are actually called `VerificationState` — they're `SasFlowState`, `SasEmoji`, `DeviceInfo`, `VerificationRequestSummary` — so the file name is just `VerificationDTOs.swift`.

- [ ] **Step 1: Define the DTOs**

```swift
import Foundation

public enum DeviceTrustLevel: Equatable, Sendable {
    case verified
    case unverified
    case blacklisted
}

public struct DeviceInfo: Equatable, Identifiable, Sendable {
    public let id: String                  // device ID
    public let userID: String
    public let displayName: String?
    public let trust: DeviceTrustLevel
    public let lastSeenAt: Date?

    public init(id: String, userID: String, displayName: String?, trust: DeviceTrustLevel, lastSeenAt: Date?) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.trust = trust
        self.lastSeenAt = lastSeenAt
    }
}

public enum SasFlowState: Equatable, Sendable {
    case idle
    case requested
    case readyForEmoji([SasEmoji])
    case awaitingConfirmation
    case verified
    case cancelled(reason: String)
}

public struct SasEmoji: Equatable, Sendable {
    public let symbol: String              // 🐢
    public let description: String         // "Turtle"
    public init(symbol: String, description: String) {
        self.symbol = symbol
        self.description = description
    }
}

public struct VerificationRequestSummary: Equatable, Identifiable, Sendable {
    public let id: String                  // unique request id
    public let otherUserID: String
    public let otherDeviceID: String?
    public let createdAt: Date

    public init(id: String, otherUserID: String, otherDeviceID: String?, createdAt: Date) {
        self.id = id
        self.otherUserID = otherUserID
        self.otherDeviceID = otherDeviceID
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MatronShared/Sources/Verification/VerificationDTOs.swift
git commit -m "feat: Verification DTOs (DeviceInfo, SasFlowState, SasEmoji, RequestSummary)"
git push
```

---

### Task 2: VerificationService protocol

**Files:**
- Create: `MatronShared/Sources/Verification/VerificationService.swift`
- Create: `MatronShared/Tests/VerificationTests/VerificationServiceFakeTests.swift`

- [ ] **Step 1: Define the protocol**

```swift
import Foundation

public protocol VerificationService: Sendable {
    /// True if this device's signing keys are present and signed.
    func isThisDeviceVerified() async throws -> Bool

    /// Emits incoming verification requests (from other devices or bots).
    func incomingRequests() -> AsyncStream<VerificationRequestSummary>

    /// Starts a SAS verification with `userID`/`deviceID`.
    /// Returned stream emits state transitions until terminal state.
    func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState>

    /// Accepts an incoming verification request and starts SAS.
    func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState>

    /// User confirms emoji match.
    func confirmEmojiMatch(requestID: String) async throws

    /// User cancels the flow.
    func cancel(requestID: String, reason: String) async throws
}
```

- [ ] **Step 2: Fake-backed tests (protocol shape only)**

```swift
import XCTest
@testable import MatronAuth // assuming Verification lives in MatronAuth product; adjust to MatronVerification if you split

actor FakeVerificationService: VerificationService {
    var didCallStart: [(String, String?)] = []
    var didConfirm: [String] = []
    var nextStream: AsyncStream<SasFlowState>?

    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { $0.finish() }
    }

    nonisolated func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        Task { await self.recordStart(userID, deviceID) }
        let states: [SasFlowState] = [
            .requested,
            .readyForEmoji([SasEmoji(symbol: "🐢", description: "Turtle")]),
            .verified
        ]
        return AsyncStream { c in
            for s in states { c.yield(s) }
            c.finish()
        }
    }

    func recordStart(_ u: String, _ d: String?) { didCallStart.append((u, d)) }

    nonisolated func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }

    func confirmEmojiMatch(requestID: String) async throws { didConfirm.append(requestID) }
    func cancel(requestID: String, reason: String) async throws {}
    func isThisDeviceVerified() async throws -> Bool { true }
}

final class VerificationServiceFakeTests: XCTestCase {
    func test_startSAS_yieldsTransitions() async throws {
        let svc = FakeVerificationService()
        var collected: [SasFlowState] = []
        for await state in svc.startSAS(withUser: "@a:s", deviceID: "DEV1") {
            collected.append(state)
        }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected.last, .verified)
    }
}
```

- [ ] **Step 3: Add a `MatronVerification` library product**

In `MatronShared/Package.swift`:

```swift
.library(name: "MatronVerification", targets: ["MatronVerification"]),
.target(
    name: "MatronVerification",
    dependencies: [
        "MatronModels",
        "MatronStorage",
        "MatronSync",
        .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
    ],
    path: "Sources/Verification"
),
```

(Move the protocol + DTOs into the new `MatronVerification` target by adjusting the `path:`. Tests live under `Tests/VerificationTests/`.)

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Verification/ MatronShared/Tests/VerificationTests/ MatronShared/Package.swift
git commit -m "feat: VerificationService protocol with SAS flow stream"
git push
```

---

### Task 3: RecoveryKeyManager

**Files:**
- Create: `MatronShared/Sources/Verification/RecoveryKeyManager.swift`

The recovery key is a string the SDK generates. We persist it in iCloud Keychain so reinstalls can restore.

- [ ] **Step 1: Implement**

```swift
import Foundation
import MatrixRustSDK
import MatronStorage
import MatronModels
import MatronSync

public final class RecoveryKeyManager: @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let keychain: KeychainStore
    private let recoveryKeyKey = "matron.recovery-key"

    public init(provider: ClientProvider, session: UserSession, keychain: KeychainStore) {
        self.provider = provider
        self.session = session
        self.keychain = keychain
    }

    /// First-device path: enables key backup with a newly generated recovery key, returns the plaintext.
    /// MUST be shown to the user once. Persists to iCloud Keychain (`kSecAttrSynchronizable: true`).
    public func generateAndPersist() async throws -> String {
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        let key = try await encryption.enableRecovery(waitForBackupsToUpload: false, progressListener: nil)
        // Persist for restore on reinstall.
        try keychain.set(key, forKey: recoveryKeyKey)
        return key
    }

    /// Additional-device / restore path: feed the user's recovery key to unlock backup + cross-signing.
    public func restore(usingKey key: String) async throws {
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        try await encryption.recover(recoveryKey: key)
        try keychain.set(key, forKey: recoveryKeyKey)
    }

    /// For "show recovery key again" in Settings.
    public func currentKey() throws -> String? {
        try keychain.get(key: recoveryKeyKey)
    }
}
```

> **Implementer notes:** `enableRecovery` / `recover` exist in matrix-rust-components-swift but argument names vary. Check `Package.resolved`. iCloud sync is enabled by passing the right `kSecAttrSynchronizable` to `KeychainStore`'s underlying SecItem dict — we'll extend `KeychainStore` to accept a `synchronizable: Bool` initializer in Step 2.

- [ ] **Step 2: Extend `KeychainStore` to support iCloud-sync**

In `KeychainStore.swift`, add an optional `synchronizable` init param and propagate it through `baseQuery`:

```swift
private let synchronizable: Bool

public init(service: String, accessGroup: String? = nil, synchronizable: Bool = false) {
    self.service = service
    self.accessGroup = accessGroup
    self.synchronizable = synchronizable
}

private func baseQuery(for key: String) -> [String: Any] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
    ]
    if synchronizable {
        query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
    }
    if let accessGroup {
        query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
}
```

- [ ] **Step 3: Tests**

Add to `KeychainStoreTests`:

```swift
func test_synchronizableInstance_writesIndependently() throws {
    let local = KeychainStore(service: "chat.matron.test", synchronizable: false)
    let icloud = KeychainStore(service: "chat.matron.test", synchronizable: true)
    try local.set("local", forKey: "k")
    try icloud.set("cloud", forKey: "k")
    XCTAssertEqual(try local.get(key: "k"), "local")
    XCTAssertEqual(try icloud.get(key: "k"), "cloud")
    try? local.delete(key: "k"); try? icloud.delete(key: "k")
}
```

- [ ] **Step 4: Commit**

```bash
cd MatronShared && swift test --filter KeychainStoreTests
git add MatronShared/Sources/Verification/RecoveryKeyManager.swift \
        MatronShared/Sources/Storage/KeychainStore.swift \
        MatronShared/Tests/StorageTests/KeychainStoreTests.swift
git commit -m "feat: RecoveryKeyManager + iCloud-syncable KeychainStore"
git push
```

---

### Task 4: VerificationServiceLive — wrap the SDK

**Files:**
- Create: `MatronShared/Sources/Verification/VerificationServiceLive.swift`

- [ ] **Step 1: Failing tests against a `FakeSessionVerificationController`**

The unit tests must exercise the live impl's flow logic against an in-memory fake controller, not the real SDK. Define a small protocol the live impl depends on, then provide both a fake (for tests) and a thin adapter that bridges to `MatrixRustSDK.SessionVerificationController` (for production).

```swift
// MatronShared/Sources/Verification/SessionVerificationControlling.swift
import Foundation

/// Protocol abstraction over `MatrixRustSDK.SessionVerificationController`.
/// Lets us unit-test VerificationServiceLive without spinning up a live SDK client.
public protocol SessionVerificationControlling: AnyObject, Sendable {
    func acceptVerificationRequest() async throws
    func startSasVerification() async throws
    func approveVerification() async throws
    func declineVerification() async throws
    func cancelVerification() async throws
}
```

```swift
// MatronShared/Tests/VerificationTests/FakeSessionVerificationController.swift
final class FakeSessionVerificationController: SessionVerificationControlling, @unchecked Sendable {
    var didAccept = false
    var didStartSas = false
    var didApprove = false
    var didCancel = false
    var didDecline = false

    func acceptVerificationRequest() async throws { didAccept = true }
    func startSasVerification()      async throws { didStartSas = true }
    func approveVerification()       async throws { didApprove = true }
    func declineVerification()       async throws { didDecline = true }
    func cancelVerification()        async throws { didCancel = true }
}
```

Add failing tests asserting:
- `acceptIncoming(requestID:)` calls `acceptVerificationRequest()` then `startSasVerification()` on the matching cached controller.
- `confirmEmojiMatch(requestID:)` calls `approveVerification()` on the cached controller and yields `.verified` after the callback fires.
- `cancel(requestID:, reason:)` calls `cancelVerification()`, removes the entry from `activeFlows`, and yields `.cancelled(reason: reason)` with the supplied reason propagated verbatim.
- An unknown `requestID` produces `.cancelled` (or throws) instead of silently no-op'ing.

- [ ] **Step 2: Implement**

```swift
import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

public final class VerificationServiceLive: VerificationService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    /// Cache of in-flight verification controllers, keyed by request ID.
    /// Populated when `IncomingVerificationListener.onUpdate` fires with a new request,
    /// drained on cancel / verified / declined.
    private var activeFlows: [String: SessionVerificationControlling] = [:]
    /// Per-request continuations so accept / confirm / cancel can yield into the
    /// same stream the UI is observing.
    private var activeContinuations: [String: AsyncStream<SasFlowState>.Continuation] = [:]
    private let lock = NSLock()

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func isThisDeviceVerified() async throws -> Bool {
        let client = try await provider.client(for: session)
        return try await client.encryption().isVerified()
    }

    public func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try await provider.client(for: session)
                    let listener = IncomingVerificationListener(
                        continuation: continuation,
                        onController: { [weak self] requestID, controller in
                            self?.register(controller: controller, for: requestID)
                        }
                    )
                    let _ = try await client.encryption().verificationStateListener(listener: listener)
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try await provider.client(for: session)
                    let request = try await client.encryption().requestSelfVerification()  // adjust per SDK API
                    let listener = SasFlowListener(continuation: continuation)
                    let _ = try await request.startSasVerification(listener: listener)
                } catch {
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { continuation in
            self.setContinuation(continuation, for: requestID)
            let task = Task { [weak self] in
                guard let self else { return }
                guard let controller = self.controller(for: requestID) else {
                    continuation.yield(.cancelled(reason: "Unknown request: \(requestID)"))
                    continuation.finish()
                    return
                }
                do {
                    try await controller.acceptVerificationRequest()
                    continuation.yield(.requested)
                    try await controller.startSasVerification()
                    // Emoji-state updates arrive via the SDK delegate (`SasFlowListener`),
                    // which yields `.readyForEmoji([...])` / `.awaitingConfirmation` into
                    // this same continuation.
                } catch {
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.clearContinuation(for: requestID)
            }
        }
    }

    public func confirmEmojiMatch(requestID: String) async throws {
        // Implementer note: API name varies — verify against SDK version Phase 1 pinned.
        // matrix-rust-sdk-swift currently exposes `approveVerification()`; older builds used
        // `confirmVerification()` / `confirm()`. If the symbol is missing, name the SDK
        // module qualifier explicitly: `MatrixRustSDK.SessionVerificationController`.
        guard let controller = controller(for: requestID) else {
            throw VerificationError.unknownRequest(requestID)
        }
        try await controller.approveVerification()
        if let continuation = continuation(for: requestID) {
            continuation.yield(.verified)
            continuation.finish()
        }
        clearController(for: requestID)
    }

    public func cancel(requestID: String, reason: String) async throws {
        guard let controller = controller(for: requestID) else {
            // Nothing to cancel — emit terminal state if a stream is waiting and exit.
            if let continuation = continuation(for: requestID) {
                continuation.yield(.cancelled(reason: reason))
                continuation.finish()
            }
            clearContinuation(for: requestID)
            return
        }
        try await controller.cancelVerification()
        if let continuation = continuation(for: requestID) {
            continuation.yield(.cancelled(reason: reason))
            continuation.finish()
        }
        clearController(for: requestID)
    }

    // MARK: - activeFlows bookkeeping (NSLock-guarded)

    func register(controller: SessionVerificationControlling, for requestID: String) {
        lock.lock(); defer { lock.unlock() }
        activeFlows[requestID] = controller
    }

    private func controller(for requestID: String) -> SessionVerificationControlling? {
        lock.lock(); defer { lock.unlock() }
        return activeFlows[requestID]
    }

    private func clearController(for requestID: String) {
        lock.lock(); defer { lock.unlock() }
        activeFlows.removeValue(forKey: requestID)
        activeContinuations.removeValue(forKey: requestID)
    }

    private func setContinuation(_ c: AsyncStream<SasFlowState>.Continuation, for requestID: String) {
        lock.lock(); defer { lock.unlock() }
        activeContinuations[requestID] = c
    }

    private func continuation(for requestID: String) -> AsyncStream<SasFlowState>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        return activeContinuations[requestID]
    }

    private func clearContinuation(for requestID: String) {
        lock.lock(); defer { lock.unlock() }
        activeContinuations.removeValue(forKey: requestID)
    }
}

public enum VerificationError: Error, Equatable {
    case unknownRequest(String)
}

/// Production adapter — bridges our protocol to the real SDK type.
/// Implementer note: API name varies — verify against SDK version Phase 1 pinned.
final class LiveSessionVerificationController: SessionVerificationControlling, @unchecked Sendable {
    private let inner: MatrixRustSDK.SessionVerificationController
    init(_ inner: MatrixRustSDK.SessionVerificationController) { self.inner = inner }

    func acceptVerificationRequest() async throws { try await inner.acceptVerificationRequest() }
    func startSasVerification()      async throws { try await inner.startSasVerification() }
    func approveVerification()       async throws { try await inner.approveVerification() }
    func declineVerification()       async throws { try await inner.declineVerification() }
    func cancelVerification()        async throws { try await inner.cancelVerification() }
}

private final class IncomingVerificationListener: VerificationStateListener {
    let continuation: AsyncStream<VerificationRequestSummary>.Continuation
    let onController: (String, SessionVerificationControlling) -> Void
    init(
        continuation: AsyncStream<VerificationRequestSummary>.Continuation,
        onController: @escaping (String, SessionVerificationControlling) -> Void
    ) {
        self.continuation = continuation
        self.onController = onController
    }
    /// SDK delegate callback. `MatrixRustSDK.VerificationState` (the SDK enum) is qualified
    /// here to avoid colliding with anything our own module defines.
    func onUpdate(sdkState: MatrixRustSDK.VerificationState) {
        // When the SDK reports a new pending request, extract its request ID and the
        // associated SessionVerificationController, register the controller in
        // VerificationServiceLive.activeFlows via `onController`, then yield a summary.
        // Adjust the case match per SDK version Phase 1 pinned.
    }
}

private final class SasFlowListener: SasListener {
    let continuation: AsyncStream<SasFlowState>.Continuation
    init(continuation: AsyncStream<SasFlowState>.Continuation) {
        self.continuation = continuation
    }
    func onChange(state: SasState) {
        // Translate SDK SasState → our SasFlowState. Cases: started → .requested,
        // shortAuthString → .readyForEmoji, confirmed → .awaitingConfirmation,
        // done → .verified, cancelled → .cancelled.
    }
}
```

> **Implementer notes:** the verification API in matrix-rust-components-swift has been one of the more volatile surfaces. Expect to spend an afternoon mapping methods. The protocol shape is what matters — it isolates the SDK churn from the UI. The `SessionVerificationControlling` indirection means tests run against `FakeSessionVerificationController` while production uses `LiveSessionVerificationController` over the real `MatrixRustSDK.SessionVerificationController`.

- [ ] **Step 3: Verify tests pass against the fake**

```bash
cd MatronShared && swift test --filter VerificationServiceLiveTests
```

Confirms `acceptIncoming` / `confirmEmojiMatch` / `cancel` all do the right thing without touching the SDK; cancel reason is propagated verbatim through the stream.

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Verification/VerificationServiceLive.swift \
        MatronShared/Sources/Verification/SessionVerificationControlling.swift \
        MatronShared/Tests/VerificationTests/FakeSessionVerificationController.swift \
        MatronShared/Tests/VerificationTests/VerificationServiceLiveTests.swift
git commit -m "feat: VerificationServiceLive wraps SDK SAS flows with cached active flows"
git push
```

---

### Task 4b: DeviceVerificationRequestObserver

**Files:**
- Create: `MatronShared/Sources/Verification/DeviceVerificationRequestObserver.swift`
- Create: `MatronShared/Tests/VerificationTests/DeviceVerificationRequestObserverTests.swift`

The observer is the entry point that receives raw SDK callbacks and forwards them into the `IncomingVerificationListener` events `VerificationServiceLive` already consumes. Splitting it out of `VerificationServiceLive` keeps the live impl free of SDK delegate boilerplate and gives us a test seam.

- [ ] **Step 1: Failing test (protocol + fake)**

```swift
// MatronShared/Tests/VerificationTests/DeviceVerificationRequestObserverTests.swift
import XCTest
@testable import MatronVerification

final class FakeIncomingVerificationListener: IncomingVerificationListening {
    var received: [(requestID: String, summary: VerificationRequestSummary, controller: SessionVerificationControlling)] = []
    func onUpdate(requestID: String, summary: VerificationRequestSummary, controller: SessionVerificationControlling) {
        received.append((requestID, summary, controller))
    }
}

final class DeviceVerificationRequestObserverTests: XCTestCase {
    func test_forwardsSdkCallbackIntoListener() {
        let listener = FakeIncomingVerificationListener()
        let observer = DeviceVerificationRequestObserver(listener: listener)
        let controller = FakeSessionVerificationController()
        observer.handleIncomingRequest(
            requestID: "req-1",
            otherUserID: "@alice:s",
            otherDeviceID: "DEV1",
            controller: controller
        )
        XCTAssertEqual(listener.received.count, 1)
        XCTAssertEqual(listener.received.first?.requestID, "req-1")
        XCTAssertEqual(listener.received.first?.summary.otherUserID, "@alice:s")
        XCTAssertEqual(listener.received.first?.summary.otherDeviceID, "DEV1")
        XCTAssertTrue(listener.received.first?.controller === controller)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// MatronShared/Sources/Verification/DeviceVerificationRequestObserver.swift
import Foundation
import MatrixRustSDK

public protocol IncomingVerificationListening: AnyObject, Sendable {
    func onUpdate(
        requestID: String,
        summary: VerificationRequestSummary,
        controller: SessionVerificationControlling
    )
}

/// Adapts SDK verification-request callbacks into `IncomingVerificationListening` events
/// consumed by `VerificationServiceLive`. Owns no state of its own — pure forwarding shim.
public final class DeviceVerificationRequestObserver: @unchecked Sendable {
    private let listener: IncomingVerificationListening

    public init(listener: IncomingVerificationListening) {
        self.listener = listener
    }

    /// Pure entry point used by tests + the real SDK delegate.
    public func handleIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) {
        let summary = VerificationRequestSummary(
            id: requestID,
            otherUserID: otherUserID,
            otherDeviceID: otherDeviceID,
            createdAt: Date()
        )
        listener.onUpdate(requestID: requestID, summary: summary, controller: controller)
    }
}

/// Production-side delegate that the SDK calls. Translates the SDK's payload into our
/// `handleIncomingRequest` shape, wrapping the SDK controller in `LiveSessionVerificationController`.
/// Implementer note: API name varies — verify against SDK version Phase 1 pinned.
final class LiveDeviceVerificationRequestDelegate: @unchecked Sendable {
    private let observer: DeviceVerificationRequestObserver
    init(observer: DeviceVerificationRequestObserver) { self.observer = observer }

    func onIncomingVerificationRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        sdkController: MatrixRustSDK.SessionVerificationController
    ) {
        observer.handleIncomingRequest(
            requestID: requestID,
            otherUserID: otherUserID,
            otherDeviceID: otherDeviceID,
            controller: LiveSessionVerificationController(sdkController)
        )
    }
}
```

- [ ] **Step 3: Verify**

```bash
cd MatronShared && swift test --filter DeviceVerificationRequestObserverTests
```

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Verification/DeviceVerificationRequestObserver.swift \
        MatronShared/Tests/VerificationTests/DeviceVerificationRequestObserverTests.swift
git commit -m "feat: DeviceVerificationRequestObserver adapts SDK callbacks to IncomingVerificationListener"
git push
```

---

### Task 5: RecoveryKeyViewModel + RecoveryKeyView (first-device flow, iOS)

**Files:**
- Create: `MatronShared/Sources/ViewModels/RecoveryKeyViewModel.swift` (target-agnostic; imported by both iOS and Mac via `MatronViewModels`)
- Create: `Matron/Features/Verification/RecoveryKeyView.swift` (iOS view)
- Create: `MatronTests/RecoveryKeyViewModelTests.swift`

Spec §7.2 Scenario A: "Show recovery key once; require user to tick 'I've saved this.' Re-enter it to confirm." That's a three-phase flow on the generate path:

- **Phase A — show:** key visible, "I've saved this" toggle.
- **Phase B — re-enter:** user types/pastes the key; `canFinish` only becomes true when the re-entered string equals `generatedKey` (constant-time compare to defeat timing leakage in the unlikely case anyone ever wires this to a remote check).
- **Phase C — confirm:** persist + dismiss.

(The restore path is unchanged — single phase, key entry → restore.)

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import Matron
@testable import MatronViewModels      // RecoveryKeyViewModel lives in MatronShared
import MatronModels

final class FakeRecoveryKeyManager {
    var generated: String = "MOCK-RECOVERY-KEY-1234-5678"
    var generatedCount = 0
    var restoredKeys: [String] = []

    func generateAndPersist() async throws -> String { generatedCount += 1; return generated }
    func restore(usingKey key: String) async throws { restoredKeys.append(key) }
}

final class RecoveryKeyViewModelTests: XCTestCase {
    @MainActor
    func test_generate_setsGeneratedKey_andEntersPhaseShow() async {
        let fake = FakeRecoveryKeyManager()
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { try await fake.generateAndPersist() }, restore: { _ in })
        await vm.generate()
        XCTAssertEqual(vm.generatedKey, "MOCK-RECOVERY-KEY-1234-5678")
        XCTAssertEqual(fake.generatedCount, 1)
        XCTAssertEqual(vm.generatePhase, .show)
    }

    @MainActor
    func test_acknowledgeSaved_advancesToReenterPhase() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "K"
        vm.generatePhase = .show
        XCTAssertFalse(vm.canFinish)        // can't finish from show phase yet
        vm.userAcknowledgedSaved = true
        vm.advanceFromShow()
        XCTAssertEqual(vm.generatePhase, .reenter)
        XCTAssertFalse(vm.canFinish)        // still can't finish — must re-enter
    }

    @MainActor
    func test_canFinish_isFalseUntilReenteredKeyMatches() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "MOCK-RECOVERY-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter
        vm.reenteredKey = ""
        XCTAssertFalse(vm.canFinish)
        vm.reenteredKey = "WRONG"
        XCTAssertFalse(vm.canFinish)
        vm.reenteredKey = "MOCK-RECOVERY-KEY-1234-5678"
        XCTAssertTrue(vm.canFinish)
    }

    @MainActor
    func test_restore_callsManager() async {
        let fake = FakeRecoveryKeyManager()
        let vm = RecoveryKeyViewModel(mode: .restore, generate: { "" }, restore: { try await fake.restore(usingKey: $0) })
        vm.enteredKey = "abc"
        await vm.attemptRestore()
        XCTAssertEqual(fake.restoredKeys, ["abc"])
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

@Observable
@MainActor
final class RecoveryKeyViewModel {
    enum Mode { case generate, restore }
    enum Phase: Equatable { case idle, busy, done, error(String) }
    /// Sub-phase within `.generate` mode (spec §7.2 Scenario A).
    enum GeneratePhase: Equatable { case notStarted, show, reenter, confirmed }

    let mode: Mode
    var generatedKey: String?
    /// Restore-mode entry.
    var enteredKey: String = ""
    /// Generate-mode re-entry (Phase B).
    var reenteredKey: String = ""
    var userAcknowledgedSaved: Bool = false
    var phase: Phase = .idle
    var generatePhase: GeneratePhase = .notStarted

    private let generate: () async throws -> String
    private let restore: (String) async throws -> Void

    init(mode: Mode, generate: @escaping () async throws -> String, restore: @escaping (String) async throws -> Void) {
        self.mode = mode
        self.generate = generate
        self.restore = restore
    }

    var canFinish: Bool {
        switch mode {
        case .generate:
            // Only finishable from Phase B (`reenter`) once the user has acknowledged
            // saving the key AND the re-entered value matches the generated one
            // (constant-time compare — see `keysMatch`).
            guard generatePhase == .reenter,
                  userAcknowledgedSaved,
                  let key = generatedKey else { return false }
            return Self.keysMatch(key, reenteredKey)
        case .restore:
            return !enteredKey.isEmpty
        }
    }

    /// Constant-time string comparison — avoids returning early on first mismatched byte.
    static func keysMatch(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    func generate() async {
        phase = .busy
        do {
            generatedKey = try await generate()
            phase = .done
            generatePhase = .show
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Advance from Phase A (show) → Phase B (reenter) once user has ticked the
    /// "I've saved this" toggle. Called from the view.
    func advanceFromShow() {
        guard mode == .generate, generatePhase == .show, userAcknowledgedSaved else { return }
        generatePhase = .reenter
    }

    func attemptRestore() async {
        phase = .busy
        do {
            try await restore(enteredKey)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 3: Verify failing tests now pass**

```bash
cd MatronShared && swift test --filter RecoveryKeyViewModelTests
```

- [ ] **Step 4: Implement view**

```swift
import SwiftUI

struct RecoveryKeyView: View {
    @State var viewModel: RecoveryKeyViewModel
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.mode {
            case .generate: generateBody
            case .restore:  restoreBody
            }
            Spacer()
            primaryActionButton
        }
        .padding()
        .navigationTitle("Recovery key")
    }

    /// Continue button label + action vary by phase: in `.generate / .show`, advances to
    /// re-entry; in `.generate / .reenter`, finishes; in `.restore`, finishes.
    @ViewBuilder
    private var primaryActionButton: some View {
        switch (viewModel.mode, viewModel.generatePhase) {
        case (.generate, .show):
            Button("Continue") { viewModel.advanceFromShow() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.userAcknowledgedSaved)
        case (.generate, .reenter):
            Button("Confirm") { onFinished() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canFinish)
        default:
            Button("Continue") { onFinished() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canFinish)
        }
    }

    @ViewBuilder
    private var generateBody: some View {
        switch viewModel.generatePhase {
        case .notStarted, .show:
            Text("This is your recovery key. Save it somewhere safe — it's the only way to recover your encrypted history.")
                .font(.callout)
            if let key = viewModel.generatedKey {
                Text(key)
                    .font(.system(.title3, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Toggle("I've saved this key somewhere safe", isOn: $viewModel.userAcknowledgedSaved)
            } else {
                Button("Generate") { Task { await viewModel.generate() } }
                    .buttonStyle(.bordered)
            }
        case .reenter:
            Text("Re-enter your recovery key to confirm you've saved it correctly.")
                .font(.callout)
            TextField("XXXX-XXXX-XXXX-XXXX", text: $viewModel.reenteredKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !viewModel.reenteredKey.isEmpty && !viewModel.canFinish {
                Text("Doesn't match the key above.").foregroundStyle(.orange).font(.caption)
            }
        case .confirmed:
            EmptyView()
        }
        if case .error(let msg) = viewModel.phase { Text(msg).foregroundStyle(.red).font(.caption) }
    }

    @ViewBuilder
    private var restoreBody: some View {
        Text("Enter your recovery key to unlock encrypted history on this device.")
            .font(.callout)
        TextField("XXXX-XXXX-XXXX-XXXX", text: $viewModel.enteredKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.title3, design: .monospaced))
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        Button("Restore") { Task { await viewModel.attemptRestore() } }
            .buttonStyle(.bordered)
            .disabled(viewModel.enteredKey.isEmpty)
        if case .error(let msg) = viewModel.phase { Text(msg).foregroundStyle(.red).font(.caption) }
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Verification/RecoveryKeyView.swift \
        MatronShared/Sources/ViewModels/RecoveryKeyViewModel.swift \
        MatronTests/RecoveryKeyViewModelTests.swift
git commit -m "feat: RecoveryKeyView with show + re-enter + confirm phases (iOS)"
git push
```

---

### Task 5c: MacRecoveryKeyView

**Files:**
- Create: `MatronMac/Features/Verification/MacRecoveryKeyView.swift`
- Create: `MatronMac/Features/Verification/NSPasteboardWrapper.swift`
- Create: `MatronMacTests/MacRecoveryKeyViewTests.swift`

The Mac recovery-key view has the same three phases as iOS (show / re-enter / confirmed; spec §7.2 Scenario A) but uses native Mac chrome: `NSPasteboard` for copy + paste detection, `.textSelection(.enabled)` so the displayed key is selectable, fixed-size sheet (480×400) instead of half-sheet. Mac users will likely paste the recovery key from a password manager or from clipboard (having copied it on iOS), so Phase B auto-advances to Phase C as soon as the pasted text matches `generatedKey`. Same `RecoveryKeyViewModel` from `MatronShared/Sources/ViewModels/` — view-only differences.

> **iCloud Keychain auto-restore on Mac:** spec §7.1 states macOS Keychain auto-syncs to iCloud Keychain when the user has it enabled, so a Mac install can pick up the recovery key written by the iOS install (Task 3 already passes `synchronizable: true` to `KeychainStore` via `kSecAttrSynchronizable`). When the user lands on `MacRecoveryKeyView` in `.restore` mode and `RecoveryKeyManager.currentKey()` returns a non-nil value, prefill the entry field and offer a one-tap "Use saved recovery key" button. The `KeychainStore` `synchronizable` flag from Task 3 makes the Mac side a read-only consumer here — no UI difference from the underlying iOS scheme, just a different default-state experience.

- [ ] **Step 1: Failing tests — paste detection auto-advances**

```swift
// MatronMacTests/MacRecoveryKeyViewTests.swift
import XCTest
@testable import MatronMac
@testable import MatronViewModels

final class FakeNSPasteboard: NSPasteboardReading {
    var stringValue: String?
    func string(forType type: NSPasteboard.PasteboardType) -> String? { stringValue }
}

final class MacRecoveryKeyViewTests: XCTestCase {
    @MainActor
    func test_pasteOfMatchingKey_autoAdvancesToConfirmed() async {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "MOCK-KEY-1234" }, restore: { _ in })
        vm.generatedKey = "MOCK-KEY-1234"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter

        let pasteboard = FakeNSPasteboard()
        pasteboard.stringValue = "MOCK-KEY-1234"
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()

        XCTAssertEqual(vm.reenteredKey, "MOCK-KEY-1234")
        XCTAssertTrue(vm.canFinish)
        XCTAssertEqual(vm.generatePhase, .confirmed)
    }

    @MainActor
    func test_pasteOfNonMatchingKey_doesNotAdvance() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "MOCK-KEY-1234"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter

        let pasteboard = FakeNSPasteboard()
        pasteboard.stringValue = "WRONG"
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()

        XCTAssertEqual(vm.reenteredKey, "WRONG")
        XCTAssertFalse(vm.canFinish)
        XCTAssertEqual(vm.generatePhase, .reenter)
    }
}
```

- [ ] **Step 2: Implement `NSPasteboardWrapper` (protocol seam)**

```swift
// MatronMac/Features/Verification/NSPasteboardWrapper.swift
import AppKit

/// Read-only abstraction over `NSPasteboard` so paste detection can be unit-tested
/// against an in-memory fake without touching the system pasteboard.
protocol NSPasteboardReading {
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

/// Production adapter — forwards to `NSPasteboard.general`.
final class LiveNSPasteboard: NSPasteboardReading {
    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        NSPasteboard.general.string(forType: type)
    }
}

/// Bridges clipboard contents into `RecoveryKeyViewModel.reenteredKey` and auto-advances
/// to `.confirmed` when the key matches. View calls `checkClipboardAndApply()` from
/// `.onChange(of: scenePhase)` and from a "Paste" button.
@MainActor
final class PasteDetector {
    private let pasteboard: NSPasteboardReading
    private let viewModel: RecoveryKeyViewModel

    init(pasteboard: NSPasteboardReading, viewModel: RecoveryKeyViewModel) {
        self.pasteboard = pasteboard
        self.viewModel = viewModel
    }

    func checkClipboardAndApply() {
        guard viewModel.mode == .generate, viewModel.generatePhase == .reenter else { return }
        guard let candidate = pasteboard.string(forType: .string), !candidate.isEmpty else { return }
        viewModel.reenteredKey = candidate
        if viewModel.canFinish {
            viewModel.generatePhase = .confirmed
        }
    }
}
```

- [ ] **Step 3: Implement `MacRecoveryKeyView`**

```swift
// MatronMac/Features/Verification/MacRecoveryKeyView.swift
import SwiftUI
import AppKit
import MatronViewModels
import MatronModels

struct MacRecoveryKeyView: View {
    @State var viewModel: RecoveryKeyViewModel
    let onFinished: () -> Void
    @State private var detector: PasteDetector?

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.mode {
            case .generate: generateBody
            case .restore:  restoreBody
            }
            Spacer()
            primaryActionButton
        }
        .padding(24)
        .frame(width: 480, height: 400)        // fixed-size Mac sheet (not a half-sheet)
        .navigationTitle("Recovery key")
        .onAppear {
            detector = PasteDetector(pasteboard: LiveNSPasteboard(), viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var generateBody: some View {
        switch viewModel.generatePhase {
        case .notStarted, .show:
            Text("This is your recovery key. Save it somewhere safe — it's the only way to recover your encrypted history.")
                .font(.callout)
            if let key = viewModel.generatedKey {
                HStack {
                    Text(key)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                }
                Toggle("I've saved this key somewhere safe", isOn: $viewModel.userAcknowledgedSaved)
            } else {
                Button("Generate") { Task { await viewModel.generate() } }
            }
        case .reenter:
            Text("Re-enter your recovery key, or paste it from the clipboard.")
                .font(.callout)
            HStack {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $viewModel.reenteredKey)
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Paste") { detector?.checkClipboardAndApply() }
            }
            // Auto-advance is also driven by `onChange` so typing the right key works too.
            .onChange(of: viewModel.reenteredKey) { _, _ in
                if viewModel.canFinish { viewModel.generatePhase = .confirmed }
            }
            if !viewModel.reenteredKey.isEmpty && !viewModel.canFinish {
                Text("Doesn't match the key above.").foregroundStyle(.orange).font(.caption)
            }
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
            Text("Recovery key confirmed").font(.title2).bold()
                .task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    onFinished()
                }
        }
        if case .error(let msg) = viewModel.phase { Text(msg).foregroundStyle(.red).font(.caption) }
    }

    @ViewBuilder
    private var restoreBody: some View {
        Text("Enter your recovery key to unlock encrypted history on this Mac.")
            .font(.callout)
        HStack {
            TextField("XXXX-XXXX-XXXX-XXXX", text: $viewModel.enteredKey)
                .font(.system(.title3, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Button("Paste") {
                if let s = NSPasteboard.general.string(forType: .string) { viewModel.enteredKey = s }
            }
        }
        Button("Restore") { Task { await viewModel.attemptRestore() } }
            .keyboardShortcut(.return)
            .disabled(viewModel.enteredKey.isEmpty)
        if case .error(let msg) = viewModel.phase { Text(msg).foregroundStyle(.red).font(.caption) }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch (viewModel.mode, viewModel.generatePhase) {
        case (.generate, .show):
            Button("Continue") { viewModel.advanceFromShow() }
                .keyboardShortcut(.return)
                .disabled(!viewModel.userAcknowledgedSaved)
        case (.generate, .reenter):
            Button("Confirm") { viewModel.generatePhase = .confirmed; onFinished() }
                .keyboardShortcut(.return)
                .disabled(!viewModel.canFinish)
        case (.generate, .confirmed):
            EmptyView()        // auto-dismisses via the .task delay
        default:
            EmptyView()
        }
    }
}
```

- [ ] **Step 4: Verify**

```bash
xcodebuild test -scheme MatronMac -only-testing:MatronMacTests/MacRecoveryKeyViewTests
```

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Verification/MacRecoveryKeyView.swift \
        MatronMac/Features/Verification/NSPasteboardWrapper.swift \
        MatronMacTests/MacRecoveryKeyViewTests.swift
git commit -m "feat: MacRecoveryKeyView with NSPasteboard paste detection"
git push
```

---

### Task 6: SasViewModel + SasView (iOS)

**Files:**
- Create: `MatronShared/Sources/ViewModels/SasViewModel.swift` (target-agnostic; imported by both iOS and Mac via `MatronViewModels`)
- Create: `Matron/Features/Verification/SasView.swift` (iOS view)
- Create: `MatronTests/SasViewModelTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import Matron
@testable import MatronViewModels      // SasViewModel lives in MatronShared
import MatronModels

final class SasViewModelTests: XCTestCase {
    @MainActor
    func test_consumesStreamAndMovesThroughStates() async {
        let states: [SasFlowState] = [
            .requested,
            .readyForEmoji([SasEmoji(symbol: "🐢", description: "Turtle")]),
            .awaitingConfirmation,
            .verified,
        ]
        let stream = AsyncStream<SasFlowState> { c in
            for s in states { c.yield(s) }
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        XCTAssertEqual(vm.state, .verified)
    }

    @MainActor
    func test_confirm_invokesCallback() async {
        var confirmed = false
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: { confirmed = true }, cancel: { _ in })
        await vm.confirm()
        XCTAssertTrue(confirmed)
    }

    @MainActor
    func test_observe_isIdempotent_underDoubleCall() async {
        // Two calls to observe() must NOT re-consume the stream. The second call must
        // early-return immediately because `isObserving` is already true.
        var yielded = 0
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.requested); yielded += 1
            c.yield(.verified);  yielded += 1
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let yieldedAfterFirst = yielded
        await vm.observe()  // must be a no-op, not re-iterate the (already-finished) stream
        XCTAssertEqual(yielded, yieldedAfterFirst, "observe() must be guarded against double-call")
        XCTAssertEqual(vm.state, .verified)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

@Observable
@MainActor
final class SasViewModel {
    private(set) var state: SasFlowState = .idle
    let requestID: String
    private let stream: AsyncStream<SasFlowState>
    private let confirmAction: () async throws -> Void
    private let cancelAction: (String) async throws -> Void
    /// Re-entrancy guard: `observe()` must consume the stream exactly once even if
    /// SwiftUI re-fires the `.task` modifier (e.g. on view re-presentation).
    private var isObserving: Bool = false

    init(
        stream: AsyncStream<SasFlowState>,
        requestID: String,
        confirm: @escaping () async throws -> Void,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.stream = stream
        self.requestID = requestID
        self.confirmAction = confirm
        self.cancelAction = cancel
    }

    func observe() async {
        guard !isObserving else { return }
        isObserving = true
        for await new in stream {
            state = new
        }
    }

    func confirm() async { try? await confirmAction() }
    func cancel(reason: String = "User cancelled") async { try? await cancelAction(reason) }
}
```

- [ ] **Step 3: View**

```swift
import SwiftUI

struct SasView: View {
    @State var viewModel: SasViewModel
    let title: String

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle, .requested:
                ProgressView("Starting verification…")
            case .readyForEmoji(let emojis):
                emojiCard(emojis)
                buttons
            case .awaitingConfirmation:
                ProgressView("Waiting for the other device…")
            case .verified:
                Image(systemName: "checkmark.shield.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("Verified").font(.title2).bold()
            case .cancelled(let reason):
                Image(systemName: "xmark.shield.fill").font(.system(size: 60)).foregroundStyle(.red)
                Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle(title)
        // Use `.task(id:)` so re-presentation with the same request ID doesn't re-fire,
        // and pairs with the `isObserving` guard inside the view-model.
        .task(id: viewModel.requestID) { await viewModel.observe() }
    }

    @ViewBuilder
    private func emojiCard(_ emojis: [SasEmoji]) -> some View {
        VStack(spacing: 12) {
            Text("Compare these emojis with the other device.").font(.callout)
            HStack(spacing: 12) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    VStack {
                        Text(e.symbol).font(.system(size: 44))
                        Text(e.description).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("They don't match", role: .destructive) { Task { await viewModel.cancel() } }
                .buttonStyle(.bordered)
            Spacer()
            Button("They match") { Task { await viewModel.confirm() } }
                .buttonStyle(.borderedProminent)
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Matron/Features/Verification/SasView.swift MatronShared/Sources/ViewModels/SasViewModel.swift \
        MatronTests/SasViewModelTests.swift
git commit -m "feat: SasView for emoji-compare verification (iOS)"
git push
```

---

### Task 7c: MacSasView

**Files:**
- Create: `MatronMac/Features/Verification/MacSasView.swift`

Native Mac sheet rendering of the SAS emoji compare flow. Same `SasViewModel` from `MatronShared/Sources/ViewModels/` (via `MatronViewModels` import) — no extra view-model logic. Differences from iOS:

- Renders as a fixed-size Mac sheet (`.sheet(isPresented:)` returning a 480×400 view), not a half-sheet — Mac sheets are always centred and modal-to-window.
- Same 7-emoji grid layout (use `LazyVGrid` of 7 columns or two rows of 4+3 to keep Mac-native compact spacing).
- Buttons get keyboard shortcuts: "They match" → `.keyboardShortcut(.return)`, "They don't match" → `.keyboardShortcut(.escape, modifiers: [])`.

- [ ] **Step 1: Implement**

```swift
// MatronMac/Features/Verification/MacSasView.swift
import SwiftUI
import MatronViewModels
import MatronModels

struct MacSasView: View {
    @State var viewModel: SasViewModel
    let title: String

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle, .requested:
                ProgressView("Starting verification…")
            case .readyForEmoji(let emojis):
                emojiGrid(emojis)
                buttons
            case .awaitingConfirmation:
                ProgressView("Waiting for the other device…")
            case .verified:
                Image(systemName: "checkmark.shield.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("Verified").font(.title2).bold()
            case .cancelled(let reason):
                Image(systemName: "xmark.shield.fill").font(.system(size: 60)).foregroundStyle(.red)
                Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)        // fixed-size Mac sheet
        .navigationTitle(title)
        .task(id: viewModel.requestID) { await viewModel.observe() }
    }

    @ViewBuilder
    private func emojiGrid(_ emojis: [SasEmoji]) -> some View {
        VStack(spacing: 12) {
            Text("Compare these emojis with the other device.").font(.callout)
            // 7-emoji grid: top row 4, bottom row 3 — matches iOS layout densely.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    VStack {
                        Text(e.symbol).font(.system(size: 40))
                        Text(e.description).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("They don't match", role: .destructive) { Task { await viewModel.cancel() } }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            Button("They match") { Task { await viewModel.confirm() } }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
        }
    }
}
```

- [ ] **Step 2: Verify**

The `SasViewModel` test suite (`SasViewModelTests`) already covers the underlying state-machine; `MacSasView` is view-only chrome. Visual coverage comes from snapshots in Task 12. No new logic-test in this step.

- [ ] **Step 3: Commit**

```bash
git add MatronMac/Features/Verification/MacSasView.swift
git commit -m "feat: MacSasView fixed-size sheet with keyboard shortcuts"
git push
```

---

### Task 7: PostLoginVerificationView (onboarding step 2)

**Files:**
- Create: `Matron/Features/Onboarding/PostLoginVerificationView.swift`
- Modify: `Matron/App/MatronApp.swift`

The two-screen onboarding from spec §5.2 — sign in (Phase 1) then verify (this task).

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MatronModels

struct PostLoginVerificationView: View {
    enum Path: Hashable {
        case generate
        case sasWithOtherDevice
        case restoreWithRecoveryKey
    }

    let dependencies: AppDependencies
    let session: UserSession
    let onCompleted: () -> Void

    @State private var hasOtherDevices: Bool? = nil
    @State private var path: [Path] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.system(size: 60)).foregroundStyle(.tint)
                Text("Secure this device").font(.title2).bold()
                Text("Choose how to set up encryption for this device.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)

                Button {
                    path.append(.sasWithOtherDevice)
                } label: {
                    Label("Verify with another device", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    path.append(.restoreWithRecoveryKey)
                } label: {
                    Label("Use recovery key", systemImage: "key")
                }
                .buttonStyle(.bordered)

                Button("This is my first device — generate a key") {
                    path.append(.generate)
                }
                .padding(.top, 8)
            }
            .padding()
            .navigationDestination(for: Path.self) { destination in
                switch destination {
                case .generate:
                    let mgr = RecoveryKeyManager(provider: dependencies.clientProvider, session: session, keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true))
                    RecoveryKeyView(viewModel: RecoveryKeyViewModel(
                        mode: .generate,
                        generate: { try await mgr.generateAndPersist() },
                        restore: { _ in }
                    ), onFinished: onCompleted)
                case .restoreWithRecoveryKey:
                    let mgr = RecoveryKeyManager(provider: dependencies.clientProvider, session: session, keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true))
                    RecoveryKeyView(viewModel: RecoveryKeyViewModel(
                        mode: .restore,
                        generate: { "" },
                        restore: { try await mgr.restore(usingKey: $0) }
                    ), onFinished: onCompleted)
                case .sasWithOtherDevice:
                    let svc = VerificationServiceLive(provider: dependencies.clientProvider, session: session)
                    // The self-verification request gets a synthetic request ID derived
                    // from the user/device pair so SasViewModel can route confirm/cancel
                    // back to the right cached flow.
                    let requestID = "self-verify:\(session.userID):\(session.deviceID)"
                    let stream = svc.startSAS(withUser: session.userID, deviceID: nil)
                    SasView(viewModel: SasViewModel(
                        stream: stream,
                        requestID: requestID,
                        confirm: { try await svc.confirmEmojiMatch(requestID: requestID) },
                        cancel: { reason in try await svc.cancel(requestID: requestID, reason: reason) }
                    ), title: "Verify this device")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Wire into `MatronApp`**

Add a `@State private var verifyDone = false` to `MatronApp`. In the post-login branch, gate the chat list behind verification. After successful verification (or skip), set `verifyDone = true` and persist that flag in `UserDefaults`.

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Onboarding/PostLoginVerificationView.swift Matron/App/MatronApp.swift
git commit -m "feat: PostLoginVerificationView wired as onboarding step 2"
git push
```

---

### Task 8: VerificationCenter — observe incoming bot verification requests

**Files:**
- Create: `Matron/Features/Verification/VerificationCenter.swift`
- Create: `MatronTests/VerificationCenterTests.swift`

- [ ] **Step 1: Failing test — dismiss must cancel the SDK request**

```swift
import XCTest
@testable import Matron
import MatronModels

final class VerificationCenterTests: XCTestCase {
    @MainActor
    func test_dismiss_callsServiceCancelBeforeRemovingFromPending() async {
        let svc = FakeVerificationService()
        let center = VerificationCenter(service: svc)
        let summary = VerificationRequestSummary(id: "req-1", otherUserID: "@bob:s", otherDeviceID: "DEV", createdAt: Date())
        center.injectPending(summary)  // test seam — appends to `pending` directly

        await center.dismiss(summary)

        XCTAssertEqual(svc.cancelled.map(\.id), ["req-1"])
        XCTAssertEqual(svc.cancelled.first?.reason, "User dismissed")
        XCTAssertTrue(center.pending.isEmpty)
    }
}
```

(Extend `FakeVerificationService` to record `(id, reason)` tuples in `cancelled`.)

- [ ] **Step 2: Implement**

```swift
import Foundation
import MatronModels

@Observable
@MainActor
final class VerificationCenter {
    private(set) var pending: [VerificationRequestSummary] = []

    private let service: VerificationService
    private var observationTask: Task<Void, Never>?

    init(service: VerificationService) {
        self.service = service
    }

    func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await summary in service.incomingRequests() {
                await MainActor.run {
                    if !self.pending.contains(where: { $0.id == summary.id }) {
                        self.pending.append(summary)
                    }
                }
            }
        }
    }

    func stop() { observationTask?.cancel() }

    /// Dismissing a banner must also cancel the underlying SDK verification request,
    /// otherwise the other side keeps the request open forever and the user sees a
    /// stale "waiting" UI on the partner device. Cancel-then-remove ordering ensures
    /// the SDK call still happens even if `pending` removal would otherwise skip it.
    func dismiss(_ summary: VerificationRequestSummary) async {
        try? await service.cancel(requestID: summary.id, reason: "User dismissed")
        pending.removeAll { $0.id == summary.id }
    }

    #if DEBUG
    /// Test seam — lets unit tests pre-populate `pending` without driving the stream.
    func injectPending(_ summary: VerificationRequestSummary) { pending.append(summary) }
    #endif
}
```

- [ ] **Step 3: Verify**

```bash
cd MatronShared && swift test --filter VerificationCenterTests
```

- [ ] **Step 4: Commit**

```bash
git add Matron/Features/Verification/VerificationCenter.swift \
        MatronTests/VerificationCenterTests.swift
git commit -m "feat: VerificationCenter cancels SDK request on dismiss"
git push
```

---

### Task 9: VerificationBanner

**Files:**
- Create: `Matron/Features/Verification/VerificationBanner.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift`

- [ ] **Step 1: Implement banner**

```swift
import SwiftUI
import MatronModels

struct VerificationBanner: View {
    let summary: VerificationRequestSummary
    let onAccept: (VerificationRequestSummary) -> Void
    let onDismiss: (VerificationRequestSummary) -> Void

    var body: some View {
        HStack {
            Image(systemName: "lock.shield.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.otherUserID) wants to verify").font(.callout).bold()
                if let device = summary.otherDeviceID {
                    Text(device).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Verify") { onAccept(summary) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button {
                onDismiss(summary)
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
```

- [ ] **Step 2: Add the banner to `ChatListView`**

In `ChatListView`, hold a `@State var verificationCenter: VerificationCenter` and a `@State var sasSummary: VerificationRequestSummary?`. Above the `List`, render a `ForEach(verificationCenter.pending)` of `VerificationBanner`s. Tap "Verify" → set `sasSummary` → `.sheet(item: $sasSummary)` presents a `SasView`. Tap dismiss → `Task { await verificationCenter.dismiss(summary) }` (async, because `dismiss` cancels the SDK request before removing from `pending`).

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Verification/VerificationBanner.swift Matron/Features/ChatList/ChatListView.swift
git commit -m "feat: VerificationBanner top-of-list overlay; tap launches SAS"
git push
```

---

### Task 9b: MacVerificationBanner

**Files:**
- Create: `MatronMac/Features/Verification/MacVerificationBanner.swift`
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (or equivalent — Phase 2's Mac sidebar)
- Create: `MatronMacTests/MacVerificationBannerSnapshotTests.swift`

The Mac equivalent of `VerificationBanner` renders as a top-of-window banner above the chat-list sidebar (within the leading column of `NavigationSplitView`) when `VerificationCenter.pending` is non-empty. Click "Verify" → opens `MacSasView` as a fixed-size sheet (Task 7c). Same `VerificationCenter` from Task 8 — the orchestrator is shared across platforms.

- [ ] **Step 1: Implement `MacVerificationBanner`**

```swift
// MatronMac/Features/Verification/MacVerificationBanner.swift
import SwiftUI
import MatronModels

struct MacVerificationBanner: View {
    let summary: VerificationRequestSummary
    let onAccept: (VerificationRequestSummary) -> Void
    let onDismiss: (VerificationRequestSummary) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.otherUserID) wants to verify").font(.callout).bold()
                if let device = summary.otherDeviceID {
                    Text(device).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Verify") { onAccept(summary) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button {
                onDismiss(summary)
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}
```

- [ ] **Step 2: Hook into `MacChatListView`**

In the Mac sidebar view (Phase 2 deliverable), hold a `@State var verificationCenter: VerificationCenter` and `@State var sasSummary: VerificationRequestSummary?`. Above the chat list, render `ForEach(verificationCenter.pending)` of `MacVerificationBanner`s. Tap "Verify" → set `sasSummary` → `.sheet(item: $sasSummary) { MacSasView(...) }`. Tap dismiss → `Task { await verificationCenter.dismiss(summary) }` (same async-cancel-before-remove ordering as iOS).

- [ ] **Step 3: Snapshot tests**

```swift
// MatronMacTests/MacVerificationBannerSnapshotTests.swift
import XCTest
import SnapshotTesting
@testable import MatronMac

final class MacVerificationBannerSnapshotTests: XCTestCase {
    func test_banner_renders_macVariants() {
        let summary = VerificationRequestSummary(
            id: "req-1",
            otherUserID: "@alice:example.org",
            otherDeviceID: "DEV1",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let view = MacVerificationBanner(summary: summary, onAccept: { _ in }, onDismiss: { _ in })
            .frame(width: 320)
        // Mac scheme runs only the Mac-side variants of the 6-variant assertVariants helper.
        assertVariants(of: view, named: "MacVerificationBanner")
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add MatronMac/Features/Verification/MacVerificationBanner.swift \
        MatronMac/Features/ChatList/MacChatListView.swift \
        MatronMacTests/MacVerificationBannerSnapshotTests.swift
git commit -m "feat: MacVerificationBanner top-of-window overlay; tap launches MacSasView"
git push
```

---

### Task 9c: Help menu wire-up (Mac)

**Files:**
- Modify: `MatronMac/App/MatronMacCommands.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (root scene observes the menu posts)

Phase 2 added Help menu placeholders for "Verify This Device…" and "Show Recovery Key…" (spec §5.9). Phase 3 wires them to the real flows:

- **Verify This Device…** — if the user has another logged-in device, opens `MacSasView` driven by a fresh `VerificationServiceLive.startSAS(...)`. If no other devices are reachable, falls back to opening `MacRecoveryKeyView` in `.restore` mode (matches spec §7.2 Scenario B fallback).
- **Show Recovery Key…** — opens `MacRecoveryKeyView` in a re-authentication-then-reveal mode: prompts for the user's recovery key (entry sheet), then displays it back via `RecoveryKeyManager.currentKey()` once re-authenticated. Matches the iOS Settings → Show Recovery Key flow from Task 11.

The wiring uses the SwiftUI `Notification.Name` pattern: menu items post a notification, the root scene's `onReceive` hands it to a state binding that flips a sheet open. The notification names live in a small `MatronCommand` namespace next to `MatronMacCommands.swift`.

- [ ] **Step 1: Define notification names**

```swift
// MatronMac/App/MatronMacCommands.swift
import SwiftUI

extension Notification.Name {
    /// Posted by the Help menu's "Verify This Device…" item.
    static let matronVerifyDeviceCommand = Notification.Name("MatronCommand.verifyDevice")
    /// Posted by the Help menu's "Show Recovery Key…" item.
    static let matronShowRecoveryKeyCommand = Notification.Name("MatronCommand.showRecoveryKey")
}

/// Convenience for callers — `View.matronCommand(.verifyDevice)` reads as
/// "observe the verify-device menu command".
enum MatronCommand {
    case verifyDevice, showRecoveryKey

    var notificationName: Notification.Name {
        switch self {
        case .verifyDevice:    return .matronVerifyDeviceCommand
        case .showRecoveryKey: return .matronShowRecoveryKeyCommand
        }
    }
}

extension View {
    func matronCommand(_ command: MatronCommand, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: command.notificationName)) { _ in
            action()
        }
    }
}
```

- [ ] **Step 2: Replace Phase 2 placeholders with posts**

Inside the existing `.commands { ... }` block from Phase 2 (Help menu group), replace the two placeholder buttons with the wired versions:

```swift
CommandGroup(replacing: .help) {
    Button("Verify This Device…") {
        NotificationCenter.default.post(name: .matronVerifyDeviceCommand, object: nil)
    }
    Button("Show Recovery Key…") {
        NotificationCenter.default.post(name: .matronShowRecoveryKeyCommand, object: nil)
    }
}
```

- [ ] **Step 3: Observe the posts in the root scene**

In `MatronMacApp`'s `WindowGroup` body, add observers that flip presentation state:

```swift
@State private var showSasSheet = false
@State private var showRecoveryKeySheet = false

WindowGroup {
    RootMacView(...)
        .matronCommand(.verifyDevice) { showSasSheet = true }
        .matronCommand(.showRecoveryKey) { showRecoveryKeySheet = true }
        .sheet(isPresented: $showSasSheet) {
            // If another device is reachable, present SAS; else fall back to recovery-key restore.
            // The "is another device reachable" check is best-effort — call
            // VerificationServiceLive.isThisDeviceVerified() and look at the SDK device list;
            // if empty (only this device), present MacRecoveryKeyView in .restore mode instead.
            MacSasView(viewModel: makeSasViewModelForSelfVerification(), title: "Verify this device")
        }
        .sheet(isPresented: $showRecoveryKeySheet) {
            MacRecoveryKeyView(
                viewModel: RecoveryKeyViewModel(
                    mode: .restore,
                    generate: { "" },
                    restore: { _ in }
                ),
                onFinished: { showRecoveryKeySheet = false }
            )
        }
}
```

> **Implementer note:** `makeSasViewModelForSelfVerification()` mirrors the construction inside `PostLoginVerificationView` (Task 7) — building a `SasViewModel` over a fresh `VerificationServiceLive.startSAS(withUser:deviceID:)` stream with the synthetic `self-verify:` request ID. Extract that into a tiny helper in `MatronShared/Sources/ViewModels/` if it ends up duplicated more than twice.

- [ ] **Step 4: Commit**

```bash
git add MatronMac/App/MatronMacCommands.swift MatronMac/App/MatronMacApp.swift
git commit -m "feat: wire Mac Help menu (Verify This Device, Show Recovery Key) to flows"
git push
```

---

### Task 10: ChatView verification-state banner (per-room)

**Files:**
- Modify: `Matron/Features/Chat/ChatView.swift`

If the bot in this room has any unverified device, show a small inline banner: "This device hasn't been verified — Verify".

- [ ] **Step 1: Add a verification check in `ChatView`**

Inject a `VerificationService` via `Environment` (similar to `AppDependencies`). On task start, call `isThisDeviceVerified()` for the bot's matrix ID; if false, show a banner above the timeline.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: ChatView shows per-bot verification banner when unverified"
git push
```

---

### Task 11: DeviceSettingsView (Settings entry point)

**Files:**
- Create: `Matron/Features/Settings/DeviceSettingsView.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift` (add a Settings button)

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MatronModels

struct DeviceSettingsView: View {
    let session: UserSession
    let recoveryKeyManager: RecoveryKeyManager
    let verificationService: VerificationService

    @State private var isVerified: Bool? = nil
    @State private var revealedKey: String? = nil

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("User ID", value: session.userID)
                LabeledContent("Device ID", value: session.deviceID)
                LabeledContent("Server", value: session.homeserverURL.host ?? session.homeserverURL.absoluteString)
            }
            Section("Encryption") {
                LabeledContent("This device verified") {
                    if let isVerified {
                        Image(systemName: isVerified ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(isVerified ? .green : .orange)
                    } else {
                        ProgressView()
                    }
                }
                Button("Show recovery key") {
                    revealedKey = (try? recoveryKeyManager.currentKey()) ?? "(not stored)"
                }
            }
            if let key = revealedKey {
                Section("Recovery key") {
                    Text(key).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Device")
        .task {
            isVerified = (try? await verificationService.isThisDeviceVerified()) ?? false
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Matron/Features/Settings/DeviceSettingsView.swift Matron/Features/ChatList/ChatListView.swift
git commit -m "feat: DeviceSettingsView with verification status + recovery key reveal"
git push
```

---

### Task 12: Snapshot tests — Mac verification chrome

**Files:**
- Create: `MatronMacTests/MacSasViewSnapshotTests.swift`
- Create: `MatronMacTests/MacRecoveryKeyViewSnapshotTests.swift`
- Already created in Task 9b: `MatronMacTests/MacVerificationBannerSnapshotTests.swift` — referenced here for completeness.

Use the same `assertVariants(of:named:)` helper added in Phase 2 (now does 6 variants: `{iOS, Mac} × {light, dark, accessibility5}`). Mac targets snapshot only the Mac variants of the helper (the helper internally skips the iOS triple when running under the Mac scheme — see Phase 2 Task 2 Step 2 for the helper's implementation).

- [ ] **Step 1: `MacSasView` snapshots**

```swift
// MatronMacTests/MacSasViewSnapshotTests.swift
import XCTest
import SnapshotTesting
@testable import MatronMac
@testable import MatronViewModels

final class MacSasViewSnapshotTests: XCTestCase {
    @MainActor
    func test_emojiCompareState() {
        let emojis = (0..<7).map { SasEmoji(symbol: ["🐢","🚀","🍎","🐱","🌟","🔥","🦄"][$0], description: "E\($0)") }
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.readyForEmoji(emojis))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "snap", confirm: {}, cancel: { _ in })
        // Drive the VM to the emoji state synchronously by yielding through an awaited observe().
        let exp = expectation(description: "observe")
        Task { @MainActor in await vm.observe(); exp.fulfill() }
        wait(for: [exp], timeout: 1)
        assertVariants(of: MacSasView(viewModel: vm, title: "Verify this device"),
                       named: "MacSasView_emojiCompare")
    }

    @MainActor
    func test_verifiedState() {
        let stream = AsyncStream<SasFlowState> { c in c.yield(.verified); c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "snap", confirm: {}, cancel: { _ in })
        let exp = expectation(description: "observe")
        Task { @MainActor in await vm.observe(); exp.fulfill() }
        wait(for: [exp], timeout: 1)
        assertVariants(of: MacSasView(viewModel: vm, title: "Verify this device"),
                       named: "MacSasView_verified")
    }
}
```

- [ ] **Step 2: `MacRecoveryKeyView` snapshots — one per phase**

```swift
// MatronMacTests/MacRecoveryKeyViewSnapshotTests.swift
import XCTest
import SnapshotTesting
@testable import MatronMac
@testable import MatronViewModels

final class MacRecoveryKeyViewSnapshotTests: XCTestCase {
    @MainActor
    func test_show_phase() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "MOCK-KEY" }, restore: { _ in })
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.generatePhase = .show
        assertVariants(of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
                       named: "MacRecoveryKeyView_show")
    }

    @MainActor
    func test_reenter_phase_mismatch() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter
        vm.reenteredKey = "WRONG"
        assertVariants(of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
                       named: "MacRecoveryKeyView_reenterMismatch")
    }

    @MainActor
    func test_confirmed_phase() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.reenteredKey = "MOCK-KEY-1234-5678"
        vm.generatePhase = .confirmed
        assertVariants(of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
                       named: "MacRecoveryKeyView_confirmed")
    }

    @MainActor
    func test_restore_mode() {
        let vm = RecoveryKeyViewModel(mode: .restore, generate: { "" }, restore: { _ in })
        vm.enteredKey = "MOCK-KEY-1234-5678"
        assertVariants(of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
                       named: "MacRecoveryKeyView_restore")
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -scheme MatronMac -only-testing:MatronMacTests/MacSasViewSnapshotTests \
                                  -only-testing:MatronMacTests/MacRecoveryKeyViewSnapshotTests
git add MatronMacTests/MacSasViewSnapshotTests.swift \
        MatronMacTests/MacRecoveryKeyViewSnapshotTests.swift \
        MatronMacTests/__Snapshots__/
git commit -m "test: snapshot variants for Mac SAS + recovery key views"
git push
```

---

### Task 13: MatronMac entitlements — keychain access group

**Files:**
- Modify: `MatronMac/MatronMac.entitlements`

Spec §7.1 establishes that the Mac crypto store is encrypted at rest with a Keychain-stored passphrase, and §7.2 Scenario A states the recovery key persists to iCloud Keychain so a Mac install can pick it up from an iOS install. For both to work consistently, the Mac entitlements must declare the same Keychain access group convention as iOS (Phase 1):

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)chat.matron.mac</string>
</array>
```

The Mac bundle's keychain access group is namespaced to `chat.matron.mac` (matches the bundle ID from spec §8.1). iCloud Keychain auto-sync is independent of access group — it's controlled by the `kSecAttrSynchronizable` flag on each item (see `KeychainStore` in Task 3). So a recovery key written by iOS with `synchronizable: true` automatically shows up in Mac Keychain on a sync-enabled device, even though the access group strings differ.

- [ ] **Step 1: Verify entitlements file matches**

```bash
plutil -p MatronMac/MatronMac.entitlements | grep keychain-access-groups -A 3
```

Expected output includes the `$(AppIdentifierPrefix)chat.matron.mac` entry.

- [ ] **Step 2: Add a setup-time assertion**

In `MatronMacApp`'s init (or first-run check), assert that `KeychainStore(service: "chat.matron.recovery", synchronizable: true).set(_:forKey:)` round-trips successfully against a probe value. If it fails (entitlements misconfigured), surface a fatal-but-helpful error in the onboarding screen ("Keychain access not configured — see docs/setup-mac.md") rather than silently no-op'ing.

- [ ] **Step 3: Commit**

```bash
git add MatronMac/MatronMac.entitlements MatronMac/App/MatronMacApp.swift
git commit -m "feat: MatronMac keychain-access-groups entitlement for E2EE recovery"
git push
```

---

### Task 14: Manual test additions

Append to `manual-tests.md`:

```markdown
## Phase 3 (E2EE & Verification UX)

### First-device flow (iOS)

- [ ] Fresh install, sign in → PostLoginVerificationView appears.
- [ ] Tap "This is my first device" → recovery key generated and shown.
- [ ] Toggle "I've saved this key" → Continue is enabled. Tap Continue → re-enter sheet appears.
- [ ] Re-enter the key correctly → Confirm enables. Tap Confirm → chat list appears.
- [ ] Settings → Show recovery key → same key revealed.

### Restore flow (iOS)

- [ ] On a second simulator/device with the same Matrix user, sign in → PostLoginVerificationView appears.
- [ ] Tap "Use recovery key" → enter the key from the first device → Continue → chat list appears, message history decrypts.

### SAS verification (multi-device, iOS)

- [ ] On the second device, instead of recovery key, choose "Verify with another device."
- [ ] Switch to first device — VerificationBanner appears at the top of the chat list.
- [ ] Tap "Verify" on the banner → both devices show emoji compare screen.
- [ ] Confirm match on both → both screens show ✓ Verified.

### Bot verification (iOS)

- [ ] Run `dev-boxer add-bot box-name` on the homeserver — emits a verification request to the user.
- [ ] On Matron iOS, banner appears: "@box-name wants to verify."
- [ ] Tap Verify → emoji compare with the bot's identity (cross-signed at provisioning time).
- [ ] After confirmation, open a chat with that bot — no "unverified device" banner inside the chat.

### Trust posture (iOS)

- [ ] If a bot adds a new device (e.g. dev-boxer reprint), opening that chat shows the inline "unverified device" banner.
- [ ] Tap the in-chat banner → opens SAS view.

### Mac verification chrome

- [ ] Sign in to MatronMac with a fresh user → first-device flow shows `MacRecoveryKeyView`. Key is selectable; Copy button writes to system pasteboard (paste into another app to confirm).
- [ ] Continue → re-entry phase. Type a wrong key → "Doesn't match" warning. Paste the right key (via the Paste button or ⌘V into the field) → auto-advances to the green checkmark and dismisses.
- [ ] Help menu → "Verify This Device…" opens `MacSasView` as a fixed-size sheet (480×400). `Return` confirms; `Esc` cancels.
- [ ] Help menu → "Show Recovery Key…" opens `MacRecoveryKeyView` in restore mode after re-authentication.
- [ ] Trigger a verification request from another device → `MacVerificationBanner` appears above the chat-list sidebar. Click "Verify" → SAS sheet opens. Click ✕ → banner disappears AND the partner device's "waiting" UI cancels (per Task 8 dismiss-cancels-SDK contract).

### iCloud Keychain auto-restore (cross-platform)

- [ ] On an iOS device with iCloud Keychain enabled, complete first-device flow → recovery key stored in iCloud Keychain.
- [ ] On a Mac signed in to the same iCloud account with Keychain sync enabled, install MatronMac, sign in → `MacRecoveryKeyView.restore` mode pre-fills the recovery key from the synced Keychain. Tap "Use saved recovery key" → message history decrypts without re-entry.
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 3 manual test additions (iOS + Mac)"
git push
```

---

## Phase 3 acceptance

1. All tasks (1, 2, 3, 4, 4b, 5, 5c, 6, 7c, 7, 8, 9, 9b, 9c, 10, 11, 12, 13, 14) committed and pushed.
2. CI green on both `Matron` and `MatronMac` schemes.
3. Manual checklist passes for: first-device generate (with re-entry confirmation), second-device restore, multi-device SAS, bot SAS — on both iOS and Mac.
4. Trust posture matches §7.5: nothing auto-trusted, banners surface unverified devices.
5. Banner dismiss cancels the SDK request (verified by `VerificationCenterTests`).
6. Mac Help menu items "Verify This Device…" and "Show Recovery Key…" open the right flows; keyboard shortcuts on `MacSasView` work (`Return` confirms, `Esc` cancels).
7. iCloud Keychain auto-restore works end-to-end (iOS → Mac) per the cross-platform manual test.

After acceptance, write Phase 4 plan.

---

## Plan self-review

- **§7 E2EE & verification:** Recovery (§7.4) → Tasks 3, 5, 5c, 7. SAS (§7.2 Scenario A: show + acknowledge + re-enter to confirm) → Tasks 5, 5c. SAS (§7.2 Scenario B: emoji compare + cancel/approve) → Tasks 4, 4b, 6, 7c, 7, 9, 9b. Bot verification (§7.3) → Tasks 4b, 8, 9, 9b, 10. Trust posture (§7.5) → Task 10. Crypto store sharing (§7.1) was set up in Phase 1 (App Group on iOS; Application Support directory on Mac). Mac entitlements (§7.1, §8.1) → Task 13. What we deliberately don't do (§7.6): identity server, device manager screen, room-key sharing UI, QR — none implemented.
- **§5.2 Onboarding:** Phase 1 had sign-in only. Task 7 here adds the post-login verification screen, completing §5.2.
- **§5.7 In-chat verification banner:** Task 10.
- **§5.9 Mac chrome:** `MacSasView` (Task 7c) is a fixed-size 480×400 sheet with `Return` / `Esc` keyboard shortcuts — not a half-sheet. `MacRecoveryKeyView` (Task 5c) is also a fixed-size sheet with `NSPasteboard`-backed Copy button and paste detection through the `NSPasteboardReading` protocol seam (`PasteDetector` is unit-tested against `FakeNSPasteboard`). `MacVerificationBanner` (Task 9b) renders as a top-of-window banner above the chat-list sidebar.
- **Mac Help menu wire-up (Task 9c):** Phase 2 added Help menu placeholders for "Verify This Device…" and "Show Recovery Key…"; this phase wires them to flows via a `Notification.Name`-based `matronCommand(_:perform:)` view modifier. Verify This Device opens `MacSasView` (or falls back to recovery-key restore if no other device is reachable); Show Recovery Key opens `MacRecoveryKeyView` in re-auth-then-reveal mode.
- **iCloud Keychain auto-restore on Mac:** spec §7.1 + §7.2 Scenario A — recovery key written by iOS via `KeychainStore(synchronizable: true)` (Task 3) auto-syncs through iCloud Keychain so a Mac install picks it up without re-entry. The `KeychainStore` extension for `kSecAttrSynchronizable` items added in Task 3 is the only state shared across platforms; UI flow is identical to iOS, just with a "Use saved recovery key" prefill in `MacRecoveryKeyView.restore` mode.
- **Shared `SessionVerificationControlling`:** Task 4's protocol seam is platform-agnostic — both iOS and Mac apps consume the same `LiveSessionVerificationController` from `MatronShared`. The SDK Client API is identical on both platforms, so there is no platform-specific live impl.
- **Shared ViewModels:** `SasViewModel` and `RecoveryKeyViewModel` live in `MatronShared/Sources/ViewModels/` (Phase 1 reorg) and are imported by both `Matron/Features/Verification/` and `MatronMac/Features/Verification/` via the `MatronViewModels` library product. Each platform owns only its `*View.swift` + tests.
- **Snapshot tests (Task 12):** Mac variants of `MacSasView` (emoji + verified states), `MacRecoveryKeyView` (show / re-enter mismatch / confirmed / restore phases), and `MacVerificationBanner` (in Task 9b) all use the shared `assertVariants(of:named:)` helper from Phase 2, which now does 6 variants (`{iOS, Mac} × {light, dark, accessibility5}`). Mac targets only emit the Mac triple per spec §10 (snapshot tests run against both platforms when the primitive is cross-platform; Mac-only chrome under Mac scheme only).
- **SDK collision:** the matrix-rust-sdk-swift `VerificationState` enum and our DTOs cohabit in `VerificationServiceLive.swift`; the SDK enum is qualified as `MatrixRustSDK.VerificationState` at the listener boundary, and our DTOs live in `VerificationDTOs.swift` (renamed from `VerificationState.swift`) precisely to dodge the name clash.
- **Active flow caching:** Task 4 introduces `activeFlows: [String: SessionVerificationControlling]` in `VerificationServiceLive`, populated from `IncomingVerificationListener.onUpdate` via the `DeviceVerificationRequestObserver` shim (Task 4b). `acceptIncoming` / `confirmEmojiMatch` / `cancel` all look up the controller by request ID; cancel reason is propagated verbatim into the `.cancelled(reason:)` state.
- **Re-entrancy:** `SasViewModel.observe()` is guarded against double-call via `isObserving`, paired with `.task(id: viewModel.requestID)` in both `SasView` and `MacSasView` so re-presentation with the same ID doesn't re-fire.
- **Dismiss-cancels-request:** `VerificationCenter.dismiss(_:)` is async and calls `service.cancel(requestID:reason:)` before removing from `pending`. Test asserts the cancel happens and the reason is `"User dismissed"`. Both `VerificationBanner` and `MacVerificationBanner` route their dismiss action through the same async helper.
- **No stub bodies left.** SDK-API-volatile call sites flagged with "Implementer note: API name varies — verify against SDK version Phase 1 pinned" comments.
