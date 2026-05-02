# Matron (iOS + Mac) — Phase 7 (Polish & App Store Readiness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 6 (Search) merged and CI green.

**Goal:** Take **both apps (Matron iOS + MatronMac)** from feature-complete to App Store-submittable. Build out the full Settings screens (iOS list + Mac TabView Preferences scene), finish the Bot Profile screen, do a design system pass (colours, typography, spacing tokens) **enforced across both apps**, accessibility audit, app icons (iOS + Mac sets) + launch screen, App Store assets (screenshots, descriptions, privacy policy, App Privacy disclosures) **for both App Store Connect records**, TestFlight + Mac App Store setup, and final QA pass.

**Architecture:** Mostly UI + assets work. The DesignSystem module already lives in `MatronShared/Sources/DesignSystem/` (placed there in Phase 1's reorg) — Phase 7 just declares the canonical semantic tokens there and enforces token usage on **both** the iOS and Mac feature sets. A `PrivacyPolicy` markdown lives in `Resources/`. App Store Connect setup happens externally with copy/screenshots committed in `docs/app-store/` (per-platform sub-folders).

**Tech Stack:** Same as prior phases. No new code dependencies.

**Reference:** Spec §3 (module structure — DesignSystem in MatronShared, Mac icon set 16/32/.../1024), §5.5 (bot profile), §5.6 (settings), §5.9 (Mac chrome — Settings scene, ⌘ shortcuts, drag-and-drop), §10 (testing strategy — two-platform integration test, three-section manual checklist), §12 (license & legal — App Privacy disclosures, two App Store Connect records, encryption export compliance for both binaries).

---

## File structure (Phase 7 deliverables)

```
matron-iOS-app/
├── Matron/Features/Settings/
│   ├── SettingsView.swift                  NEW — iOS list-of-sections shape
│   ├── SettingsViewModel.swift             NEW (lives in MatronShared/Sources/ViewModels/, shared with Mac)
│   ├── AccountSettingsView.swift           NEW
│   ├── NotificationSettingsView.swift      NEW
│   ├── ServerSettingsView.swift            NEW
│   ├── AboutView.swift                     NEW
│   └── LicensesView.swift                  NEW
├── Matron/Features/BotProfile/
│   └── BotProfileView.swift                MODIFIED — full styling, avatar fetch
├── MatronMac/Features/Settings/
│   └── MacSettingsView.swift               NEW — TabView for Settings { } Preferences scene (Task 4b)
├── MatronShared/Sources/DesignSystem/
│   ├── Colors.swift                        MODIFIED — semantic tokens, dark mode
│   ├── Typography.swift                    MODIFIED — type ramp
│   ├── Spacing.swift                       NEW — spacing tokens
│   └── ButtonStyles.swift                  NEW — primary / secondary / destructive
├── MatronShared/Sources/ViewModels/
│   └── SettingsViewModel.swift             NEW — shared by iOS SettingsView + MacSettingsView
├── Matron/Resources/
│   ├── Assets.xcassets/AppIcon.appiconset  NEW — full iOS icon set
│   ├── Assets.xcassets/AccentColor         MODIFIED
│   ├── Info.plist                          MODIFIED — MatronPrivacyPolicyURL, ITSAppUsesNonExemptEncryption=NO
│   ├── PrivacyPolicy.md                    NEW
│   └── Acknowledgements.plist              NEW — generated SPM license list
├── MatronMac/Resources/
│   ├── Assets.xcassets/AppIcon.appiconset  NEW — full Mac icon set (16/32/64/128/256/512/1024 @1x+@2x)
│   ├── Assets.xcassets/AccentColor         MODIFIED — same brand colour as iOS
│   ├── Info.plist                          MODIFIED — MatronPrivacyPolicyURL, ITSAppUsesNonExemptEncryption=NO
│   └── Acknowledgements.plist              NEW — same generated plist (or shared bundle resource)
├── docs/app-store/
│   ├── icon-source.svg                     NEW — single 1024×1024 vector master, drives both icon sets
│   ├── description-en.md                   NEW — listing copy (one set, used by both records)
│   ├── promotional-text.md                 NEW
│   ├── keywords.txt                        NEW
│   ├── screenshots/
│   │   ├── ios/                            NEW — 6.7" / 6.5" / 5.5" sets
│   │   └── mac/                            NEW — 1280×800 / 1440×900 / 2560×1600 / 2880×1800
│   ├── privacy-policy.md                   NEW — public version (one URL serves both apps)
│   └── app-privacy-disclosures.md          NEW — JSON-ish for App Store Connect (same content per platform record)
├── fastlane/                               OPTIONAL — automated build/upload (iOS lane only; Mac uploaded via xcodebuild)
│   ├── Appfile
│   ├── Fastfile
│   └── Snapfile
├── docs/manual-tests.md                    NEW — three-section regression checklist (iOS / Mac / cross-platform), per spec §10
├── MatronIntegrationTests/                 NEW — iOS integration test target (Task 12)
│   └── HappyPathTests.swift                NEW
├── MatronMacIntegrationTests/              NEW — Mac integration test target (Task 12)
│   └── HappyPathTests.swift                NEW — same source pulled in via project.yml `sources:` reference
├── docker-compose.test.yml                 NEW — tuwunel homeserver for integration tests (shared by both targets)
└── .github/workflows/integration.yml       NEW — CI for integration tests (matrix: ios + macos)
```

---

## Tasks

### Task 1: Design system tokens

**Files:**
- Create/modify: `MatronShared/Sources/DesignSystem/Colors.swift`
- Create/modify: `MatronShared/Sources/DesignSystem/Typography.swift`
- Create: `MatronShared/Sources/DesignSystem/Spacing.swift`
- Create: `MatronShared/Sources/DesignSystem/ButtonStyles.swift`

- [ ] **Step 1: Colors**

```swift
import SwiftUI

public extension Color {
    // Semantic tokens
    static let matronBackground       = Color("MatronBackground", bundle: nil)
    static let matronSurface          = Color("MatronSurface", bundle: nil)
    static let matronSurfaceRaised    = Color("MatronSurfaceRaised", bundle: nil)
    static let matronTextPrimary      = Color("MatronTextPrimary", bundle: nil)
    static let matronTextSecondary    = Color("MatronTextSecondary", bundle: nil)
    static let matronAccent           = Color("MatronAccent", bundle: nil)
    static let matronWarning          = Color("MatronWarning", bundle: nil)
    static let matronDanger           = Color("MatronDanger", bundle: nil)
    static let matronCodeBackground   = Color("MatronCodeBackground", bundle: nil)
}
```

The actual color values live in `Matron/Resources/Assets.xcassets` (light + dark variants per token). Add asset catalogue entries for each name.

- [ ] **Step 2: Typography**

```swift
import SwiftUI

public extension Font {
    static let matronDisplay     = Font.system(.largeTitle, design: .default, weight: .semibold)
    static let matronTitle       = Font.system(.title, design: .default, weight: .semibold)
    static let matronTitle2      = Font.system(.title2, design: .default, weight: .semibold)
    static let matronHeadline    = Font.system(.headline, design: .default, weight: .semibold)
    static let matronBody        = Font.system(.body, design: .default)
    static let matronCallout     = Font.system(.callout, design: .default)
    static let matronCaption     = Font.system(.caption, design: .default)
    static let matronCode        = Font.system(.callout, design: .monospaced)
    static let matronCodeSmall   = Font.system(.caption, design: .monospaced)
}
```

- [ ] **Step 3: Spacing**

```swift
import SwiftUI

public enum MatronSpacing {
    public static let xs: CGFloat = 4
    public static let s:  CGFloat = 8
    public static let m:  CGFloat = 12
    public static let l:  CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}
```

- [ ] **Step 4: Button styles**

```swift
import SwiftUI

public struct MatronPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matronHeadline)
            .padding(.horizontal, MatronSpacing.l)
            .padding(.vertical, MatronSpacing.m)
            .frame(maxWidth: .infinity)
            .background(Color.matronAccent.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

public struct MatronSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matronHeadline)
            .padding(.horizontal, MatronSpacing.l)
            .padding(.vertical, MatronSpacing.m)
            .frame(maxWidth: .infinity)
            .background(Color.matronSurfaceRaised.opacity(configuration.isPressed ? 0.6 : 1.0))
            .foregroundStyle(Color.matronTextPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

public struct MatronDestructiveButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matronHeadline)
            .padding(.horizontal, MatronSpacing.l)
            .padding(.vertical, MatronSpacing.m)
            .frame(maxWidth: .infinity)
            .background(Color.matronDanger.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

public extension ButtonStyle where Self == MatronPrimaryButtonStyle {
    static var matronPrimary: MatronPrimaryButtonStyle { MatronPrimaryButtonStyle() }
}
public extension ButtonStyle where Self == MatronSecondaryButtonStyle {
    static var matronSecondary: MatronSecondaryButtonStyle { MatronSecondaryButtonStyle() }
}
public extension ButtonStyle where Self == MatronDestructiveButtonStyle {
    static var matronDestructive: MatronDestructiveButtonStyle { MatronDestructiveButtonStyle() }
}
```

- [ ] **Step 5: Snapshot tests for each button style + colour swatch (consolidate into the cross-platform 6-variant matrix)**

Phase 2 established a `{iOS, Mac} × {light, dark, accessibility5}` 6-variant matrix helper for primitives that render on both platforms. Reuse it here for each button style and colour swatch — the design tokens are platform-agnostic, so each token snapshots as 6 variants. Mac-only chrome (covered later in Task 4b) snapshots only in the Mac scheme; iOS-only chrome only in the iOS scheme. The helper is the single source of truth — don't reinvent variant lists in Phase 7.

If Phase 2 didn't already add a `traitsForAccessibility5()` / `dynamicTypeAccessibility5()` helper, add one now in `MatronShared/Tests/SnapshotHelpers/SnapshotTraits.swift`:

```swift
import SwiftUI

extension View {
    /// Returns `self` with the largest accessibility Dynamic Type size applied.
    func dynamicTypeAccessibility5() -> some View {
        self.environment(\.dynamicTypeSize, .accessibility5)
    }
}
```

Use it in snapshot setups, e.g. `assertSnapshot(of: MyView().dynamicTypeAccessibility5(), as: .image(traits: .init(userInterfaceStyle: .dark)))`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/
git commit -m "feat: design system tokens (colours, typography, spacing) + button styles"
git push
```

---

### Task 1.5: Reconcile Phase 2 provisional token

> **Historical note (Phase 1 reorg):** DesignSystem has lived in `MatronShared/Sources/DesignSystem/` since Phase 1, so this is a within-MatronShared rename — **not** a cross-module move. An earlier review pass flagged this as a path-and-name reconciliation; with DesignSystem already shared, only the symbol name (`matronCodeBg` → `matronCodeBackground`) needs reconciling. Both apps consume the same canonical declaration once renamed.

Phase 2 introduced a provisional `Color.matronCodeBg` extension in `MatronShared/Sources/DesignSystem/Colors.swift` for use by `CodeBlock.swift`. Phase 7's canonical token is `Color.matronCodeBackground` (declared in Task 1, Step 1). Reconcile the two before any further token work depends on the canonical name.

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/Colors.swift`
- Modify: `MatronShared/Sources/DesignSystem/CodeBlock.swift` (and any other callsite found by grep)

- [ ] **Step 1: Locate every callsite**

```bash
grep -rn "matronCodeBg" MatronShared Matron MatronMac
```

Expected: at minimum `MatronShared/Sources/DesignSystem/CodeBlock.swift` (the Phase 2 consumer; the primitive lives in `MatronShared/`, not in either app target). Note any others found in either app.

- [ ] **Step 2: Remove the provisional definition**

In `MatronShared/Sources/DesignSystem/Colors.swift`, remove the Phase 2 provisional line:

```swift
static let matronCodeBg = Color(.systemGray6)
```

Confirm the canonical declaration from Task 1 Step 1 is in place:

```swift
static let matronCodeBackground = Color("MatronCodeBackground", bundle: nil)
```

- [ ] **Step 3: Update all callsites**

Replace `Color.matronCodeBg` → `Color.matronCodeBackground` in `CodeBlock.swift` and any other consumer surfaced by Step 1's grep.

- [ ] **Step 4: Re-run snapshot tests; rebaseline if intentional**

```bash
cd MatronShared && swift test --filter SnapshotTests
```

If a baseline diff appears (the asset-catalogue value differs from `Color(.systemGray6)`), eyeball the new render against the design intent before accepting the new baseline. Revert if the visual change is unintentional.

- [ ] **Step 5: Verify no stragglers**

```bash
grep -rn "matronCodeBg" MatronShared Matron MatronMac
# expected: no results
```

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Colors.swift MatronShared/Sources/DesignSystem/CodeBlock.swift
git commit -m "refactor(designsystem): rename matronCodeBg → matronCodeBackground (Phase 2 → Phase 7 token reconciliation)"
git push
```

---

### Task 2: Apply tokens across both apps

**Files:**
- Modify: every iOS `View` in `Matron/Features/` with hardcoded `Color`, `Font`, padding values
- Modify: every Mac `View` in `MatronMac/Features/` with hardcoded `Color`, `Font`, padding values

- [ ] **Step 1: Per-file token sweep (iOS + Mac)**

Replace hardcoded fonts, colours, and paddings with semantic tokens defined in Task 1. Touch each file explicitly — no "best effort" passes. Tokens are flat extensions on `Color` / `Font` plus `MatronSpacing.*`, all from `MatronShared/Sources/DesignSystem/`, so the same replacement vocabulary applies on both platforms. Cross-platform rendering primitives (MarkdownText, CodeBlock, ToolCallCard, MessageBubble, AskUserSheetBody, SessionMetaHeader, AttachmentImage, AttachmentFile) live in `MatronShared/Sources/DesignSystem/` — token usage there is fixed once and inherited by both apps; sweep them too.

**iOS feature files:**

- `Matron/Features/Onboarding/SignInView.swift` — replace `.font(.body)` → `.font(.matronBody)`, `.font(.headline)` → `.font(.matronHeadline)`, `.foregroundStyle(.secondary)` → `.foregroundStyle(Color.matronTextSecondary)`, `.padding(8)` → `.padding(MatronSpacing.s)`, raw `Color.blue` → `Color.matronAccent`.
- `Matron/Features/ChatList/ChatListView.swift` — replace `.font(.body)` → `.font(.matronBody)`, `.font(.headline)` → `.font(.matronHeadline)`, `.background(Color(.systemGroupedBackground))` → `.background(Color.matronBackground)`, `.padding(...)` numeric literals → `MatronSpacing.*`.
- `Matron/Features/ChatList/ChatRow.swift` — replace `.font(.subheadline)` → `.font(.matronCallout)`, `.font(.caption)` → `.font(.matronCaption)`, `.foregroundStyle(.secondary)` → `.foregroundStyle(Color.matronTextSecondary)`, unread badge background → `Color.matronAccent`.
- `Matron/Features/Chat/ChatView.swift` — `.background(Color(.systemBackground))` → `Color.matronBackground`, all `.font(...)` system literals → `.font(.matron*)` equivalents, all numeric `.padding(...)` → `MatronSpacing.*`.
- `Matron/Features/Chat/Composer/ComposerView.swift` — composer surface `.background(Color(.systemGray6))` → `Color.matronSurfaceRaised`, send-button tint `.tint(.blue)` → `.tint(Color.matronAccent)`, `.font(.body)` → `.font(.matronBody)`.
- `Matron/Features/Chat/Rendering/TimelineItemView.swift` — date-separator `.foregroundStyle(.secondary)` → `Color.matronTextSecondary`, all fonts → `.matron*` equivalents.
- `Matron/Features/Chat/Rendering/MessageBubble.swift` — bubble `.background(Color(.systemGray5/6))` → `Color.matronSurface` / `Color.matronSurfaceRaised` per role, text `.foregroundStyle(.primary)` → `Color.matronTextPrimary`, `.font(.body)` → `.font(.matronBody)`.
- `Matron/Features/Settings/SettingsView.swift` (and the per-section views from Task 4) — all `.font(...)` and `.foregroundStyle(...)` literals → semantic tokens; `Form` row spacing using `MatronSpacing.*`.
- `Matron/Features/Settings/NotificationSettingsView.swift` — replace hardcoded `.red` / `.green` (status indicator on lines ~401–403 of this plan's Task 4 Step 3) with `Color.matronDanger` / `Color.matronAccent`.

**Mac feature files (apply the same vocabulary):**

- `MatronMac/Features/Onboarding/MacSignInView.swift` — same font / colour / spacing token replacements as iOS Onboarding; centred-card layout uses `MatronSpacing.xl`/`xxl` for outer padding.
- `MatronMac/Features/ChatList/MacChatListView.swift` — sidebar list rows use `Font.matron*` and `Color.matronTextSecondary`; selection highlight uses `Color.matronAccent.opacity(...)` rather than a raw system tint.
- `MatronMac/Features/Chat/MacChatView.swift` — detail-column background → `Color.matronBackground`, system fonts → `.font(.matron*)`, hover-state surfaces → `Color.matronSurfaceRaised`.
- `MatronMac/Features/Chat/MacComposerView.swift` — composer surface → `Color.matronSurfaceRaised`, send-button tint → `Color.matronAccent`, drop-target highlight → `Color.matronAccent.opacity(0.2)` not raw `.blue`.
- `MatronMac/Features/Chat/Rendering/...` — **none.** All chat-rendering primitives (MarkdownText, CodeBlock, ToolCallCard, MessageBubble, AskUserSheetBody, SessionMetaHeader, AttachmentImage, AttachmentFile) live in `MatronShared/Sources/DesignSystem/`; the Mac chat view composes them directly. Sweep happens in `MatronShared/`, not under `MatronMac/Features/Chat/Rendering/`.
- `MatronMac/Features/BotProfile/MacBotProfileSheet.swift` — sheet header / row typography → `.matron*`; divider colour → `Color.matronTextSecondary.opacity(0.3)` not raw `.gray`.
- `MatronMac/Features/Verification/MacSasView.swift` — emoji grid label fonts → `.matronBody`/`.matronCallout`; CTA buttons use the design-system button styles (`.matronPrimary` / `.matronSecondary`).
- `MatronMac/Features/Verification/MacRecoveryKeyView.swift` — monospaced display of the key → `.font(.matronCode)`; instructional copy → `Color.matronTextSecondary`.
- `MatronMac/Features/Search/MacSearchView.swift` — toolbar field background `.background(Color(.windowBackgroundColor))` → `Color.matronSurface`; `.font(.body)` → `.font(.matronBody)`.
- `MatronMac/Features/Search/MacSearchResultsView.swift` — result-row fonts → `.matron*`; snippet highlights use `Color.matronAccent` not raw `.blue`.
- `MatronMac/Features/Settings/MacSettingsView.swift` — every tab body uses `.font(.matron*)` and `Color.matron*` throughout; Notifications tab status indicator uses `Color.matronDanger` / `Color.matronAccent` (parallel to iOS NotificationSettingsView).

- [ ] **Step 2: Verification — no hardcoded literals remain in either `Features/`**

The verification grep scans both app targets:

```bash
grep -rn 'foregroundStyle(.secondary)' Matron/Features MatronMac/Features
grep -rn 'foregroundStyle(.primary)' Matron/Features MatronMac/Features
grep -rn '\.font(\.body)' Matron/Features MatronMac/Features
grep -rn '\.font(\.headline)' Matron/Features MatronMac/Features
grep -rn '\.font(\.caption)' Matron/Features MatronMac/Features
grep -rn 'Color(\.systemGray' Matron/Features MatronMac/Features
grep -rn 'Color(\.systemBackground)' Matron/Features MatronMac/Features
grep -rn 'Color(\.windowBackgroundColor)' Matron/Features MatronMac/Features
grep -rn 'Color\.blue\b\|Color\.red\b\|Color\.green\b\|Color\.gray\b' Matron/Features MatronMac/Features
```

Each grep above must return no results. The exit criterion for Task 2 is **no hardcoded color/font literals in either `Matron/Features/` or `MatronMac/Features/`**.

- [ ] **Step 3: Visual regression check**

```bash
cd MatronShared && swift test --filter SnapshotTests
```

If a baseline changed, eyeball the new baseline against the design intent before accepting. If the diff is unintentional, revert the offending replacement. Do not blanket-accept.

- [ ] **Step 4: Commit per logical chunk**

Don't commit one giant blob; commit per feature group, with iOS and Mac surfaces in the same commit per feature (so the cross-platform consistency is reviewable in one diff):

```bash
git commit -m "style: apply design tokens to onboarding (iOS + Mac)"
git commit -m "style: apply design tokens to chat list (iOS + Mac)"
git commit -m "style: apply design tokens to chat view + composer (iOS + Mac)"
git commit -m "style: apply design tokens to verification + search + bot profile (iOS + Mac)"
git commit -m "style: apply design tokens to settings (iOS + Mac)"
git push
```

---

### Task 3: App icons + accent colour (iOS + Mac)

**Files:**
- Create: `Matron/Resources/Assets.xcassets/AppIcon.appiconset/` (full iOS icon set)
- Modify: `Matron/Resources/Assets.xcassets/AccentColor.colorset/`
- Create: `MatronMac/Resources/Assets.xcassets/AppIcon.appiconset/` (full Mac icon set)
- Modify: `MatronMac/Resources/Assets.xcassets/AccentColor.colorset/` (same brand colour as iOS)

- [ ] **Step 0: Create the master art file (shared between platforms)**

Place `docs/app-store/icon-source.svg` (or `.pdf`) — a 1024×1024 vector design. Both icon sets are generated from this single master so the iOS and Mac apps look like the same product. Commit this file before running the generator. Without committed master art, neither icon set can be regenerated reliably (you'd need to recreate the design from the rasterised PNGs, which loses fidelity).

```bash
git add docs/app-store/icon-source.svg
git commit -m "chore(app-store): commit 1024×1024 vector icon source (shared by iOS + Mac)"
```

- [ ] **Step 1: Generate the iOS icon set**

Need: 1024×1024 master + auto-generated sizes for iPhone (60pt @2x/@3x), Settings (29pt @2x/@3x), Spotlight (40pt @2x/@3x), Notification (20pt @2x/@3x), iPad sizes if you intend to ship iPad. Use a tool like `bakery` (`brew install bakery`) or `Icon Set Creator` to generate from `docs/app-store/icon-source.svg`. Output goes into `Matron/Resources/Assets.xcassets/AppIcon.appiconset/`.

Master design: simple monogram or wordmark. Recommend a flat single-colour-on-tint design over photographic — works at 20pt and ages well.

- [ ] **Step 2: Generate the Mac icon set**

Mac icons require a different size matrix from iOS: **16, 32, 64, 128, 256, 512, 1024** points, each at **@1x and @2x** (so the @2x of 512 is 1024 — 14 PNG entries total in the `.iconset`/`.appiconset`). The same `bakery` / `IconKit` tooling generates the Mac set from the same `docs/app-store/icon-source.svg` master:

```bash
# bakery example (illustrative — confirm the exact CLI in the version you install)
bakery export docs/app-store/icon-source.svg \
    --type macos \
    --output MatronMac/Resources/Assets.xcassets/AppIcon.appiconset
# or, manually with sips/iconutil:
mkdir -p AppIcon.iconset
for size in 16 32 64 128 256 512 1024; do
  sips -Z $size docs/app-store/icon-source.svg --out AppIcon.iconset/icon_${size}x${size}.png
  sips -Z $((size * 2)) docs/app-store/icon-source.svg --out AppIcon.iconset/icon_${size}x${size}@2x.png
done
iconutil -c icns AppIcon.iconset
# then copy the resulting PNGs + Contents.json into MatronMac/Resources/Assets.xcassets/AppIcon.appiconset/
```

The Mac `Contents.json` enumerates idioms `mac` with sizes `16x16` through `512x512` at `1x` and `2x`. Commit the Mac icon set under `MatronMac/Resources/Assets.xcassets/AppIcon.appiconset/`.

- [ ] **Step 3: Set accent colour (both apps)**

In each app's `AccentColor.colorset`, set the same chosen brand colour (light + dark variants). Both files live next to their respective `AppIcon.appiconset` and read the identical RGB values so the platforms feel like one product.

- [ ] **Step 4: Verify**

- iOS: build to a device. Long-press the home-screen icon — looks crisp. Open Settings → App → ensure all sizes render.
- Mac: build the Mac app, drag the `.app` bundle into Finder, view at icon-size 16, 32, 64, 128, 256, 512, 1024 in Finder column view + Get Info — every size renders crisply, no aliasing at the smallest sizes.

- [ ] **Step 5: Commit**

```bash
git add Matron/Resources/Assets.xcassets/ MatronMac/Resources/Assets.xcassets/
git commit -m "feat: app icon sets + accent colour for iOS and Mac"
git push
```

---

### Task 4: Full SettingsView

**Files:**
- Create: `Matron/Features/Settings/SettingsView.swift`
- Create: `MatronShared/Sources/ViewModels/SettingsViewModel.swift` (shared with Mac per spec §3 conventions — ViewModels are platform-agnostic and live in MatronShared)
- Create: `Matron/Features/Settings/AccountSettingsView.swift`
- Create: `Matron/Features/Settings/NotificationSettingsView.swift`
- Create: `Matron/Features/Settings/ServerSettingsView.swift`
- Create: `Matron/Features/Settings/AboutView.swift`
- Create: `Matron/Features/Settings/LicensesView.swift`

- [ ] **Step 1: SettingsView (the root)**

```swift
import SwiftUI
import MatronModels

struct SettingsView: View {
    let session: UserSession
    let dependencies: AppDependencies
    let onSignOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AccountSettingsView(session: session, onSignOut: onSignOut)
                    } label: {
                        Label("Account", systemImage: "person.circle")
                    }
                    NavigationLink {
                        DeviceSettingsView(
                            session: session,
                            recoveryKeyManager: dependencies.recoveryKeyManager(for: session),
                            verificationService: dependencies.verificationService(for: session)
                        )
                    } label: {
                        Label("Device & encryption", systemImage: "lock.shield")
                    }
                }
                Section {
                    NavigationLink { NotificationSettingsView() } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    NavigationLink {
                        ServerSettingsView(session: session)
                    } label: {
                        Label("Server", systemImage: "server.rack")
                    }
                }
                Section {
                    NavigationLink { AboutView() } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    NavigationLink { LicensesView() } label: {
                        Label("Licenses", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

- [ ] **Step 2: AccountSettingsView**

```swift
import SwiftUI
import MatronModels

struct AccountSettingsView: View {
    let session: UserSession
    let onSignOut: () -> Void
    @State private var showingSignOutConfirm = false

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("User ID", value: session.userID)
                LabeledContent("Device ID", value: session.deviceID)
            }
            Section {
                Button("Sign out", role: .destructive) {
                    showingSignOutConfirm = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign out of Matron?", isPresented: $showingSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need your recovery key to read encrypted history when you sign back in.")
        }
    }
}
```

- [ ] **Step 3: NotificationSettingsView**

```swift
import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                LabeledContent("System notifications") {
                    Text(label).foregroundStyle(color)
                }
                if status == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            Section {
                Text("Per-chat mute is in the long-press menu on a chat row.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .task { await refresh() }
    }

    private var label: String {
        switch status {
        case .authorized, .ephemeral, .provisional: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not yet asked"
        @unknown default: return "Unknown"
        }
    }
    private var color: Color {
        status == .denied ? Color.matronDanger : Color.matronAccent
    }
    private func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
    }
}
```

- [ ] **Step 4: ServerSettingsView**

```swift
import SwiftUI
import MatronModels

struct ServerSettingsView: View {
    let session: UserSession

    var body: some View {
        Form {
            Section {
                LabeledContent("URL", value: session.homeserverURL.absoluteString)
                LabeledContent("Host", value: session.homeserverURL.host ?? "—")
            }
        }
        .navigationTitle("Server")
    }
}
```

- [ ] **Step 5: AboutView + LicensesView**

```swift
struct AboutView: View {
    private let privacyPolicyURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "MatronPrivacyPolicyURL") as? String ?? "https://matron.example.com/privacy")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            }
            Section {
                Link("Privacy policy", destination: privacyPolicyURL)
                Link("Source code", destination: URL(string: "https://github.com/matronhq/matron-iOS-app")!)
            }
        }
        .navigationTitle("About")
    }
}

struct AckEntry: Decodable, Identifiable {
    let name: String
    let license: String
    var id: String { name }
}

struct LicensesView: View {
    @State private var entries: [AckEntry] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(Color.matronTextSecondary)
            } else if entries.isEmpty {
                Text("Licenses unavailable.").foregroundStyle(Color.matronTextSecondary)
            } else {
                ForEach(entries) { entry in
                    NavigationLink {
                        LicenseDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: MatronSpacing.xs) {
                            Text(entry.name).font(.matronHeadline)
                            Text(entry.license.prefix(120) + (entry.license.count > 120 ? "…" : ""))
                                .font(.matronCaption)
                                .foregroundStyle(Color.matronTextSecondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Licenses")
        .task { load() }
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else {
            loadError = "Acknowledgements.plist not bundled."
            return
        }
        do {
            entries = try PropertyListDecoder().decode([AckEntry].self, from: data)
        } catch {
            loadError = "Failed to decode Acknowledgements.plist: \(error.localizedDescription)"
        }
    }
}

struct LicenseDetailView: View {
    let entry: AckEntry
    var body: some View {
        ScrollView {
            Text(entry.license)
                .font(.matronCodeSmall)
                .padding(MatronSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .navigationTitle(entry.name)
    }
}
```

- [ ] **Step 6: Generate `Acknowledgements.plist`**

The plist must decode into `[AckEntry]` (top-level array of `{ name: String, license: String }` dictionaries). Two supported paths:

**Option A — `LicensePlist` SPM tool (preferred, repeatable):**

Add to `Package.swift` under `swift-package-manager-plugins` (or run via `mint`):

```bash
brew install mint
mint install mono0926/LicensePlist
mint run LicensePlist license-plist \
    --output-path Matron/Resources \
    --package-path MatronShared/Package.swift \
    --suppress-opening-directory \
    --single-page
```

`LicensePlist` emits one combined plist (`com.mono0926.LicensePlist.Output.plist`). Adapt with a one-shot conversion script committed under `scripts/generate-acknowledgements.swift`:

```bash
swift scripts/generate-acknowledgements.swift \
    Matron/Resources/com.mono0926.LicensePlist.Output.plist \
    Matron/Resources/Acknowledgements.plist
```

The script reads LicensePlist's output and re-emits a top-level array of `{ name, license }` dictionaries (the shape `AckEntry` decodes).

**Option B — manual one-time generation (fallback):**

Commit `scripts/generate-acknowledgements.swift` that walks `swift package describe --type json` for each SPM dependency, looks up its `LICENSE` file from the checked-out source under `MatronShared/.build/checkouts/<dep>/LICENSE`, and emits the same plist shape. Run once; commit the resulting `Matron/Resources/Acknowledgements.plist`. Re-run after any `Package.swift` change.

Either option, the committed `Acknowledgements.plist` is what ships in the bundle and is read by `LicensesView` via `PropertyListDecoder`.

**Both apps bundle the plist.** Drop a copy under `MatronMac/Resources/Acknowledgements.plist` (or, equivalently, point both app targets at the same shared resource via `project.yml`'s `sources:` for the resource bundle). The Mac `AboutTab` inside `MacSettingsView` (Task 4b) reuses the same `LicensesView` from `MatronShared` (or duplicated under `Matron/Features/Settings/`) — same code, same plist contents.

- [ ] **Step 7: Wire SettingsView into chat list**

In `ChatListView`, add a Settings toolbar button that pushes `SettingsView`.

- [ ] **Step 8: Commit**

```bash
git add Matron/Features/Settings/ Matron/Resources/Acknowledgements.plist
git commit -m "feat: complete iOS Settings hierarchy (Account, Notifications, Server, About, Licenses)"
git push
```

---

### Task 4b: MacSettingsView (Preferences scene)

The iOS `SettingsView` from Task 4 is a `List` of `Section`s pushed onto a `NavigationStack` — that shape is wrong on Mac. Mac apps expose preferences via the native `Settings { } ` scene, which renders as a Preferences window with a `TabView` of tabs. This task adds the Mac-shaped Settings UI, sharing the `SettingsViewModel` from `MatronShared/Sources/ViewModels/`.

Do this **TDD-style**: snapshot test for each tab body first (light/dark × default/`.accessibility5` — the cross-platform 6-variant matrix established in Phase 2), then the view itself.

**Files:**
- Create: `MatronMac/Features/Settings/MacSettingsView.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (wire `Settings { MacSettingsView() }`)
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/MacSettingsViewSnapshotTests.swift` (Mac scheme only)

- [ ] **Step 1: Snapshot test scaffold (failing)**

In `MatronShared/Tests/DesignSystemSnapshotTests/MacSettingsViewSnapshotTests.swift`, snapshot each of the five tab bodies under light + dark + `.accessibility5` using the `dynamicTypeAccessibility5()` helper from Task 1 Step 5. Run under the Mac scheme — fails because `MacSettingsView` doesn't exist yet.

- [ ] **Step 2: Implement `MacSettingsView`**

```swift
import SwiftUI
import MatronModels
import MatronShared

struct MacSettingsView: View {
    @State private var viewModel: SettingsViewModel  // shared from MatronShared/Sources/ViewModels/
    let session: UserSession
    let dependencies: AppDependencies
    let onSignOut: () -> Void

    var body: some View {
        TabView {
            GeneralTab(viewModel: viewModel, onSignOut: onSignOut)
                .tabItem { Label("General", systemImage: "gear") }

            ThisDeviceTab(
                session: session,
                recoveryKeyManager: dependencies.recoveryKeyManager(for: session),
                verificationService: dependencies.verificationService(for: session)
            )
            .tabItem { Label("This Device", systemImage: "lock.shield") }

            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }

            ServerTab(session: session)
                .tabItem { Label("Server", systemImage: "server.rack") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct GeneralTab: View {
    @Bindable var viewModel: SettingsViewModel
    let onSignOut: () -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Display name", text: $viewModel.displayName)
            }
            Section {
                Button("Sign out", role: .destructive, action: onSignOut)
            }
        }
        .formStyle(.grouped)
        .padding(MatronSpacing.l)
    }
}

private struct ThisDeviceTab: View {
    let session: UserSession
    let recoveryKeyManager: RecoveryKeyManager
    let verificationService: VerificationService

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Device ID", value: session.deviceID)
                LabeledContent("Verification", value: verificationService.statusLabel)
            }
            Section("Recovery key") {
                Button("Reveal recovery key") { /* sheet — same flow as iOS DeviceSettingsView */ }
            }
        }
        .formStyle(.grouped)
        .padding(MatronSpacing.l)
    }
}

private struct NotificationsTab: View {
    @State private var pushEnabled = true
    var body: some View {
        Form {
            Toggle("System push notifications", isOn: $pushEnabled)
            Text("Per-chat mute is in the chat row's context menu (right-click).")
                .font(.matronCaption)
                .foregroundStyle(Color.matronTextSecondary)
        }
        .formStyle(.grouped)
        .padding(MatronSpacing.l)
    }
}

private struct ServerTab: View {
    let session: UserSession
    var body: some View {
        Form {
            LabeledContent("URL", value: session.homeserverURL.absoluteString)
            LabeledContent("Host", value: session.homeserverURL.host ?? "—")
            LabeledContent("Server version", value: session.homeserverVersion ?? "—")
        }
        .formStyle(.grouped)
        .padding(MatronSpacing.l)
    }
}

private struct AboutTab: View {
    private let privacyPolicyURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "MatronPrivacyPolicyURL") as? String ?? "https://matron.example.com/privacy")!
    var body: some View {
        Form {
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            Link("Privacy policy", destination: privacyPolicyURL)
            NavigationLink("Licenses") { LicensesView() }   // shared with iOS
        }
        .formStyle(.grouped)
        .padding(MatronSpacing.l)
    }
}
```

- [ ] **Step 3: Wire into `MatronMacApp`**

```swift
@main
struct MatronMacApp: App {
    // ...existing WindowGroup main scene, .commands menu bar, etc.
    var body: some Scene {
        WindowGroup { /* main window */ }
            .commands { /* menu bar */ }
        Settings {
            MacSettingsView(session: …, dependencies: …, onSignOut: …)
        }
    }
}
```

`⌘,` from anywhere in the app opens the Preferences window with the General tab selected by default (system default behaviour for `Settings { }` scenes).

- [ ] **Step 4: Verify snapshot tests pass**

```bash
xcodebuild test -scheme MatronShared-Mac -destination 'platform=macOS'
```

All five tab snapshots green under light/dark × default/`.accessibility5`.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Settings/MacSettingsView.swift MatronMac/App/MatronMacApp.swift MatronShared/Tests/DesignSystemSnapshotTests/MacSettingsViewSnapshotTests.swift
git commit -m "feat(mac): MacSettingsView TabView for native Settings { } Preferences scene"
git push
```

---

### Task 5: Bot profile polish

**Files:**
- Modify: `Matron/Features/BotProfile/BotProfileView.swift`

- [ ] **Step 1: Add avatar fetch**

If the bot has an `avatarURL` (mxc://), fetch via `MediaService` (introduce in MatronShared if not already) and render as a real image. Cache in-memory.

- [ ] **Step 2: Improve typography + spacing using design tokens**

Use `MatronSpacing`, `Font.matronBody` / `Font.matronHeadline` / etc. (from the `Font` extension defined in Task 1), and `Color.matronAccent` / `Color.matronSurface` / etc. (from the `Color` extension defined in Task 1). All tokens are flat extension methods, not namespaced types — there is no `MatronTypography` or `MatronColors` type, only `MatronSpacing` (which is the one enum-namespaced token group).

- [ ] **Step 3: Commit**

```bash
git commit -am "feat: BotProfileView avatar + design polish"
git push
```

---

### Task 6: Accessibility audit

**Files:**
- Modify: many views (small adjustments)

Audit checklist (do as one pass, commit per area):

- [ ] **Step 1: VoiceOver labels**
  - Every icon-only button has `.accessibilityLabel("…")`.
  - `ChatRow` reads as "Chat title, bot name, time, X unread."
  - Tool call cards: "Tool call, [tool], [status]."
  - Ask-user sheet inputs have proper `.accessibilityLabel`.

- [ ] **Step 2: Dynamic Type**
  - Test at sizes `.xSmall`, `.large` (default), `.xxxLarge`, and `.accessibility5` (alias `.accessibilityExtraExtraExtraLarge`).
  - Snapshot tests in DesignSystem already cover S/L/XXXL — extend the existing test cases with `.accessibility5` variants alongside light/dark, using the `dynamicTypeAccessibility5()` helper added in Task 1 Step 5.
  - Fix any clipped text or broken layouts surfaced by the new baselines.

- [ ] **Step 3: Hit targets**
  - Every tappable element ≥ 44×44pt. Composer send button, palette rows, banner buttons.

- [ ] **Step 4: Reduced motion**
  - Respect `@Environment(\.accessibilityReduceMotion)` for the auto-scroll-to-bottom animation in ChatView (use `.linear(duration: 0.001)` if reduced).

- [ ] **Step 5: Contrast**
  - Run the Accessibility Inspector → Audit on the chat list, chat view, settings. Fix any flagged contrast issues by adjusting design tokens.

- [ ] **Step 6: Commit per area**

```bash
git commit -am "a11y: VoiceOver labels across chat list and chat view"
git commit -am "a11y: dynamic type fixes for composer + ask-user sheet"
git commit -am "a11y: enlarge hit targets in settings"
git push
```

---

### Task 7: Privacy policy + App Privacy disclosures

**Files:**
- Create: `Matron/Resources/PrivacyPolicy.md`
- Create: `docs/app-store/privacy-policy.md`
- Create: `docs/app-store/app-privacy-disclosures.md`

- [ ] **Step 1: Write the privacy policy**

Cover:
- What data is collected: nothing by us. The user's homeserver receives Matrix IDs, push tokens, message data (E2EE).
- Third parties: matrix-rust-sdk (vendor: Matrix.org), Apple Push Notification service (silent payloads, no content).
- No analytics, no crash reporting, no telemetry.
- Data retention: messages stored on the user's homeserver indefinitely; local FTS index until sign-out.
- Contact: an email address you control.

- [ ] **Step 2: App Privacy disclosures (matches App Store Connect's "Data Types" form)**

```markdown
# App Privacy disclosures

## Data linked to the user
- **Identifiers** (User ID): used to authenticate with the user's homeserver. Not used for tracking.

## Data not collected
- Contact info (we don't ask for email/phone)
- Health, financial, location, browsing history
- Diagnostics — no analytics SDK in the app.

## Third-party SDK disclosures
- matrix-rust-sdk-swift (Matrix.org, Apache 2.0): network with the user-supplied homeserver only.
- MarkdownUI, GRDB.swift, swift-snapshot-testing: no network access; on-device only.
```

- [ ] **Step 3: Wire the public privacy-policy URL into `AboutView` (both apps)**

Once `docs/app-store/privacy-policy.md` is hosted at a stable public URL (typically a GitHub Pages render of that file or a marketing site path), expose it to **both** apps via their respective Info.plist instead of hardcoding it in Swift. One URL covers both apps (per spec §12.5).

Add the same key + value to both Info.plist files:

`Matron/Resources/Info.plist`:

```xml
<key>MatronPrivacyPolicyURL</key>
<string>https://matron.chat/privacy</string>
```

`MatronMac/Resources/Info.plist`:

```xml
<key>MatronPrivacyPolicyURL</key>
<string>https://matron.chat/privacy</string>
```

Replace the URL with the real hosted URL before App Store submission. The same `Bundle.main.object(forInfoDictionaryKey: "MatronPrivacyPolicyURL")` lookup works on both platforms — `AboutView` (iOS) and the `AboutTab` inside `MacSettingsView` (Mac, Task 4b) both read this key with a fallback.

Document this requirement at the top of `docs/app-store/privacy-policy.md`:

> The public hosted URL of this document MUST be set as `MatronPrivacyPolicyURL` in **both** `Matron/Resources/Info.plist` and `MatronMac/Resources/Info.plist` before each App Store / Mac App Store submission. The same URL must be entered as the Privacy Policy URL in **both** App Store Connect records (iOS + Mac).

- [ ] **Step 4: Commit**

```bash
git add Matron/Resources/PrivacyPolicy.md Matron/Resources/Info.plist MatronMac/Resources/Info.plist docs/app-store/
git commit -m "docs: privacy policy + App Privacy disclosures + Info.plist URL key (iOS + Mac)"
git push
```

---

### Task 8: App Store listing copy + screenshots (iOS + Mac)

**Files:**
- Create: `docs/app-store/description-en.md` (used by both records)
- Create: `docs/app-store/promotional-text.md`
- Create: `docs/app-store/keywords.txt`
- Create: `docs/app-store/screenshots/ios/` (PNG files)
- Create: `docs/app-store/screenshots/mac/` (PNG files)

- [ ] **Step 1: Description (≤ 4000 chars)**

Draft a short product pitch. Lead with what makes Matron different — bot-first chat, your own homeserver, end-to-end encrypted, native on iPhone / iPad / Mac. The same description goes into both App Store Connect records.

- [ ] **Step 2: Promotional text (≤ 170 chars)**

E.g. "Native Matrix client for talking to AI bots. End-to-end encrypted. Bring your own homeserver. iPhone, iPad, Mac."

- [ ] **Step 3: Keywords (≤ 100 chars total, comma-separated)**

E.g. `matrix,chat,bot,e2ee,encryption,ai,claude,homeserver,messaging,private`

- [ ] **Step 4: iOS screenshots**

Required sizes: 6.7" (iPhone 15 Pro Max), 6.5" (iPhone 11 Pro Max), 5.5" (iPhone 8 Plus).

Use `xcrun simctl io <DEVICE> screenshot screenshot.png` from the simulator. Capture five screens:
1. Chat list with several bots and recency grouping
2. Chat view with markdown + code block + tool-call card
3. Composer with slash palette open
4. Ask-user sheet with choice input
5. Settings → Device with verified state

Save under `docs/app-store/screenshots/ios/{6.7,6.5,5.5}/`.

- [ ] **Step 4b: Mac screenshots**

Required sizes (Apple's accepted Mac App Store sizes): 1280×800, 1440×900, 2560×1600, 2880×1800.

Capture from a real Mac running the Mac app (or via `screencapture -x`). Capture the same five screens as iOS (in the Mac shape — sidebar + detail layout):
1. Sidebar chat list + chat view side-by-side, with markdown + code block + tool-call card visible
2. Search results panel replacing the detail column (`⌘F`)
3. Composer with drag-and-drop highlight active
4. Ask-user sheet over the chat detail column
5. Preferences (Settings) window with the General tab selected

Save under `docs/app-store/screenshots/mac/{1280x800,1440x900,2560x1600,2880x1800}/`.

Optional: caption overlays (use Sketch/Figma + a script). The same caption strings can apply to both platforms with minor wording tweaks.

- [ ] **Step 5: Commit**

```bash
git add docs/app-store/
git commit -m "docs: App Store listing copy + iOS (6.7\"/6.5\"/5.5\") and Mac (1280×800–2880×1800) screenshots"
git push
```

---

### Task 9: Fastlane (optional but recommended) for iOS TestFlight uploads

> **Scope note:** Fastlane handles **iOS only**. Mac App Store uploads use raw `xcodebuild -exportArchive` + `xcrun altool --upload-app` (Task 11 Step 2b) since Fastlane's macOS support is less mature and the raw command is sufficient.

**Files:**
- Create: `fastlane/Appfile`
- Create: `fastlane/Fastfile`
- Create: `fastlane/Snapfile`

- [ ] **Step 1: Install and init**

```bash
brew install fastlane
fastlane init
```

- [ ] **Step 2: Configure for TestFlight**

`Fastfile`:

```ruby
default_platform(:ios)

platform :ios do
  desc "Build and upload a beta build to TestFlight"
  lane :beta do
    setup_ci if ENV['CI']
    match(type: "appstore") if ENV['CI']  # ASC API key auth in CI; manual signing locally is fine
    increment_build_number(xcodeproj: "Matron.xcodeproj")
    build_app(
      workspace: "Matron.xcworkspace",
      scheme: "Matron",
      clean: true,
      export_method: "app-store"
    )
    upload_to_testflight(
      api_key_path: ENV['ASC_API_KEY_PATH'],
      skip_waiting_for_build_processing: false
    )
  end
end
```

`Appfile`:

```ruby
app_identifier "chat.matron.app"
apple_id "<YOUR_APPLE_ID>"
team_id "<TEAM_ID>"
```

- [ ] **Step 3: Add a CI workflow for TestFlight (optional)**

`.github/workflows/testflight.yml` — manual trigger only, runs `fastlane beta` with secrets stored in GitHub Actions.

- [ ] **Step 4: Commit**

```bash
git add fastlane/ .github/workflows/testflight.yml
git commit -m "build: fastlane lane for TestFlight uploads"
git push
```

---

### Task 10: Final QA pass + manual regression

**Files:**
- Create: `docs/manual-tests.md` (NEW — the file does not yet exist on disk; earlier phases referenced it but it was never authored)

- [ ] **Step 1: Author `docs/manual-tests.md` with the full three-section regression checklist (per spec §10)**

The checklist must run before each TestFlight build **and** each Mac App Store build, and explicitly include every spec-mandated item across both platforms plus a cross-platform smoke section. Write the file:

```markdown
# Matron — manual test checklist (iOS + Mac)

Run the appropriate sections on a TestFlight build (iOS) and/or a notarized Mac App Store build (Mac), on physical hardware, against a clean homeserver, before each build is promoted. Anything that fails blocks the release. The Cross-platform smoke section runs once per release with both apps signed in to the same account.

## Smoke

- [ ] Cold install (iOS) → sign-in → first-device verification → chat list → start a chat → send a message → response renders → push notification arrives → tap notification → opens correct chat.
- [ ] Cold install (Mac) → sign-in → first-device verification → chat list → start a chat → send a message → response renders → push notification arrives → click notification → focuses the main window on the correct chat.

## Phases 1–6 regression

- [ ] Re-run all manual checks added in earlier phases on both apps (sign-in, chat list, chat view, E2EE, push, custom events, search).

## iOS per-TestFlight regression (mandatory — spec §10)

- [ ] **SAS verification with a real other device** — sign in to Matron on a second physical device with the same Matrix account; from device A, initiate verification with device B; both sides see the 7-emoji set; compare emojis aloud; both tap "They match"; both sides confirm the verification succeeded and the partner device shows as Verified.
- [ ] **Push notification on physical device** — install the TestFlight build on a physical device; sign in; lock the device; from a separate Matrix account, send a message to a room the test user is in; assert the push arrives within 10 seconds with the decrypted message body visible (sender display name + message text), not a generic "New message" placeholder.
- [ ] **Attachment picker end-to-end** — from the composer, open the image picker; pick a photo; send; on the second device (from the SAS step above), confirm the image renders correctly and decrypts. Repeat with the file picker (PDF or other non-image file). Both attachments must be sent encrypted (`m.image` / `m.file` with E2EE) and decrypted on the receiving device.

## Mac per-App-Store-build regression (mandatory — spec §10)

- [ ] **Menu bar shortcuts** — confirm every keyboard shortcut wired in Phase 5 fires the right command:
  - `⌘N` — New chat
  - `⌘F` — Focus search
  - `⌘K` — Focus composer
  - `⌘⇧S` — Toggle sidebar
  - `⌘+` / `⌘-` / `⌘0` — Zoom in / out / reset
  - `⌘,` — Open Preferences (Settings) window
- [ ] **Sidebar toggle** — `⌘⇧S` collapses and expands the sidebar; the View menu item reflects current state.
- [ ] **Window position restores** — close and re-open the app; the main window restores to the same position and size on the same display.
- [ ] **Drag-and-drop attachments** — drag an image file from Finder onto the composer; the drop target highlights; releasing sends the image (encrypted) to the active chat. Repeat with a non-image file (PDF) → sent as `m.file`.
- [ ] **Settings (Preferences) window** — `⌘,` from anywhere opens the Preferences window; all five tabs render: General, This Device, Notifications, Server, About. Each tab's controls work (display-name edit, recovery-key reveal, push toggle, server URL/version display, build/version + privacy-policy link).
- [ ] **Mac push notification on a real Mac** — sign in on a real Mac with notifications granted; background the app (`⌘H`); from a separate Matrix account, send a message; the push arrives within 10 seconds with decrypted content.
- [ ] **Tap notification focuses window** — clicking the delivered banner brings the Matron Mac window forward and selects the correct chat in the sidebar.

## Cross-platform smoke (mandatory — spec §10)

- [ ] **Same-account dual sign-in** — sign in to the same Matrix account on both an iOS device and a Mac. Both apps display the identical chat list within seconds of sync.
- [ ] **Cross-platform message round-trip** — send a message from iOS → Mac receives within 5 seconds (and vice versa). Send an attachment from Mac (drag-and-drop) → iOS receives and decrypts.
- [ ] **SAS verify Mac from iOS device** — initiate device verification on the iOS app to verify the Mac app's session; emoji set matches on both screens; both tap/click "They match"; the Mac app's session shows as Verified in iOS Settings → Device, and vice versa.
- [ ] **Recovery key from iCloud Keychain works on Mac** — after saving the recovery key on iOS during first-device setup (which writes it to iCloud Keychain), sign out on Mac, sign back in, and confirm the recovery key autofills from iCloud Keychain on the Mac and successfully decrypts historical messages.

## Visual polish (both apps)

- [ ] iOS app icon present on Home Screen at every size (60pt, 29pt Settings, 40pt Spotlight, 20pt Notification).
- [ ] Mac app icon renders crisply at 16/32/64/128/256/512/1024 in Finder Get Info.
- [ ] iOS app launches in <3 seconds on iPhone 12 or newer.
- [ ] Mac app launches in <3 seconds on M1 or newer.
- [ ] No console warnings in Xcode about layout, missing assets, or deprecated APIs (both schemes).
- [ ] All snapshot tests pass after design token application (the cross-platform 6-variant matrix: `{iOS, Mac} × {light, dark, accessibility5}`).
- [ ] VoiceOver (iOS) / VoiceOver (macOS) navigation through chat list, chat view, settings — every element has a sensible label on both platforms.
- [ ] Dynamic Type tested at `.accessibility5` — no clipped text on any major screen, both apps.
- [ ] Light + dark mode visually consistent on both apps.
- [ ] Privacy policy link in About opens to the URL set in `MatronPrivacyPolicyURL` (both Info.plists).
```

- [ ] **Step 2: Commit**

```bash
git add docs/manual-tests.md
git commit -m "docs: v1.0 release regression checklist — iOS + Mac + cross-platform (spec §10 mandatory items)"
git push
```

---

### Task 11: TestFlight + Mac App Store first build + submission

**Files:** none (App Store Connect work — done per platform)

Spec §12.5 mandates **two** App Store Connect records (one per platform; iOS and Mac binaries are submitted separately). Encryption export compliance applies to both binaries; one privacy policy URL covers both apps; App Privacy disclosures are entered identically in both records.

- [ ] **Step 1a: Set up the iOS App Store Connect record**

- Create the iOS app in App Store Connect with bundle ID `chat.matron.app` (or your chosen identifier).
- iOS provisioning profile + distribution certificate set up (via `fastlane match` or Xcode automatic signing).
- Fill in metadata from `docs/app-store/` (description, promo text, keywords, support URL).
- Upload iOS screenshots from `docs/app-store/screenshots/ios/`.
- Set Privacy Policy URL (the same one used in `MatronPrivacyPolicyURL`).
- Fill in App Privacy disclosures from `docs/app-store/app-privacy-disclosures.md`.
- Confirm `ITSAppUsesNonExemptEncryption=NO` is in `Matron/Resources/Info.plist` (already added in Task 7 — Phase 7 verification).

- [ ] **Step 1b: Set up the Mac App Store Connect record**

- Create the **Mac** app in App Store Connect (separate record from iOS) with bundle ID `chat.matron.mac` (or `chat.matron.app` again — Apple allows the same bundle ID across iOS / Mac App Store records but treats them as separate apps for review purposes).
- Mac provisioning profile + Developer ID Application certificate (via `fastlane match` for the Mac App Store distribution type, or Xcode automatic signing).
- Fill in metadata from `docs/app-store/` — description, promo text, keywords are identical content; the Mac record uses Mac-sized screenshots from `docs/app-store/screenshots/mac/` (1280×800, 1440×900, 2560×1600, 2880×1800).
- Set Privacy Policy URL — **same URL as iOS** (one URL covers both apps per spec §12.5).
- Fill in App Privacy disclosures — same content as iOS.
- Confirm `ITSAppUsesNonExemptEncryption=NO` is in `MatronMac/Resources/Info.plist` (added in Task 7 — Phase 7 verification).
- **Notarization:** Mac builds **submitted via App Store Connect upload do not require a separate `xcrun notarytool` step** — App Store Connect handles notarization as part of the submission. Notarization via `notarytool` is only needed for Developer ID-distributed builds outside the Mac App Store, which isn't our distribution channel.

- [ ] **Step 2: Build + upload (iOS)**

iOS uploads use Fastlane (Task 9):

```bash
fastlane beta
```

Expected: build uploads, processed, available in TestFlight within ~30 minutes. Internal testers can install.

- [ ] **Step 2b: Build + upload (Mac)**

Mac builds use `xcodebuild -exportArchive` directly (Fastlane's macOS support is less mature; the raw command is simpler and well-supported):

```bash
# Archive the Mac app
xcodebuild -workspace Matron.xcworkspace \
    -scheme MatronMac \
    -configuration Release \
    -archivePath build/MatronMac.xcarchive \
    archive

# Export an App Store package (.pkg)
xcodebuild -exportArchive \
    -archivePath build/MatronMac.xcarchive \
    -exportPath build/MatronMac-export \
    -exportOptionsPlist MatronMac/ExportOptions.plist

# Upload to App Store Connect
xcrun altool --upload-app \
    --type macos \
    --file build/MatronMac-export/MatronMac.pkg \
    --apiKey "$ASC_API_KEY_ID" \
    --apiIssuer "$ASC_API_KEY_ISSUER"
```

`MatronMac/ExportOptions.plist` declares `<key>method</key><string>app-store</string>` (or `app-store-connect` on newer Xcode versions) and the team ID. Commit the plist alongside the Mac target.

Expected: build uploads, App Store Connect notarizes it automatically, processed within ~60 minutes; internal testers in the Mac App Store TestFlight equivalent can install.

- [ ] **Step 3: Internal testing on both platforms (1–2 weeks)**

Recruit 5–10 internal testers per platform (some can dual-test). Triage any reports.

- [ ] **Step 4: Submit for App Review (per platform)**

When confident, submit each record for App Review from its App Store Connect record. iOS and Mac reviews run independently and can land at different times.

- [ ] **Step 5: Document the release in the repo**

```bash
git tag v1.0.0
git push --tags
```

Add a `CHANGELOG.md` entry covering both platforms.

```bash
git commit -m "chore: tag v1.0.0 (iOS + Mac)"
```

---

### Task 12: Integration test targets — iOS + Mac (spec §10 mandate)

Spec §10 mandates "one happy-path flow against a real homeserver, run in CI" on **both** platforms (`MatronIntegrationTests` for iOS, `MatronMacIntegrationTests` for Mac, same `HappyPathTests.swift` source). The purpose is to catch SDK-wiring regressions that no unit test will surface, on both targets. Do this **TDD-style**: write the failing test first, then bring up the homeserver and CI plumbing, then make it green on both schemes. Commit per step.

**Files:**
- Create: `MatronIntegrationTests/HappyPathTests.swift` (canonical source)
- Create: `MatronMacIntegrationTests/` directory (no own source — its `project.yml` stanza references the same `HappyPathTests.swift` via `sources:` path)
- Modify: `project.yml` (add **two** test target stanzas — `MatronIntegrationTests` on iOS, `MatronMacIntegrationTests` on Mac, both depending on `MatronShared`)
- Create: `docker-compose.test.yml` (repo root, shared by both targets)
- Create: `.github/workflows/integration.yml` (matrix workflow: ios + macos)

- [ ] **Step 1: Add both test targets to `project.yml` (test-first scaffold)**

Append the following two stanzas under `targets:` in `project.yml`. Both reference the same `MatronIntegrationTests/HappyPathTests.swift` source file — the Mac target's `sources:` path points at the iOS target's directory so we don't duplicate the test code.

```yaml
  MatronIntegrationTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: MatronIntegrationTests
    dependencies:
      - package: MatronShared
        product: MatronShared
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        IPHONEOS_DEPLOYMENT_TARGET: "17.0"

  MatronMacIntegrationTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: MatronIntegrationTests   # same source — single canonical HappyPathTests.swift
    dependencies:
      - package: MatronShared
        product: MatronShared
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        MACOSX_DEPLOYMENT_TARGET: "14.0"
```

Regenerate Xcode project:

```bash
xcodegen generate
```

Commit:

```bash
git add project.yml
git commit -m "test(integration): add MatronIntegrationTests + MatronMacIntegrationTests target scaffolds"
```

- [ ] **Step 2: Write the failing happy-path test first**

Create `MatronIntegrationTests/HappyPathTests.swift`:

```swift
import XCTest
@testable import MatronShared
import MatrixRustSDK

/// One end-to-end happy-path test against a real Matrix homeserver
/// brought up via `docker-compose.test.yml` (tuwunel on localhost:8008).
///
/// Spec §10: catches SDK-wiring regressions that unit tests can't.
final class HappyPathTests: XCTestCase {
    private let homeserverURL = URL(string: "http://localhost:8008")!

    func testRegisterUserAndBotRoundTripMessage() async throws {
        // 1. Register a fresh user.
        let userLocalpart = "alice-\(UUID().uuidString.prefix(8).lowercased())"
        let userPassword = "test-password-\(UUID().uuidString)"
        let userID = try await registerUser(localpart: userLocalpart, password: userPassword)

        // 2. Register a fresh bot user.
        let botLocalpart = "bot-\(UUID().uuidString.prefix(8).lowercased())"
        let botPassword = "test-password-\(UUID().uuidString)"
        let botID = try await registerUser(localpart: botLocalpart, password: botPassword)

        // 3. Sign the user in via the real SDK and create a room.
        let userClient = try await buildClient(userID: userID, password: userPassword)
        let roomID = try await createRoom(client: userClient, invite: [botID])

        // 4. Sign the bot in and accept the invite.
        let botClient = try await buildClient(userID: botID, password: botPassword)
        try await joinRoom(client: botClient, roomID: roomID)

        // 5. User sends an `m.room.message`.
        let body = "hello from integration test \(UUID().uuidString)"
        let eventID = try await sendTextMessage(client: userClient, roomID: roomID, body: body)

        // 6. Bot reads it back via NotificationClient.getNotification (the same path
        //    the NSE takes — proves SDK wiring catches encryption + sync regressions).
        let notification = try await fetchNotificationWithRetry(
            client: botClient,
            roomID: roomID,
            eventID: eventID,
            timeout: 30
        )
        XCTAssertNotNil(notification, "Bot must be able to read the message back via getNotification")
        XCTAssertTrue(
            (notification?.body ?? "").contains(body),
            "Decrypted notification body must contain the sent text"
        )
    }

    // MARK: - Helpers (raw HTTP for register/create-room; real SDK for client/send/getNotification)

    private func registerUser(localpart: String, password: String) async throws -> String {
        var req = URLRequest(url: homeserverURL.appendingPathComponent("/_matrix/client/v3/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": localpart,
            "password": password,
            "auth": ["type": "m.login.dummy"],
            "inhibit_login": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Integration", code: 1, userInfo: [NSLocalizedDescriptionKey: "register failed: \(body)"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let userID = json?["user_id"] as? String else {
            throw NSError(domain: "Integration", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing user_id"])
        }
        return userID
    }

    private func buildClient(userID: String, password: String) async throws -> Client {
        // Replace with whatever ClientBuilder factory MatronShared exposes; the point
        // is to use the SAME builder the app uses so regressions in SDK wiring surface.
        let builder = ClientBuilder()
            .homeserverUrl(url: homeserverURL.absoluteString)
        let client = try await builder.build()
        try await client.login(username: userID, password: password, initialDeviceName: "integration", deviceId: nil)
        return client
    }

    private func createRoom(client: Client, invite: [String]) async throws -> String {
        let params = CreateRoomParameters(
            name: "Integration test room",
            topic: nil,
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .privateChat,
            invite: invite,
            avatar: nil
        )
        return try await client.createRoom(request: params)
    }

    private func joinRoom(client: Client, roomID: String) async throws {
        try await client.joinRoomById(roomId: roomID)
    }

    private func sendTextMessage(client: Client, roomID: String, body: String) async throws -> String {
        let room = try await client.getRoom(roomId: roomID)!
        let timeline = try await room.timeline()
        return try await timeline.sendMessage(msg: .text(body: body))
    }

    private func fetchNotificationWithRetry(client: Client, roomID: String, eventID: String, timeout: TimeInterval) async throws -> NotificationItem? {
        let nc = try NotificationClient(client: client, processSetup: .singleProcess)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = try? await nc.getNotification(roomId: roomID, eventId: eventID) {
                return item
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }
}
```

(The exact `ClientBuilder` / `CreateRoomParameters` / `NotificationClient` shapes will need to be reconciled with the matrix-rust-sdk-swift version Matron pins — adjust property names per Phase 4's notes on SDK shape drift.)

Run locally on **both** schemes — expect failure (homeserver not yet up):

```bash
xcodebuild test -scheme MatronIntegrationTests -destination 'platform=iOS Simulator,name=iPhone 15'
xcodebuild test -scheme MatronMacIntegrationTests -destination 'platform=macOS'
```

Commit:

```bash
git add MatronIntegrationTests/HappyPathTests.swift
git commit -m "test(integration): failing happy-path test against real homeserver (iOS + Mac)"
```

- [ ] **Step 3: Bring up the test homeserver**

Create `docker-compose.test.yml` at the repo root:

```yaml
services:
  tuwunel:
    image: tuwunel/tuwunel:latest
    container_name: matron-tuwunel-test
    restart: "no"
    ports:
      - "8008:8008"
    environment:
      TUWUNEL_SERVER_NAME: "localhost"
      TUWUNEL_PORT: "8008"
      TUWUNEL_ADDRESS: "0.0.0.0"
      TUWUNEL_DATABASE_PATH: "/var/lib/tuwunel"
      TUWUNEL_ALLOW_REGISTRATION: "true"
      TUWUNEL_REGISTRATION_TOKEN: ""
      TUWUNEL_YES_I_AM_VERY_VERY_SURE_I_WANT_AN_OPEN_REGISTRATION_SERVER_PROD: "true"
      TUWUNEL_ALLOW_FEDERATION: "false"
      TUWUNEL_ALLOW_CHECK_FOR_UPDATES: "false"
      TUWUNEL_TRUSTED_SERVERS: "[]"
      TUWUNEL_LOG: "warn"
    volumes:
      - tuwunel-test-data:/var/lib/tuwunel
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8008/_matrix/client/versions || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 20

volumes:
  tuwunel-test-data:
```

Verify locally on both schemes:

```bash
docker compose -f docker-compose.test.yml up -d
until curl -sf http://localhost:8008/_matrix/client/versions; do sleep 2; done
xcodebuild test -scheme MatronIntegrationTests    -destination 'platform=iOS Simulator,name=iPhone 15'
xcodebuild test -scheme MatronMacIntegrationTests -destination 'platform=macOS'
docker compose -f docker-compose.test.yml down -v
```

Both schemes should now pass. Commit:

```bash
git add docker-compose.test.yml
git commit -m "test(integration): docker-compose tuwunel homeserver for integration tests"
```

- [ ] **Step 4: Wire CI (two-platform matrix)**

The repo's CI is GitHub Actions (per Phase 1's `.github/workflows/ci.yml`). Add a parallel workflow `.github/workflows/integration.yml` that runs the integration suite on both iOS Simulator and macOS host via a matrix:

```yaml
name: integration

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  integration:
    runs-on: macos-14
    timeout-minutes: 30
    strategy:
      fail-fast: false
      matrix:
        platform: [ios, macos]
        include:
          - platform: ios
            scheme: MatronIntegrationTests
            destination: 'platform=iOS Simulator,name=iPhone 15'
          - platform: macos
            scheme: MatronMacIntegrationTests
            destination: 'platform=macOS'
    steps:
      - uses: actions/checkout@v4

      - name: Set up Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Start tuwunel
        run: docker compose -f docker-compose.test.yml up -d

      - name: Wait for homeserver
        run: |
          for i in {1..60}; do
            if curl -sf -o /dev/null -w "%{http_code}" http://localhost:8008/_matrix/client/versions | grep -q 200; then
              echo "homeserver is up"
              exit 0
            fi
            sleep 2
          done
          echo "homeserver did not come up within 120s"
          docker compose -f docker-compose.test.yml logs
          exit 1

      - name: Run integration tests (${{ matrix.platform }})
        run: |
          xcodebuild test \
            -scheme ${{ matrix.scheme }} \
            -destination '${{ matrix.destination }}' \
            -resultBundlePath integration-results-${{ matrix.platform }}.xcresult \
            | xcpretty
          exit ${PIPESTATUS[0]}

      - name: Tear down
        if: always()
        run: docker compose -f docker-compose.test.yml down -v

      - name: Upload xcresult on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: integration-results-${{ matrix.platform }}
          path: integration-results-${{ matrix.platform }}.xcresult
```

Both matrix jobs run against the same `docker-compose.test.yml` tuwunel instance (each job runs on its own runner so the homeserver lifecycle is per-job — no shared state). Verify in a PR — both matrix jobs run green. Commit:

```bash
git add .github/workflows/integration.yml
git commit -m "ci(integration): GitHub Actions matrix running tuwunel + xcodebuild test on iOS + macOS"
git push
```

---

## Phase 7 acceptance

1. All 14 tasks (Tasks 1, 1.5, 2, 3, 4, 4b, 5–12) committed and pushed.
2. CI green; all snapshot tests pass on both Mac and iOS schemes; the new integration workflow (Task 12) is green on both matrix legs (`ios` and `macos`).
3. **Both** App Store Connect records complete (iOS + Mac), each with metadata, screenshots, privacy policy URL, App Privacy disclosures, and `ITSAppUsesNonExemptEncryption=NO`.
4. TestFlight (iOS) and Mac App Store TestFlight equivalent (Mac) builds available; internal testers can install both.
5. `docs/manual-tests.md` (Task 10) regression checklist passes on both builds — the iOS section on the TestFlight build, the Mac section on the Mac App Store build, plus the cross-platform smoke section run once with both apps signed in to the same account.
6. Both apps submitted for App Review (acceptance ≠ approval — that's Apple's call, per platform independently).

---

## Plan self-review

- **§3 Module structure & DesignSystem:** DesignSystem already lives in `MatronShared/Sources/DesignSystem/` from Phase 1's reorg — Phase 7 just declares the canonical tokens there (Task 1) and enforces token usage on **both** apps. Task 1.5's `matronCodeBg` → `matronCodeBackground` rename is now an in-MatronShared symbol rename (the earlier review note about it being a cross-module reconciliation is historical and called out as such). Task 2's per-file sweep enumerates files in **both** `Matron/Features/` and `MatronMac/Features/`, and the verification grep scans both feature trees. Cross-platform rendering primitives are swept in `MatronShared/` once and inherited by both apps, so `MatronMac/Features/Chat/Rendering/...` has no files to sweep. Task 5 Step 2 references the actual extension methods (no fictional `MatronTypography`/`MatronColors` types). Status indicators use `Color.matronDanger` / `Color.matronAccent`, not raw `.red` / `.green`, in both the iOS Notifications view and the Mac Notifications tab.
- **§3 Mac app icon set:** Task 3 generates the Mac icon set with the correct size matrix (16/32/64/128/256/512/1024 at @1x and @2x), driven from the same single `docs/app-store/icon-source.svg` master that produces the iOS set, committed under `MatronMac/Resources/Assets.xcassets/AppIcon.appiconset/`.
- **§5.5 Bot profile:** Task 5.
- **§5.6 Settings:** Task 4 (iOS list-of-sections shape, all five sections) + Task 4b (`MacSettingsView` with five `TabView` tabs in the native `Settings { }` Preferences scene, sharing `SettingsViewModel` from `MatronShared/Sources/ViewModels/`, wired into `MatronMacApp.Settings { MacSettingsView() }` so `⌘,` opens it). Both surfaces use the same design tokens.
- **§5.9 Mac chrome:** menu-bar shortcuts (`⌘N`, `⌘F`, `⌘K`, `⌘⇧S`, `⌘+/-/0`, `⌘,`), drag-and-drop attachments, sidebar toggle, window-position restore, and Settings Preferences window are all explicitly verified in the Mac per-App-Store-build regression section of `docs/manual-tests.md` (Task 10).
- **§7 E2EE UX:** Existing DeviceSettingsView from Phase 3 plugs into the new iOS SettingsView hierarchy; the equivalent "This Device" tab in `MacSettingsView` (Task 4b) reuses the same recovery-key + verification flows.
- **§8 Push notifications UX:** iOS NotificationSettingsView (Task 4) and Mac Notifications tab (Task 4b) — privacy and accent colours via tokens on both.
- **§10 Testing strategy:**
  - Task 12 implements the spec-mandated single happy-path integration test as **two test targets** (`MatronIntegrationTests` on iOS, `MatronMacIntegrationTests` on macOS), both consuming the same canonical `MatronIntegrationTests/HappyPathTests.swift` source via `project.yml`'s `sources:` reuse.
  - GitHub Actions workflow uses a `strategy.matrix` over `[ios, macos]` so both schemes run on every PR.
  - Task 10 creates `docs/manual-tests.md` (NEW) with the three spec-mandated sections: **iOS per-TestFlight** (SAS verification with a real other device, push on physical device, attachment picker end-to-end), **Mac per-App-Store-build** (menu-bar shortcuts, sidebar toggle, window-position restore, drag-and-drop, Preferences `⌘,`, Mac push on real Mac, tap-notification-focuses-window), and **cross-platform smoke** (same-account dual sign-in, cross-platform message round-trip, SAS verify Mac from iOS, recovery key from iCloud Keychain on Mac).
  - Snapshot tests reuse the Phase 2 cross-platform 6-variant matrix (`{iOS, Mac} × {light, dark, accessibility5}`) — Task 1 Step 5 explicitly consolidates rather than reinvents variants; Task 4b adds Mac-only `MacSettingsView` snapshots in the Mac scheme.
- **§12 License & legal:**
  - Privacy policy + disclosures (Task 7); the public privacy URL is sourced from `MatronPrivacyPolicyURL` in **both** `Matron/Resources/Info.plist` and `MatronMac/Resources/Info.plist` (Task 7 Step 3); both `AboutView` (iOS) and the `AboutTab` in `MacSettingsView` (Mac, Task 4b) read the same key. One privacy-policy URL serves both apps.
  - `Acknowledgements.plist` is generated reproducibly via `LicensePlist` (Task 4 Step 6) and bundled in **both** apps; both `LicensesView` (iOS) and the Mac equivalent decode it identically.
  - **Two App Store Connect records** (Task 11 Steps 1a/1b): iOS + Mac, each with its own provisioning profile, screenshots (iOS sizes vs Mac sizes), and privacy disclosures (same content). `ITSAppUsesNonExemptEncryption=NO` set in **both** Info.plist files.
  - Mac builds submitted via App Store Connect upload (`xcodebuild -exportArchive` → `xcrun altool --upload-app`) **don't need a separate `xcrun notarytool` step** — App Store Connect notarizes as part of submission (Task 11 Step 1b).
- App icon source art is committed as `docs/app-store/icon-source.svg` before the generator runs (Task 3 Step 0), and drives **both** the iOS and Mac icon sets (Task 3 Steps 1 + 2), so both icon sets are reproducible from a single master.
- No placeholders. App Store Connect tasks are intentionally manual — you can't fully automate the metadata form, on either platform.
- Phase 7 closes out the spec coverage: every numbered section in the design spec has at least one task across phases 1–7, including spec §10's integration-test mandate on both platforms and spec §12.5's two-record App Store submission requirement.
