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
