# Phase 3 — E2EE & Verification UX: Progress

This file tracks Phase 3 implementation progress.

**Plan:** `docs/superpowers/plans/2026-05-02-matron-ios-phase-3-e2ee-verification.md`

**Branch:** `phase-3-e2ee-verification` (stacked on `phase-2-chat-experience`)

## Status

Started 2026-05-03. Stacked on Phase 2 to overlap iteration with Phase 2 review.

## Phase 1 + 2 lessons that apply

- `AuthServiceLive(sessionStore:, basePath:)` constructor (not `keychain:`).
- `StoragePaths.groupContainer` etc. are `URL?` on iOS; macOS `appSupport` is non-optional.
- `ChatService.chatSummaries()` and `TimelineService.items()` return `AsyncThrowingStream`.
- `AppDependencies` splits container into `sdk-store/` (SDK) + `sessions/` (FileSessionStore).
- `slidingSyncVersionBuilder(versionBuilder: .native)` is REQUIRED on every `ClientBuilder()`.
- v26 SDK Room API: `displayName()` / `heroes()` / `latestEvent()` / `roomInfo()` (no `name()` / `activeMembersIds()` etc.).
- Swift 6 strict concurrency: no `@MainActor` `deinit` accessing isolated properties — expose `cancel()` / `stop()` and call from `View.onDisappear`.
- `MatronTests` and `MatronMacTests` are **not** standalone xcodebuild schemes — they're testables of `Matron` / `MatronMac` schemes. Use `xcodebuild test -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'`.
- iOS Simulator: `iPhone 17` (not 15 — Xcode 26 dropped iPhone 15).
- `MatronShared` exposes 7 library products (MatronAuth, MatronChat, MatronModels, MatronStorage, MatronSync, MatronViewModels, MatronDesignSystem). XcodeGen needs explicit per-product `package: MatronShared, product: <name>` declarations. If Phase 3 adds `MatronVerification`, add to Package.swift libraries AND to project.yml dependencies on both Matron + MatronMac targets.
- `Pasteboard.copy(_:)` is public in `MatronDesignSystem` — useful for the recovery-key copy button.
- `MatronStorage.LRUCache` is generic + public if Phase 3 needs bounded caches.
- `MatronCommand` enum (Mac) + `Notification.Name.matronCommand(_:)` exist for menu commands. `Verify Device…` and `Show Recovery Key…` slots may already be present in `Commands.swift`.
- iOS Simulator can't use Keychain without a signing team (Phase 1 deferred this; FileSessionStore is the workaround). If Phase 3 wires keychain-access-groups, expect the iOS simulator to hit `errSecMissingEntitlement -34018`.

## Tasks

See plan for canonical list. Updates land here per push.

- [x] **Task 1 — Verification DTOs** (2026-05-03). `DeviceInfo`, `DeviceTrustLevel`, `SasFlowState`, `SasEmoji`, `VerificationRequestSummary` in `MatronShared/Sources/Verification/VerificationDTOs.swift`. 5 unit tests in `Tests/VerificationTests/VerificationDTOsTests.swift`. **Plan deviation:** added the `MatronVerification` SPM library product + target in this commit (plan defers to Task 2 step 3) so the DTO file is reachable from a target and the commit can build/test in isolation. Wired the new product into both apps and both test targets in `project.yml`. SPM total: 150 tests (was 145). iOS scheme: 27. Mac scheme: 25. All green.
- [x] **Task 2 — `VerificationService` protocol + `FakeVerificationService`** (2026-05-03). Protocol in `MatronShared/Sources/Verification/VerificationService.swift`. Test fake `FakeVerificationService` (actor) + 6 protocol-shape tests in `Tests/VerificationTests/`. **Plan deviation:** test imports `MatronVerification` (not `MatronAuth` as the plan wrote) since Task 1 created the `MatronVerification` SPM target. Also tightened the fake's `actor` design: confirm/cancel mutate isolated state; `nonisolated` stream constructors hop back via `Task { await self.recordStart(...) }`. The plan's `var didCallStart` directly on the actor was fine, but I added `private(set)` so callers can observe state without mutating it. SPM total: 156 (was 150). iOS scheme: 27. Mac scheme: 25.
- [x] **Task 3 — `RecoveryKeyManager` + iCloud-syncable `KeychainStore`** (2026-05-03). Manager in `MatronShared/Sources/Verification/RecoveryKeyManager.swift`; `KeychainStore` extended with `synchronizable: Bool = false` (default preserves existing behaviour). 4 new tests (1 KeychainStore + 3 RecoveryKeyManager). **Plan deviations:**
  - SDK signature: plan calls `enableRecovery(waitForBackupsToUpload:progressListener:)` with `progressListener: nil`. Actual v26.04.01 signature is `enableRecovery(waitForBackupsToUpload:passphrase:progressListener:)` where `progressListener` is **non-optional** (`EnableRecoveryProgressListener`). Fixed by passing `passphrase: nil` and a private `NoopEnableRecoveryProgressListener`. UI-side progress reporting is deferred to the recovery-key view in a later task.
  - Test scope: plan only ships a `KeychainStoreTests` extension. I added `RecoveryKeyManagerTests` covering `currentKey()` round-trip + `storageKey` stability — the SDK-bound paths (`generateAndPersist`, `restore`) require a live `Client` so they're integration-tested in Phase 7. Manager exposes `storageKey` as `public static let` so tests (and a future migration) can reference it without a magic string.
  - Synchronizable test gating: the synchronizable round-trip half needs an iCloud Keychain entitlement that the SPM `swift test` host (and iOS Simulator) don't have. Probed: `SecItemAdd` returns `errSecMissingEntitlement (-34018)`. Test catches that specific status and `throw XCTSkip(...)`. Real-device coverage lands in Phase 7.
  - SPM total: 160 (was 156, +1 skipped). iOS scheme: 27. Mac scheme: 25.
- [x] **Task 4 — `VerificationServiceLive` + `SessionVerificationControlling`** (2026-05-03). Live impl in `MatronShared/Sources/Verification/VerificationServiceLive.swift`; protocol seam in `SessionVerificationControlling.swift`; `FakeSessionVerificationController` + 6 unit tests in `Tests/VerificationTests/`. **Plan deviations:**
  - Concurrency: plan stores `activeFlows` + `activeContinuations` behind an `NSLock` on the class. Swift 6 strict-concurrency rejects `NSLock.lock()` from async contexts. Switched to a private `actor FlowStore` inside `VerificationServiceLive`; class stays `@unchecked Sendable` because all mutation hops through the actor. Same trick on `FakeSessionVerificationController` — internal `actor Recorder` instead of NSLock-guarded bools.
  - Test-only init: tests call `VerificationServiceLive()` with no args. Added an internal no-arg init that leaves `provider`/`session` as `nil`; SDK-bound surfaces (`isThisDeviceVerified`, `incomingRequests`, `startSAS`) throw `.notConfigured` / yield empty under that init. Production callers use the public `init(provider:session:)`.
  - SDK signatures: plan calls `client.encryption().isVerified()` (doesn't exist on `Encryption`; `isVerified()` is on `UserIdentity`). Real v26 path: `client.encryption().verificationState() == .verified`. `requestSelfVerification()` also doesn't exist — replaced with `client.getSessionVerificationController()` then `requestDeviceVerification()` / `requestUserVerification(userId:)`. The plan's `IncomingVerificationListener: VerificationStateListener` is also wrong (that listener is for global state, not incoming requests) — actual incoming requests come via `SessionVerificationControllerDelegate.didReceiveVerificationRequest`. Wiring of the delegate is deferred to Task 4b's observer; `incomingRequests()` finishes empty for now.
  - SPM total: 166 (was 160). iOS scheme: 27. Mac scheme: 25.
- [x] **Task 4b — `DeviceVerificationRequestObserver`** (2026-05-03). Observer + `IncomingVerificationListening` protocol in `MatronShared/Sources/Verification/DeviceVerificationRequestObserver.swift`; production `LiveSessionVerificationDelegate` adapter alongside; `FakeIncomingVerificationListener` + 3 tests in `Tests/VerificationTests/DeviceVerificationRequestObserverTests.swift`. **Plan deviations:**
  - SDK delegate shape: plan extracts `(requestID, otherUserID, otherDeviceID, sdkController)` from a custom `onIncomingVerificationRequest` callback. v26.04.01's actual surface is `SessionVerificationControllerDelegate.didReceiveVerificationRequest(details: SessionVerificationRequestDetails)` — `details` carries `flowId`, `senderProfile.userId`, `deviceId` (non-optional), `deviceDisplayName`. The SDK doesn't hand back a per-request controller; the same `SessionVerificationController` is reused, so `LiveSessionVerificationDelegate` wraps the shared SDK controller in `LiveSessionVerificationController` and forwards. The remaining delegate callbacks (`didStartSasVerification`, `didReceiveVerificationData`, `didFinish`, `didCancel`, `didFail`) are no-ops in this commit — wiring them into the open SAS continuation will land with the SAS-state listener task; this commit stays scoped to the request-arrival adapter.
  - Test fake recording: plan's recorder pattern (an unguarded array on a fake) trips Swift 6 strict-concurrency. Switched `FakeIncomingVerificationListener` to an `NSLock`-guarded buffer accessed synchronously from `onUpdate` — keeps tests synchronous (no actor flush dance) since the protocol's `onUpdate` is itself synchronous.
  - SPM total: 169 (was 166). iOS scheme: 27. Mac scheme: 25.
