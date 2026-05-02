# Matron iOS — Phase 7 (Polish & App Store Readiness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 6 (Search) merged and CI green.

**Goal:** Take the app from feature-complete to App Store-submittable. Build out the full Settings screen, finish the Bot Profile screen, do a design system pass (colours, typography, spacing tokens), accessibility audit, app icon + launch screen, App Store assets (screenshots, descriptions, privacy policy, App Privacy disclosures), TestFlight setup, and final QA pass.

**Architecture:** Mostly UI + assets work. The DesignSystem module gets its semantic tokens. A `PrivacyPolicy` markdown lives in `Resources/`. App Store Connect setup happens externally with copy/screenshots committed in `docs/app-store/`.

**Tech Stack:** Same as prior phases. No new code dependencies.

**Reference:** Spec §5.5 (bot profile), §5.6 (settings), §12 (license & legal — App Privacy disclosures).

---

## File structure (Phase 7 deliverables)

```
matron-iOS-app/
├── Matron/Features/Settings/
│   ├── SettingsView.swift                  NEW (replaces ad-hoc DeviceSettings)
│   ├── SettingsViewModel.swift             NEW
│   ├── AccountSettingsView.swift           NEW
│   ├── NotificationSettingsView.swift      NEW
│   ├── ServerSettingsView.swift            NEW
│   ├── AboutView.swift                     NEW
│   └── LicensesView.swift                  NEW
├── Matron/Features/BotProfile/
│   └── BotProfileView.swift                MODIFIED — full styling, avatar fetch
├── MatronShared/Sources/DesignSystem/
│   ├── Colors.swift                        MODIFIED — semantic tokens, dark mode
│   ├── Typography.swift                    MODIFIED — type ramp
│   ├── Spacing.swift                       NEW — spacing tokens
│   └── ButtonStyles.swift                  NEW — primary / secondary / destructive
├── Matron/Resources/
│   ├── Assets.xcassets/AppIcon.appiconset  NEW — full icon set
│   ├── Assets.xcassets/AccentColor         MODIFIED
│   ├── PrivacyPolicy.md                    NEW
│   └── Acknowledgements.plist              NEW — generated SPM license list
├── docs/app-store/
│   ├── description-en.md                   NEW — listing copy
│   ├── promotional-text.md                 NEW
│   ├── keywords.txt                        NEW
│   ├── screenshots/                        NEW — 6.7" / 6.1" / 5.5" sets
│   ├── privacy-policy.md                   NEW — public version
│   └── app-privacy-disclosures.md          NEW — JSON-ish for App Store Connect
├── fastlane/                               OPTIONAL — automated build/upload
│   ├── Appfile
│   ├── Fastfile
│   └── Snapfile
└── manual-tests.md                         MODIFIED — final regression checklist
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

- [ ] **Step 5: Snapshot tests for each button style + colour swatch**

Add snapshot tests (light + dark mode) under `DesignSystemSnapshotTests/`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/
git commit -m "feat: design system tokens (colours, typography, spacing) + button styles"
git push
```

---

### Task 2: Apply tokens across the app

**Files:**
- Modify: every `View` with hardcoded `Color`, `Font`, padding values

- [ ] **Step 1: Search-and-replace pass**

Find: `.font(.body)`, `.foregroundStyle(.secondary)`, `Color(.systemGray6)`, `padding(8)`, raw `Color.blue`, etc. Replace with the semantic tokens defined in Task 1.

Don't aim for a perfect sweep — focus on:
- Onboarding views
- ChatList + ChatRow
- ChatView + Composer + TimelineItemView
- Settings views (after Task 4)

- [ ] **Step 2: Visual regression check**

Re-run all snapshot tests; expect failures, eyeball each diff, accept the new baseline if it looks better, revert if not.

```bash
cd MatronShared && swift test --filter SnapshotTests
```

- [ ] **Step 3: Commit per logical chunk**

Don't commit one giant blob; commit per feature group:

```bash
git commit -m "style: apply design tokens to onboarding"
git commit -m "style: apply design tokens to chat list"
git commit -m "style: apply design tokens to chat view + composer"
git commit -m "style: apply design tokens to settings"
git push
```

---

### Task 3: App icon + accent colour

**Files:**
- Create: `Matron/Resources/Assets.xcassets/AppIcon.appiconset/` (full icon set)
- Modify: `Matron/Resources/Assets.xcassets/AccentColor.colorset/`

- [ ] **Step 1: Generate the full icon set**

Need: 1024×1024 master + auto-generated sizes for iPhone (60pt @2x/@3x), Settings (29pt @2x/@3x), Spotlight (40pt @2x/@3x), Notification (20pt @2x/@3x), iPad sizes if you intend to ship iPad. Use a tool like `bakery` (`brew install bakery`) or `Icon Set Creator` to generate from one master.

Master design: simple monogram or wordmark. Recommend a flat single-colour-on-tint design over photographic — works at 20pt and ages well.

- [ ] **Step 2: Set accent colour**

In the `AccentColor` asset, set the value to your chosen brand colour (light + dark variants).

- [ ] **Step 3: Verify**

Build to a device. Long-press the home-screen icon — looks crisp. Open Settings → App → ensure all sizes render.

- [ ] **Step 4: Commit**

```bash
git add Matron/Resources/Assets.xcassets/
git commit -m "feat: app icon set + accent colour"
git push
```

---

### Task 4: Full SettingsView

**Files:**
- Create: `Matron/Features/Settings/SettingsView.swift`
- Create: `Matron/Features/Settings/SettingsViewModel.swift`
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
        status == .denied ? .red : .green
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
    var body: some View {
        Form {
            Section {
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            }
            Section {
                Link("Privacy policy", destination: URL(string: "https://matron.example.com/privacy")!)
                Link("Source code", destination: URL(string: "https://github.com/matronhq/matron-iOS-app")!)
            }
        }
        .navigationTitle("About")
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "plist"),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("Licenses unavailable.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Licenses")
    }
}
```

- [ ] **Step 6: Generate Acknowledgements**

Use a script to dump SPM dependency licenses:

```bash
swift package describe --type json > Acknowledgements.json
# Convert to a plist or simple text via a script you write once.
```

(Manual fallback: list each SPM dep + license in `Acknowledgements.plist` by hand.)

- [ ] **Step 7: Wire SettingsView into chat list**

In `ChatListView`, add a Settings toolbar button that pushes `SettingsView`.

- [ ] **Step 8: Commit**

```bash
git add Matron/Features/Settings/ Matron/Resources/Acknowledgements.plist
git commit -m "feat: complete Settings hierarchy (Account, Notifications, Server, About, Licenses)"
git push
```

---

### Task 5: Bot profile polish

**Files:**
- Modify: `Matron/Features/BotProfile/BotProfileView.swift`

- [ ] **Step 1: Add avatar fetch**

If the bot has an `avatarURL` (mxc://), fetch via `MediaService` (introduce in MatronShared if not already) and render as a real image. Cache in-memory.

- [ ] **Step 2: Improve typography + spacing using design tokens**

Use `MatronSpacing`, `MatronTypography`, `MatronColors` throughout.

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
  - Test at sizes `.xSmall`, `.large` (default), `.xxxLarge`, and `.accessibility5`.
  - Snapshot tests in DesignSystem already cover S/L/XXXL — extend with `.accessibility5`.
  - Fix any clipped text or broken layouts.

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

- [ ] **Step 3: Commit**

```bash
git add Matron/Resources/PrivacyPolicy.md docs/app-store/
git commit -m "docs: privacy policy + App Privacy disclosures"
git push
```

---

### Task 8: App Store listing copy + screenshots

**Files:**
- Create: `docs/app-store/description-en.md`
- Create: `docs/app-store/promotional-text.md`
- Create: `docs/app-store/keywords.txt`
- Create: `docs/app-store/screenshots/` (PNG files)

- [ ] **Step 1: Description (≤ 4000 chars)**

Draft a short product pitch. Lead with what makes Matron different — bot-first chat, your own homeserver, end-to-end encrypted.

- [ ] **Step 2: Promotional text (≤ 170 chars)**

E.g. "A native iOS Matrix client built for talking to AI bots. End-to-end encrypted. Bring your own homeserver."

- [ ] **Step 3: Keywords (≤ 100 chars total, comma-separated)**

E.g. `matrix,chat,bot,e2ee,encryption,ai,claude,homeserver,messaging,private`

- [ ] **Step 4: Screenshots**

Required sizes: 6.7" (iPhone 15 Pro Max), 6.5" (iPhone 11 Pro Max), 5.5" (iPhone 8 Plus).

Use `xcrun simctl io <DEVICE> screenshot screenshot.png` from the simulator. Capture five screens:
1. Chat list with several bots and recency grouping
2. Chat view with markdown + code block + tool-call card
3. Composer with slash palette open
4. Ask-user sheet with choice input
5. Settings → Device with verified state

Optional: caption overlays (use Sketch/Figma + a script).

- [ ] **Step 5: Commit**

```bash
git add docs/app-store/
git commit -m "docs: App Store listing copy + screenshots (6.7\"/6.5\"/5.5\")"
git push
```

---

### Task 9: Fastlane (optional but recommended) for TestFlight uploads

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
- Modify: `manual-tests.md`

- [ ] **Step 1: Add a comprehensive regression checklist for v1.0**

```markdown
## v1.0 release regression

Run the entire checklist (Phases 1–7) on a TestFlight build, on a physical device, against a clean homeserver. Anything that fails blocks the release.

### Smoke

- [ ] Cold install → sign-in → first-device verification → chat list → start a chat → send a message → response renders → push notification arrives → tap notification → opens correct chat.

### Phases 1–6 checklists

- [ ] Re-run all manual checks added in earlier phases.

### Polish

- [ ] App icon present on Home Screen at every size.
- [ ] App launches in <3 seconds on iPhone 12 or newer.
- [ ] No console warnings in Xcode about layout, missing assets, or deprecated APIs.
- [ ] All snapshot tests pass after design token application.
- [ ] VoiceOver navigation through chat list, chat view, settings — every element has a sensible label.
- [ ] Dynamic Type tested at `.accessibility3` — no clipped text on any major screen.
- [ ] Light + dark mode visually consistent.
- [ ] Privacy policy link in About opens.
```

- [ ] **Step 2: Commit**

```bash
git add manual-tests.md
git commit -m "docs: v1.0 release regression checklist"
git push
```

---

### Task 11: TestFlight first build + submission

**Files:** none (App Store Connect work)

- [ ] **Step 1: Set up App Store Connect**

- Create the app in App Store Connect with bundle ID `chat.matron.app`.
- Fill in metadata from `docs/app-store/`.
- Upload screenshots.
- Set Privacy Policy URL.
- Fill in App Privacy disclosures from `docs/app-store/app-privacy-disclosures.md`.
- Set encryption export compliance: `ITSAppUsesNonExemptEncryption = false` (we use only standard E2EE via the SDK; declare exempt).

- [ ] **Step 2: Run `fastlane beta`**

```bash
fastlane beta
```

Expected: build uploads, processed, available in TestFlight within ~30 minutes. Internal testers can install.

- [ ] **Step 3: Internal testing (1–2 weeks)**

Recruit 5–10 internal testers. Triage any reports.

- [ ] **Step 4: Submit for App Review**

When confident, submit for App Review from App Store Connect.

- [ ] **Step 5: Document the release in the repo**

```bash
git tag v1.0.0
git push --tags
```

Add a `CHANGELOG.md` entry.

```bash
git commit -m "chore: tag v1.0.0"
```

---

## Phase 7 acceptance

1. All 11 tasks committed and pushed.
2. CI green; all snapshot tests pass.
3. App Store Connect listing complete.
4. TestFlight build available; internal testers can install and use.
5. Final regression checklist passes on TestFlight build.
6. App submitted for App Review (acceptance ≠ approval — that's Apple's call).

---

## Plan self-review

- **§5.5 Bot profile:** Task 5.
- **§5.6 Settings:** Task 4 (covers all five sections).
- **§7 E2EE UX:** Existing DeviceSettingsView from Phase 3 plugs into the new SettingsView hierarchy.
- **§8 Push notifications UX:** NotificationSettingsView (Task 4).
- **§12 License & legal:** Privacy policy + disclosures (Task 7), encryption export compliance flagged in Task 11.
- No placeholders. App Store Connect tasks are intentionally manual — you can't fully automate the metadata form.
- Phase 7 closes out the spec coverage: every numbered section in the design spec has at least one task across phases 1–7.
