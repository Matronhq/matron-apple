# Devices Screen + Agent Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the app side of matron-journal PR #19's spec: a Devices roster with per-device revoke (self-revoke = sign out) and an "Add agent" pairing modal (code → IP preview → name + approve → wait-for-claim), on both Mac and iOS.

**Architecture:** New `JournalAPI` endpoints + DTOs in `MatronJournal`; two new `@Observable` view models in `MatronViewModels` behind a small `DevicesProviding` protocol seam (so tests fake the network); per-platform SwiftUI on top (Mac Settings tab, iOS Settings push). Everything server-facing follows `docs/superpowers/specs/2026-07-15-app-devices-ui-spec.md` from the matron-journal repo — that spec is the source of truth.

**Tech Stack:** Swift 6 / SwiftUI, XCTest (SPM `MatronShared` suite + MatronMacTests), StubURLProtocol harness for API tests.

## Global Constraints (from the server spec — exact values)

- Timestamps are epoch **milliseconds**. `last_seen_at: null` renders as "Never".
- Roster sort: clients first, then agents, each newest-first (`created_at` desc).
- `is_self` row badge: "This device". Self-revoke confirm copy: "Sign out this device?" — on 200 drop credentials → login.
- Revoke 404 (`not_found`) = already gone → treat as success and re-fetch.
- Refresh on screen enter and after every mutation. Pull-based — no push signal exists.
- Pair codes: 8 chars, alphabet `0123456789BCDFGHJKMNPQRSTVWXYZ`, displayed `XXXX-XXXX`. Accept sloppy input: normalize = uppercase + strip every non-alphanumeric. Type-only (no QR) in v1.
- **Preview before approve is mandatory** (anti-phish): show `requester_ip` before the approve button is available. Copy: "A device at **{ip}** is asking to connect as an agent on your account. Only approve if this is your machine — check the code on its terminal."
- `expires_in` seconds → countdown; on expiry disable approve, ask for a fresh code.
- Preview/approve 404 copy: "Code not recognized or expired. Get a fresh code from the box and try again."
- Approve 409 copy: "This code was already approved."
- `agent_name` is not renameable later — say so next to the field. Duplicate names legal → inline warning "You already have an agent called {name}" but allow.
- Wait-for-claim: poll `GET /devices` every 2–3s, capped at the pair's remaining TTL; detect the new agent **by `device_id` snapshot diff** (agent kind, id not in pre-approve snapshot), never by name. Timeout copy: "The box never collected its token. Start again with a fresh code." Wait is dismissible.
- Error envelope: `{ "error": "snake_case_code" }`; 401 → unauthenticated, 409 → conflict (new `JournalAPIError` case).

---

### Task 1: JournalAPI endpoints + DTOs

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift`
- Test: `MatronShared/Tests/JournalTests/JournalAPITests.swift`

**Produces (exact interfaces):**
```swift
public struct DeviceDTO: Equatable, Sendable, Identifiable {
    public let id: Int64            // device_id
    public let kind: String         // "client" | "agent"
    public let name: String
    public let createdAt: Int64     // ms
    public let cursor: Int64
    public let lag: Int64
    public let lastSeenAt: Int64?   // ms, nil = never connected
    public let isSelf: Bool
}
public struct PairPreview: Equatable, Sendable {
    public let requesterIP: String
    public let expiresIn: Int       // seconds
}
// JournalAPIError gains: case conflict   (409, any code)
public func devices() async throws -> [DeviceDTO]                    // GET /devices
public func revokeDevice(id: Int64) async throws                     // POST /devices/:id/revoke
public func pairPreview(code: String) async throws -> PairPreview    // POST /pair/preview {pair_code}
public func pairApprove(code: String, agentName: String) async throws // POST /pair/approve {pair_code, agent_name}
```

- [ ] Failing tests first (StubURLProtocol): decode roster incl. `last_seen_at: null` + `is_self`; revoke posts to `/devices/7/revoke`; preview body carries `pair_code`; approve 409 → `.conflict`; 404 → `.notFound`.
- [ ] Implement; `cd MatronShared && swift test` green; commit.

### Task 2: PairingCode helper

**Files:**
- Create: `MatronShared/Sources/Journal/PairingCode.swift`
- Test: `MatronShared/Tests/JournalTests/PairingCodeTests.swift`

**Produces:**
```swift
public enum PairingCode {
    public static let length = 8
    public static func normalize(_ raw: String) -> String   // uppercase, strip non-alphanumerics
    public static func display(_ raw: String) -> String     // "KTNM3VQ8" -> "KTNM-3VQ8" (partial input safe)
    public static func isPlausible(_ raw: String) -> Bool   // normalized length == 8
}
```

- [ ] Tests: `"ktnm-3vq8 "` → `KTNM3VQ8`; display partial `"ktn"` → `KTN`; 8-char plausibility; commit with implementation.

### Task 3: DevicesViewModel

**Files:**
- Create: `MatronShared/Sources/ViewModels/DevicesViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/DevicesViewModelTests.swift`

**Produces:**
```swift
public protocol DevicesProviding: Sendable {
    func devices() async throws -> [DeviceDTO]
    func revokeDevice(id: Int64) async throws
    func pairPreview(code: String) async throws -> PairPreview
    func pairApprove(code: String, agentName: String) async throws
}
extension JournalAPI: DevicesProviding {}   // already matches

@Observable @MainActor public final class DevicesViewModel {
    public private(set) var devices: [DeviceDTO]   // sorted: clients first, newest-first
    public private(set) var isLoading: Bool
    public private(set) var errorMessage: String?
    public init(api: any DevicesProviding, onSelfRevoked: @escaping () -> Void)
    public func refresh() async
    public func revoke(_ device: DeviceDTO) async   // 404 == success; self → onSelfRevoked(), others → refresh()
}
```

- [ ] Tests (fake `DevicesProviding`): sort order; revoke other → API hit + refetch; revoke 404 → no error + refetch; revoke self → `onSelfRevoked` fired, no refetch of a dead token; error surfaces `errorMessage`.
- [ ] Implement; suite green; commit.

### Task 4: PairingViewModel

**Files:**
- Create: `MatronShared/Sources/ViewModels/PairingViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/PairingViewModelTests.swift`

**Produces:**
```swift
@Observable @MainActor public final class PairingViewModel {
    public enum Phase: Equatable {
        case enterCode
        case preview(requesterIP: String)
        case waitingForClaim
        case success(agentName: String)
    }
    public var codeInput: String { didSet }   // auto-format via PairingCode.display; plausible → schedule preview
    public var agentName: String
    public private(set) var phase: Phase
    public private(set) var errorMessage: String?
    public private(set) var expiresAt: Date?          // approve disabled past this
    public var duplicateNameWarning: String?          // vs. existingNames
    public init(api: any DevicesProviding, existingNames: [String],
                now: @escaping () -> Date = Date.init,
                pollInterval: Duration = .seconds(2.5),
                previewDebounce: Duration = .milliseconds(300))
    public func approve() async    // snapshot ids → approve → poll loop capped at expiresAt
    public func cancelWaiting()
}
```

- Preview task: debounced on codeInput change, cancels prior, only when `isPlausible`; 404 → spec copy; success → `.preview(ip)` + `expiresAt = now() + expires_in`.
- Approve: snapshot `Set(device_id)` via `api.devices()` immediately before `pairApprove`; 409/404 → spec copy; success → `.waitingForClaim` + poll until new agent-kind id appears (→ `.success(name:)` with the server row's name) or `now() > expiresAt` (→ back to `.preview` with timeout copy).

- [ ] Tests (fake provider + injected `now`/near-zero intervals): normalization/format on input; debounce cancels stale previews; preview 404 copy; approve 409 copy; claim detected by id diff even when a pre-existing device shares the chosen name; TTL timeout copy; `cancelWaiting` stops the loop.
- [ ] Implement; suite green; commit.

### Task 5: Mac UI — Settings gets a Devices tab

**Files:**
- Modify: `MatronMac/App/MatronMacApp.swift` (Settings scene → `TabView`)
- Modify: `MatronMac/Features/Settings/MacDeviceSettingsView.swift` (unchanged content, becomes the General tab)
- Create: `MatronMac/Features/Settings/MacDevicesView.swift` (roster + revoke confirms + Add Agent sheet)
- Create: `MatronMac/Features/Settings/MacAddAgentSheet.swift` (pairing modal driving `PairingViewModel`)
- Modify: `MatronMac/App/AppDependencies.swift` + iOS `Matron/App/AppDependencies.swift`: add `func devicesService(for session: UserSession) -> any DevicesProviding { core(for: session).api }`

Roster row: name + kind icon (`laptopcomputer` client / `terminal` agent), "This device" badge, relative last-seen ("Never" when nil), lag ("Up to date" / "N events behind"), Revoke button → `confirmationDialog` ("Revoke 'name'?" / self: "Sign out this device?"). Refresh `.task` on appear + after sheet dismiss. Self-revoke success → existing `signOut(activeSession:)`.

- [ ] Build + `xcodegen generate` for new files; `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test … MatronMacTests` green (assert exact count); commit.

### Task 6: iOS UI — Devices from Settings

**Files:**
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (add `Section("Devices") { NavigationLink }` + pass-throughs)
- Create: `Matron/Features/Settings/DevicesView.swift` (roster; same behaviors as Mac, `.refreshable`)
- Create: `Matron/Features/Settings/AddAgentSheet.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift` (sheet passes `deps`/`session`/`onSignOut` into `DeviceSettingsView`)

- [ ] iOS build (`xcodebuild build -scheme Matron -destination 'generic/platform=iOS'` or sim) green; commit.

### Task 7: Full suites + PR + installs

- [ ] `cd MatronShared && swift test` — assert "Executed N tests … 0 failures" (N ≥ 601 + new).
- [ ] Mac tests (exact count), Mac ad-hoc build AFTER tests, install to /Applications, dylib hash verify.
- [ ] iOS build + install to Dan's iPhone (devicectl), since this feature is iOS-visible.
- [ ] Push branch `feat/devices-pairing`, PR referencing the journal spec, monitor, Bugbot loop, merge.

## Self-review notes
- Spec coverage: roster (§1), revoke incl. self/404 (§2), code entry (§3a), mandatory preview + IP + countdown (§3b), name + approve + duplicate warn + 409 (§3c), wait-for-claim by id snapshot + TTL + dismissible (§3d), error table (conflict case added).
- Out of scope per spec: QR scanning, rename, un-approve, presence, `app-start`/`recent-folders`.
- 401 routing to login already exists app-wide via sync; Devices surfaces its own errors inline otherwise.
