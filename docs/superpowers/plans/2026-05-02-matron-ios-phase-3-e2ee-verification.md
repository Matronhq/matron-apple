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
│   ├── VerificationService.swift                NEW
│   ├── VerificationServiceLive.swift            NEW
│   ├── VerificationState.swift                  NEW — DTO
│   ├── RecoveryKeyManager.swift                 NEW — generate/store/restore
│   └── DeviceVerificationRequestObserver.swift  NEW
├── Matron/Features/Verification/
│   ├── RecoveryKeyView.swift                    NEW
│   ├── RecoveryKeyViewModel.swift               NEW
│   ├── SasView.swift                            NEW
│   ├── SasViewModel.swift                       NEW
│   ├── VerificationBanner.swift                 NEW — top-of-list overlay
│   └── VerificationCenter.swift                 NEW — orchestrates incoming requests
├── Matron/Features/Onboarding/
│   └── PostLoginVerificationView.swift          NEW — second onboarding step
├── Matron/Features/Settings/
│   └── DeviceSettingsView.swift                 NEW — minimal device info + recovery reveal
├── MatronTests/
│   ├── VerificationServiceFakeTests.swift       NEW
│   ├── RecoveryKeyViewModelTests.swift          NEW
│   └── SasViewModelTests.swift                  NEW
```

---

## Tasks

### Task 1: VerificationState DTO

**Files:**
- Create: `MatronShared/Sources/Verification/VerificationState.swift`

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
git add MatronShared/Sources/Verification/VerificationState.swift
git commit -m "feat: VerificationState DTOs (DeviceInfo, SasFlowState, SasEmoji, RequestSummary)"
git push
```

---

### Task 2: VerificationService protocol

**Files:**
- Create: `MatronShared/Sources/Verification/VerificationService.swift`
- Create: `MatronShared/Tests/AuthTests/VerificationServiceFakeTests.swift`

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

- [ ] **Step 1: Implement**

```swift
import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

public final class VerificationServiceLive: VerificationService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private var activeFlows: [String: AnyObject] = [:]

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
                    let listener = IncomingVerificationListener(continuation: continuation)
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
        // Look up the request by id (cached from incomingRequests), accept, start SAS, stream states.
        // Implementer: maintain a cache `[requestID: SDKVerificationRequest]` populated by IncomingVerificationListener.
        AsyncStream { $0.finish() }
    }

    public func confirmEmojiMatch(requestID: String) async throws {
        // Look up cached request, call confirm() on its SAS verification.
    }

    public func cancel(requestID: String, reason: String) async throws {
        // Look up cached request, call cancel().
    }
}

private final class IncomingVerificationListener: VerificationStateListener {
    let continuation: AsyncStream<VerificationRequestSummary>.Continuation
    init(continuation: AsyncStream<VerificationRequestSummary>.Continuation) {
        self.continuation = continuation
    }
    func onUpdate(state: VerificationState) {
        // Map SDK enum to summaries when there's a pending request. Adjust per SDK version.
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

> **Implementer notes:** the verification API in matrix-rust-components-swift has been one of the more volatile surfaces. Expect to spend an afternoon mapping methods. The protocol shape is what matters — it isolates the SDK churn from the UI.

- [ ] **Step 2: Commit**

```bash
git add MatronShared/Sources/Verification/VerificationServiceLive.swift
git commit -m "feat: VerificationServiceLive skeleton wrapping SDK SAS flows"
git push
```

---

### Task 5: RecoveryKeyViewModel + RecoveryKeyView (first-device flow)

**Files:**
- Create: `Matron/Features/Verification/RecoveryKeyViewModel.swift`
- Create: `Matron/Features/Verification/RecoveryKeyView.swift`
- Create: `MatronTests/RecoveryKeyViewModelTests.swift`

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
    func test_generate_setsGeneratedKey() async {
        let fake = FakeRecoveryKeyManager()
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { try await fake.generateAndPersist() }, restore: { _ in })
        await vm.generate()
        XCTAssertEqual(vm.generatedKey, "MOCK-RECOVERY-KEY-1234-5678")
        XCTAssertEqual(fake.generatedCount, 1)
    }

    @MainActor
    func test_confirm_requiresUserAcknowledgment() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "K"
        XCTAssertFalse(vm.canFinish)
        vm.userAcknowledgedSaved = true
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

    let mode: Mode
    var generatedKey: String?
    var enteredKey: String = ""
    var userAcknowledgedSaved: Bool = false
    var phase: Phase = .idle

    private let generate: () async throws -> String
    private let restore: (String) async throws -> Void

    init(mode: Mode, generate: @escaping () async throws -> String, restore: @escaping (String) async throws -> Void) {
        self.mode = mode
        self.generate = generate
        self.restore = restore
    }

    var canFinish: Bool {
        switch mode {
        case .generate: return generatedKey != nil && userAcknowledgedSaved
        case .restore:  return !enteredKey.isEmpty
        }
    }

    func generate() async {
        phase = .busy
        do {
            generatedKey = try await generate()
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
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

- [ ] **Step 3: Implement view**

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
            Button("Continue") { onFinished() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canFinish)
        }
        .padding()
        .navigationTitle("Recovery key")
    }

    @ViewBuilder
    private var generateBody: some View {
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

- [ ] **Step 4: Commit**

```bash
git add Matron/Features/Verification/RecoveryKeyView.swift \
        Matron/Features/Verification/RecoveryKeyViewModel.swift \
        MatronTests/RecoveryKeyViewModelTests.swift
git commit -m "feat: RecoveryKeyView for generate + restore flows"
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
        let vm = SasViewModel(stream: stream, confirm: {}, cancel: { _ in })
        await vm.observe()
        XCTAssertEqual(vm.state, .verified)
    }

    @MainActor
    func test_confirm_invokesCallback() async {
        var confirmed = false
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, confirm: { confirmed = true }, cancel: { _ in })
        await vm.confirm()
        XCTAssertTrue(confirmed)
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
    private let stream: AsyncStream<SasFlowState>
    private let confirmAction: () async throws -> Void
    private let cancelAction: (String) async throws -> Void

    init(
        stream: AsyncStream<SasFlowState>,
        confirm: @escaping () async throws -> Void,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.stream = stream
        self.confirmAction = confirm
        self.cancelAction = cancel
    }

    func observe() async {
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
        .task { await viewModel.observe() }
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
                    let stream = svc.startSAS(withUser: session.userID, deviceID: nil)
                    SasView(viewModel: SasViewModel(
                        stream: stream,
                        confirm: { /* implement once acceptIncoming + confirmEmojiMatch are wired */ },
                        cancel: { _ in }
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

- [ ] **Step 1: Implement**

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

    func dismiss(_ requestID: String) {
        pending.removeAll { $0.id == requestID }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Matron/Features/Verification/VerificationCenter.swift
git commit -m "feat: VerificationCenter to surface pending requests app-wide"
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

In `ChatListView`, hold a `@State var verificationCenter: VerificationCenter` and a `@State var sasSummary: VerificationRequestSummary?`. Above the `List`, render a `ForEach(verificationCenter.pending)` of `VerificationBanner`s. Tap → set `sasSummary` → `.sheet(item: $sasSummary)` presents a `SasView`.

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

1. All 12 tasks committed and pushed.
2. CI green.
3. Manual checklist passes for: first-device generate, second-device restore, multi-device SAS, bot SAS.
4. Trust posture matches §7.5: nothing auto-trusted, banners surface unverified devices.

After acceptance, write Phase 4 plan.

---

## Plan self-review

- **§7 E2EE & verification:** Recovery (§7.4) → Tasks 3, 5, 7. SAS (§7.2) → Tasks 4, 6, 7, 9. Bot verification (§7.3) → Tasks 8, 9, 10. Trust posture (§7.5) → Task 10. Crypto store sharing (§7.1) was set up in Phase 1 (App Group). What we deliberately don't do (§7.6): identity server, device manager screen, room-key sharing UI, QR — none implemented.
- **§5.2 Onboarding:** Phase 1 had sign-in only. Task 7 here adds the post-login verification screen, completing §5.2.
- **§5.7 In-chat verification banner:** Task 10.
- No placeholders. SDK-API-volatile call sites flagged for the implementer.
