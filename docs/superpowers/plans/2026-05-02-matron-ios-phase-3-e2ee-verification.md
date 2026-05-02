# Matron iOS — Phase 3 (E2EE & Verification UX) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 2 (Chat experience) merged and CI green.

**Goal:** Wire the encryption UX. After Phase 3, users can: (a) generate + save a recovery key on first device, (b) verify a new device via SAS with another device, (c) verify each bot via SAS, (d) restore from recovery key on a fresh install. Banners surface verification state and link into the right flow.

**Architecture:** New `VerificationService` in `MatronShared` wraps the SDK's verification machinery. UI flows live in `Matron/Features/Verification/`. Two screens: `RecoveryKeyView` (show/save/restore) and `SasView` (emoji compare). Banners are SwiftUI overlays driven by a top-level `VerificationStateObserver`. Trust posture from spec §7.5: nothing auto-trusted.

**Tech Stack:** Same as Phase 2. No new third-party deps — matrix-rust-sdk-swift exposes the verification primitives natively.

**Reference:** Spec §7 (E2EE), §5.7 (verification banner UX).

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
├── Matron/Features/Verification/
│   ├── RecoveryKeyView.swift                           NEW
│   ├── RecoveryKeyViewModel.swift                      NEW
│   ├── SasView.swift                                   NEW
│   ├── SasViewModel.swift                              NEW
│   ├── VerificationBanner.swift                        NEW — top-of-list overlay
│   └── VerificationCenter.swift                        NEW — orchestrates incoming requests, cancels on dismiss
├── Matron/Features/Onboarding/
│   └── PostLoginVerificationView.swift                 NEW — second onboarding step
├── Matron/Features/Settings/
│   └── DeviceSettingsView.swift                        NEW — minimal device info + recovery reveal
├── MatronTests/
│   ├── RecoveryKeyViewModelTests.swift                 NEW
│   ├── SasViewModelTests.swift                         NEW
│   └── VerificationCenterTests.swift                   NEW
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

### Task 5: RecoveryKeyViewModel + RecoveryKeyView (first-device flow)

**Files:**
- Create: `Matron/Features/Verification/RecoveryKeyViewModel.swift`
- Create: `Matron/Features/Verification/RecoveryKeyView.swift`
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
        Matron/Features/Verification/RecoveryKeyViewModel.swift \
        MatronTests/RecoveryKeyViewModelTests.swift
git commit -m "feat: RecoveryKeyView with show + re-enter + confirm phases"
git push
```

---

### Task 6: SasViewModel + SasView

**Files:**
- Create: `Matron/Features/Verification/SasViewModel.swift`
- Create: `Matron/Features/Verification/SasView.swift`
- Create: `MatronTests/SasViewModelTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import Matron
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
git add Matron/Features/Verification/SasView.swift Matron/Features/Verification/SasViewModel.swift \
        MatronTests/SasViewModelTests.swift
git commit -m "feat: SasView for emoji-compare verification"
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

### Task 12: Manual test additions

Append to `manual-tests.md`:

```markdown
## Phase 3 (E2EE & Verification UX)

### First-device flow

- [ ] Fresh install, sign in → PostLoginVerificationView appears.
- [ ] Tap "This is my first device" → recovery key generated and shown.
- [ ] Toggle "I've saved this key" → Continue is enabled. Tap Continue → chat list appears.
- [ ] Settings → Show recovery key → same key revealed.

### Restore flow

- [ ] On a second simulator/device with the same Matrix user, sign in → PostLoginVerificationView appears.
- [ ] Tap "Use recovery key" → enter the key from the first device → Continue → chat list appears, message history decrypts.

### SAS verification (multi-device)

- [ ] On the second device, instead of recovery key, choose "Verify with another device."
- [ ] Switch to first device — VerificationBanner appears at the top of the chat list.
- [ ] Tap "Verify" on the banner → both devices show emoji compare screen.
- [ ] Confirm match on both → both screens show ✓ Verified.

### Bot verification

- [ ] Run `dev-boxer add-bot box-name` on the homeserver — emits a verification request to the user.
- [ ] On Matron iOS, banner appears: "@box-name wants to verify."
- [ ] Tap Verify → emoji compare with the bot's identity (cross-signed at provisioning time).
- [ ] After confirmation, open a chat with that bot — no "unverified device" banner inside the chat.

### Trust posture

- [ ] If a bot adds a new device (e.g. dev-boxer reprint), opening that chat shows the inline "unverified device" banner.
- [ ] Tap the in-chat banner → opens SAS view.
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 3 manual test additions"
git push
```

---

## Phase 3 acceptance

1. All 13 tasks (1, 2, 3, 4, 4b, 5, 6, 7, 8, 9, 10, 11, 12) committed and pushed.
2. CI green.
3. Manual checklist passes for: first-device generate (with re-entry confirmation), second-device restore, multi-device SAS, bot SAS.
4. Trust posture matches §7.5: nothing auto-trusted, banners surface unverified devices.
5. Banner dismiss cancels the SDK request (verified by `VerificationCenterTests`).

After acceptance, write Phase 4 plan.

---

## Plan self-review

- **§7 E2EE & verification:** Recovery (§7.4) → Tasks 3, 5, 7. SAS (§7.2 Scenario A: show + acknowledge + re-enter to confirm) → Task 5. SAS (§7.2 Scenario B: emoji compare + cancel/approve) → Tasks 4, 4b, 6, 7, 9. Bot verification (§7.3) → Tasks 4b, 8, 9, 10. Trust posture (§7.5) → Task 10. Crypto store sharing (§7.1) was set up in Phase 1 (App Group). What we deliberately don't do (§7.6): identity server, device manager screen, room-key sharing UI, QR — none implemented.
- **§5.2 Onboarding:** Phase 1 had sign-in only. Task 7 here adds the post-login verification screen, completing §5.2.
- **§5.7 In-chat verification banner:** Task 10.
- **SDK collision:** the matrix-rust-sdk-swift `VerificationState` enum and our DTOs cohabit in `VerificationServiceLive.swift`; the SDK enum is qualified as `MatrixRustSDK.VerificationState` at the listener boundary, and our DTOs live in `VerificationDTOs.swift` (renamed from `VerificationState.swift`) precisely to dodge the name clash.
- **Active flow caching:** Task 4 introduces `activeFlows: [String: SessionVerificationControlling]` in `VerificationServiceLive`, populated from `IncomingVerificationListener.onUpdate` via the `DeviceVerificationRequestObserver` shim (Task 4b). `acceptIncoming` / `confirmEmojiMatch` / `cancel` all look up the controller by request ID; cancel reason is propagated verbatim into the `.cancelled(reason:)` state.
- **Re-entrancy:** `SasViewModel.observe()` is guarded against double-call via `isObserving`, paired with `.task(id: viewModel.requestID)` in `SasView` so re-presentation with the same ID doesn't re-fire.
- **Dismiss-cancels-request:** `VerificationCenter.dismiss(_:)` is async and calls `service.cancel(requestID:reason:)` before removing from `pending`. Test asserts the cancel happens and the reason is `"User dismissed"`.
- **No stub bodies left.** SDK-API-volatile call sites flagged with "Implementer note: API name varies — verify against SDK version Phase 1 pinned" comments.
