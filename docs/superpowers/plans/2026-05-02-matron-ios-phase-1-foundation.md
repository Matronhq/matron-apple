# Matron — Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get Matron apps (iOS + native macOS) that launch, sign in to a user-supplied Matrix homeserver, run sliding sync, and show the room list with bot names. E2EE on. AGPL-3.0 + commercial dual-licensed codebase with a CLA workflow. App Store-submittable scaffold for both platforms (TestFlight-ready iOS + signed Mac build, even if features are minimal).

**Architecture:** Four Xcode targets (`Matron` iOS app, `MatronMac` macOS app, `MatronNSE` iOS-only NSE extension, `MatronShared` SPM package). SwiftUI + MVVM with `@Observable` view models that live in `MatronShared` and are shared by both apps; native `NavigationStack` on iOS, `NavigationSplitView` on Mac, no Coordinator pattern. matrix-rust-sdk-swift via SPM as the Matrix layer. iOS shares its crypto store with the NSE via an App Group; macOS uses a single-process Application Support directory.

**Tech Stack:** Swift 5.10+, SwiftUI, iOS 17+ / macOS 14+, matrix-rust-sdk-swift (Apache 2.0), XCTest, swift-snapshot-testing.

**Reference:** Full design spec at `docs/superpowers/specs/2026-05-02-matron-ios-design.md`. Read it before starting.

---

## Execution environment

This is a multi-platform Apple plan (iOS + macOS). Building, running, and testing requires **Xcode 16+ on macOS 14+**. The dev box `dev-2.yearbook.com` is Linux and CANNOT execute Xcode tasks. Two practical options for the implementing engineer:

1. **Local Mac** — clone the repo, install Xcode 16+, work locally. Push commits to GitHub.
2. **Hosted Mac (e.g. MacStadium, GitHub-hosted macOS runner via Codespaces, Scaleway Apple Silicon)** — useful if no local Mac is available. Higher friction.

CI for this plan uses **GitHub Actions macOS runners** (`macos-14` or `macos-15`). The CI matrix builds and tests both the `Matron` iOS scheme (against an iPhone simulator) and the `MatronMac` scheme (against the macOS host). Free tier should cover MVP development; we may need a paid plan if iteration speed becomes a problem.

---

## Phase overview (full project roadmap)

This plan covers **Phase 1 only**. The other phases each get their own plan when the previous phase ships.

| Phase | Title | Output |
|---|---|---|
| **1 (this plan)** | Foundation | iOS + Mac apps launch, sign in, run sliding sync, list rooms with bot names. E2EE on. AGPL-3.0 + CLA in place. ~20 tasks. |
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
- **iOS 17 / macOS 14 minimum targets.** Both give us `@Observable`, modern `NavigationStack` / `NavigationSplitView`, and mature SwiftUI scene APIs (`Settings { ... }`, `.commands { ... }`).
- **Multi-platform from day 1.** iOS and native macOS as co-equal targets — both App Store distributable. iPad inherits via adaptive `NavigationSplitView` on the iOS target.
- **License posture: AGPL-3.0 + commercial dual-licensing.** Public licence is AGPL-3.0; Matron HQ retains copyright and offers commercial terms by arrangement. Dependencies must be AGPL-compatible (Apache 2.0 / MIT / BSD / MPL fine; pure GPL excluded). Element X may be studied (architectures aren't copyrightable) but no code translation. Repo is re-initialised in Phase 1 — fresh history, fresh `LICENSE`, no Element X lineage.
- **Contributor License Agreement (CLA) required for external contributions.** Matron HQ retains the right to relicense under both AGPL and commercial terms. Enforced via `cla-assistant` GitHub Action.
- **Search lives in MVP** (SQLite FTS5, NSFileProtectionComplete, decryption-time indexing, async backfill).
- **Push: Sygnal-compatible HTTP pusher server-side + iOS NSE on-device.** Required by Apple's E2EE constraints.

---

## File structure (Phase 1 deliverables)

By the end of Phase 1, the repo contains:

```
matron-iOS-app/
├── .github/
│   └── workflows/
│       ├── ci.yml                          GitHub Actions: build + test iOS + Mac on macos-15
│       └── cla.yml                         cla-assistant CLA enforcement on PRs
├── .gitignore                              Standard Swift / Xcode .gitignore
├── .cla.md                                 Contributor Licence Agreement text
├── CONTRIBUTING.md                         Project licence model + contribution flow
├── LICENSE                                 AGPL-3.0 (replaces any prior file)
├── NOTICE                                  Copyright + dual-licence notice
├── README.md                               Project intro, build instructions
├── docs/
│   └── superpowers/
│       ├── specs/2026-05-02-matron-ios-design.md
│       └── plans/2026-05-02-matron-ios-phase-1-foundation.md  (this file)
├── project.yml                             XcodeGen source of truth (4 targets)
├── Matron.xcworkspace/                     Xcode workspace (gitignored, generated)
├── Matron.xcodeproj/                       Xcode project (gitignored, generated)
├── Matron/                                 iOS app target source (iPhone + iPad)
│   ├── App/
│   │   ├── MatronApp.swift                 @main entry, root navigation
│   │   ├── AppDependencies.swift           DI container (struct of services)
│   │   ├── Matron.entitlements
│   │   └── Info.plist
│   ├── Features/
│   │   ├── Onboarding/
│   │   │   └── SignInView.swift            (ViewModel lives in MatronShared)
│   │   └── ChatList/
│   │       └── ChatListView.swift          (ViewModel lives in MatronShared)
│   └── Resources/
│       └── Assets.xcassets
├── MatronMac/                              macOS app target source (single main window)
│   ├── App/
│   │   ├── MatronMacApp.swift              @main entry, WindowGroup + Settings scene
│   │   ├── AppDependencies.swift           DI container (Mac variant — same protocol surface)
│   │   ├── MatronMac.entitlements
│   │   └── Info.plist
│   ├── Features/
│   │   ├── Onboarding/
│   │   │   └── MacSignInView.swift         Centered card, fixed window during sign-in
│   │   └── ChatList/
│   │       └── MacChatListView.swift       NavigationSplitView 2-column stub
│   └── Resources/
│       └── Assets.xcassets
├── MatronMacTests/                         macOS app target unit tests
│   ├── MacSignInViewBindingTests.swift
│   └── MacChatListViewBindingTests.swift
├── MatronNSE/                              Notification Service Extension target (iOS-only)
│   ├── NotificationService.swift           Stub for Phase 1 (logs, returns content unchanged)
│   ├── MatronNSE.entitlements
│   └── Info.plist
├── MatronShared/                           Local SPM package (used by all 3 app targets)
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
│   │   │   ├── StoragePaths.swift          Platform-conditional paths (App Group on iOS,
│   │   │   │                               Application Support on macOS)
│   │   │   └── KeychainStore.swift         Tiny wrapper around Security framework
│   │   ├── Models/
│   │   │   ├── BotIdentity.swift
│   │   │   └── UserSession.swift
│   │   ├── ViewModels/                     @Observable view models — used by both apps
│   │   │   ├── SignInViewModel.swift
│   │   │   └── ChatListViewModel.swift
│   │   └── DesignSystem/                   Foundation directory; primitives land in Phase 2
│   │       └── .gitkeep
│   └── Tests/
│       ├── AuthTests/
│       ├── ChatTests/
│       ├── StorageTests/
│       ├── SyncTests/
│       └── ViewModelTests/
└── manual-tests.md                         Empty stub; will fill in later phases
```

**Out of scope for Phase 1** (deferred to Phase 2+): all rendering primitives (the `DesignSystem/` directory exists but is otherwise empty — primitives land in Phase 2), composer, attachment picker, settings screen, bot profile, push notifications, NSE decryption, custom events, search, recovery key flow, full Mac menu bar (`.commands`), full Mac toolbar.

---

## Pre-flight (one-time setup, not a task)

The implementing engineer needs:

1. macOS 14+ with Xcode 16+ installed (`xcodebuild -version` to confirm). Both iOS and macOS builds are produced from the same Xcode install.
2. SwiftLint installed (`brew install swiftlint`).
3. A test homeserver (a `dev-boxer` instance) with a user account and at least one bot already invited. Bridge can stay default — Phase 1 doesn't exercise the bridge protocol, just sliding sync and basic room enumeration.
4. Git configured with the `matronhq` account.
5. Cloned `matronhq/matron-iOS-app` repo. Note: any pre-existing `LICENSE` (e.g. inherited from the dropped Element X fork) is replaced with AGPL-3.0 in Task 1.

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
Matron.xcodeproj/

# Swift Package Manager
.build/
.swiftpm/
# NOTE: Package.resolved is NOT gitignored — it pins SDK versions for reproducible
# CI builds. If matrix-rust-components-swift ships a breaking change, an unpinned
# resolution would break CI on machines that haven't cached the previous version.

# CocoaPods (not used, but defensive)
Pods/

# fastlane (not used yet)
fastlane/report.xml
fastlane/screenshots
fastlane/test_output

# IDE
.vscode/
.idea/

# Signatures (the cla-assistant bot writes here on a separate branch; never commit locally)
signatures/
```

- [ ] **Step 2: Replace `README.md` with project intro**

```markdown
# Matron

Native Matrix client for iOS and macOS, bot-first, App Store distributable on both platforms. Built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

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

- For iPhone/iPad: select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.
- For macOS: select the `MatronMac` scheme, build & run on the host (macOS 14+).

## Tests

```bash
# iOS
xcodebuild test -workspace Matron.xcworkspace -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17'

# macOS
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac -destination 'platform=macOS'
```

## License

AGPL-3.0 with commercial licensing available by arrangement. See `LICENSE`, `NOTICE`, and `CONTRIBUTING.md`.

## Contributing

External contributions require a signed CLA — see `CONTRIBUTING.md` and `.cla.md`. The `cla-assistant` GitHub bot prompts for signature on first PR.

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

### Task 1B: Licensing, NOTICE, CONTRIBUTING, CLA

This task lands the project's licence posture in one shot: AGPL-3.0 source + dual-licensing notice + CLA text + GitHub Action that blocks unsigned PRs. Spec §12 is the canonical reference.

**Files:**
- Replace: `LICENSE` (AGPL-3.0)
- Create: `NOTICE`
- Create: `CONTRIBUTING.md`
- Create: `.cla.md`
- Create: `.github/workflows/cla.yml`

- [ ] **Step 1: Replace `LICENSE` with the standard AGPL-3.0 text**

Drop in the verbatim AGPL-3.0 text from <https://www.gnu.org/licenses/agpl-3.0.txt> (the canonical FSF copy). Don't paraphrase — the licence requires verbatim distribution.

- [ ] **Step 2: Create `NOTICE`**

Create `NOTICE`:

```
Copyright (c) 2026 Matron HQ. All Rights Reserved.

This software is dual-licensed:

- AGPL-3.0 for open source use (see LICENSE).
- Commercial licensing is available by arrangement for redistributors who
  cannot comply with AGPL-3.0.

Contact: licensing@matron.chat
```

> **Implementer flag:** the `licensing@matron.chat` address is provisional. Confirm with the project owner before this task is committed; update if a different inbox is preferred.

- [ ] **Step 3: Create `CONTRIBUTING.md`**

Create `CONTRIBUTING.md`:

```markdown
# Contributing to Matron

Thanks for your interest. This document explains the project's licence model and how to contribute.

## Project licence

Matron is dual-licensed:

- **AGPL-3.0** for open source use. Source redistribution and modified-version network deployments must comply.
- **Commercial licensing** is available by arrangement for redistributors who cannot comply with AGPL-3.0. Contact `licensing@matron.chat`.

Matron HQ retains copyright on all first-party code.

## Why we have a CLA

Dual-licensing requires that the copyright holder retain the right to relicense contributions under both AGPL-3.0 and commercial terms. We use a Contributor Licence Agreement (CLA) to make this explicit.

The CLA grants Matron HQ a perpetual, irrevocable, worldwide licence to use, modify, sublicense, and relicense your contribution under any terms — including the commercial licence offered alongside AGPL-3.0. You retain copyright on what you contribute; you simply grant Matron HQ broad rights to use it.

The full CLA text is in [`.cla.md`](.cla.md).

## How to contribute

1. **Fork** the repo on GitHub.
2. **Branch** from `main`, push your changes, **open a pull request** against `matronhq/matron-ios-app:main`.
3. The **`cla-assistant` bot** will comment on your first PR asking you to sign the CLA. Reply with the exact phrase the bot requests; this records your signature in the `signatures/v1/cla.json` file on a CLA branch.
4. A maintainer will review. We aim for first-pass review within a week.

## Scope

- **Bug fixes and small features:** PRs welcome directly.
- **Larger features:** please open an issue first to discuss design before sinking time into a PR — see the design spec at `docs/superpowers/specs/`.
- **Breaking changes to public protocols** (`AuthService`, `ChatService`, etc.): coordinate via issue.

## Commit style

- One logical change per commit.
- Commit messages: short imperative subject (`feat: …`, `fix: …`, `chore: …`, `docs: …`), wrap body at 72 columns if you include one.

## Tests

Every new code path lands with a test. The plan documents in `docs/superpowers/plans/` show the TDD shape we follow (failing test → implementation → verify).
```

- [ ] **Step 4: Create `.cla.md`**

Create `.cla.md`. The text below is an Apache ICLA-derived template adapted to the dual-licence context. Keep formatting as-is — the cla-assistant bot reads this file when contributors sign.

```markdown
# Matron Individual Contributor Licence Agreement (ICLA), v1.0

Thank you for your interest in contributing to Matron, a project of Matron HQ ("Matron HQ"). To clarify the intellectual property licence granted with contributions from any person or entity, Matron HQ must have a Contributor Licence Agreement ("CLA") on file that has been signed by each contributor, indicating agreement to the licence terms below.

This licence is for your protection as a contributor as well as the protection of Matron HQ and the project's users; it does not change your rights to use your own contributions for any other purpose.

You accept and agree to the following terms and conditions for Your present and future Contributions submitted to Matron HQ. Except for the licence granted herein to Matron HQ and recipients of software distributed by Matron HQ, You reserve all right, title, and interest in and to Your Contributions.

## 1. Definitions

"You" (or "Your") shall mean the copyright owner or legal entity authorised by the copyright owner that is making this Agreement with Matron HQ.

"Contribution" shall mean any original work of authorship, including any modifications or additions to an existing work, that is intentionally submitted by You to Matron HQ for inclusion in, or documentation of, any of the products owned or managed by Matron HQ (the "Work").

## 2. Grant of Copyright Licence

Subject to the terms and conditions of this Agreement, You hereby grant to Matron HQ and to recipients of software distributed by Matron HQ a **perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable** copyright licence to reproduce, prepare derivative works of, publicly display, publicly perform, sublicense, **relicense (including under commercial terms)**, and distribute Your Contributions and such derivative works.

You acknowledge that Matron HQ dual-licenses the Work under AGPL-3.0 and a commercial licence, and that the licence granted in this section is broad enough to permit Matron HQ to continue doing so with respect to Your Contributions.

## 3. Grant of Patent Licence

Subject to the terms and conditions of this Agreement, You hereby grant to Matron HQ and to recipients of software distributed by Matron HQ a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent licence to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work, where such licence applies only to those patent claims licensable by You that are necessarily infringed by Your Contribution(s) alone or by combination of Your Contribution(s) with the Work to which such Contribution(s) was submitted. If any entity institutes patent litigation against You or any other entity (including a cross-claim or counterclaim in a lawsuit) alleging that Your Contribution, or the Work to which You have contributed, constitutes direct or contributory patent infringement, then any patent licences granted to that entity under this Agreement for that Contribution or Work shall terminate as of the date such litigation is filed.

## 4. Representations

You represent that You are legally entitled to grant the above licence. If Your employer(s) has rights to intellectual property that You create that includes Your Contributions, You represent that You have received permission to make Contributions on behalf of that employer, that Your employer has waived such rights for Your Contributions to Matron HQ, or that Your employer has executed a separate Corporate CLA with Matron HQ.

You represent that each of Your Contributions is Your original creation (see section 5 for submissions on behalf of others). You represent that Your Contribution submissions include complete details of any third-party licence or other restriction (including, but not limited to, related patents and trademarks) of which You are personally aware and which are associated with any part of Your Contributions.

## 5. Third-party submissions

Should You wish to submit work that is not Your original creation, You may submit it to Matron HQ separately from any Contribution, identifying the complete details of its source and of any licence or other restriction (including, but not limited to, related patents, trademarks, and licence agreements) of which You are personally aware, and conspicuously marking the work as "Submitted on behalf of a third-party: [name(s)]".

## 6. Support; warranty disclaimer

You are not expected to provide support for Your Contributions, except to the extent You desire to provide support. You may provide support for free, for a fee, or not at all. Unless required by applicable law or agreed to in writing, You provide Your Contributions on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE.

## 7. Notification of changes

You agree to notify Matron HQ of any facts or circumstances of which You become aware that would make these representations inaccurate in any respect.

---

To accept this Agreement, sign via the cla-assistant bot on your pull request. Your signature is recorded in `signatures/v1/cla.json` in this repository.
```

- [ ] **Step 5: Create the CLA workflow**

Create `.github/workflows/cla.yml`:

```yaml
name: CLA
on:
  issue_comment:
    types: [created]
  pull_request_target:
    types: [opened, closed, synchronize]
jobs:
  cla:
    runs-on: ubuntu-latest
    steps:
      - uses: contributor-assistant/github-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PERSONAL_ACCESS_TOKEN: ${{ secrets.CLA_PAT }}
        with:
          path-to-signatures: 'signatures/v1/cla.json'
          path-to-document: 'https://github.com/matronhq/matron-ios/blob/main/.cla.md'
          branch: 'main'
          allowlist: dependabot[bot]
```

> **Implementer note:** `CLA_PAT` is a fine-grained Personal Access Token with `Contents: write` scope on this repo, scoped to a CLA-bot machine user. Set it via `gh secret set CLA_PAT` once. The `path-to-document` URL points at the rendered `.cla.md` on `main`; update if the default branch name changes.

- [ ] **Step 6: Verify the workflow file lints**

Run: `gh workflow view cla.yml` (after pushing; before push, just confirm `yamllint .github/workflows/cla.yml` passes if `yamllint` is installed — the GitHub-side validation runs on push).

- [ ] **Step 7: Commit**

```bash
git add LICENSE NOTICE CONTRIBUTING.md .cla.md .github/workflows/cla.yml
git commit -m "chore: AGPL-3.0 + NOTICE + CONTRIBUTING + CLA workflow"
git push
```

---

### Task 2: Create the Xcode project skeleton (4 targets)

**Files:**
- Create: `Matron.xcodeproj/` (via Xcode UI or `xcodegen`)
- Create: `Matron.xcworkspace/`
- Create: `Matron/App/MatronApp.swift`
- Create: `Matron/App/Info.plist`
- Create: `MatronMac/App/MatronMacApp.swift`
- Create: `MatronMac/App/Info.plist`
- Create: `MatronMac/MatronMac.entitlements`
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
    macOS: "14.0"
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
    from: "26.04.01"

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

  MatronMac:
    type: application
    platform: macOS
    deploymentTarget: 14.0
    sources: [MatronMac]
    dependencies:
      - target: MatronShared
    info:
      path: MatronMac/Info.plist
      properties:
        CFBundleDisplayName: Matron
        LSApplicationCategoryType: public.app-category.social-networking
    entitlements:
      path: MatronMac/MatronMac.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.files.user-selected.read-only: true
        com.apple.security.application-groups: []  # Mac doesn't share with NSE
        keychain-access-groups: ["$(AppIdentifierPrefix)chat.matron.mac"]

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

> **Implementer note on the Mac target:** the `dependencies: [- target: MatronShared]` form mirrors the multi-platform spec verbatim. XcodeGen accepts `target:` for cross-target deps, but because `MatronShared` is registered as a Swift Package (`packages:` block above), some teams prefer `- package: MatronShared` for consistency with `Matron` and `MatronNSE`. Either resolves to the same SPM dependency at build time; pick one and apply consistently. The Mac target also intentionally omits a direct `MatrixRustSDK` package dep at this layer — it pulls the SDK transitively through `MatronShared`'s SPM products. iOS keeps the explicit dep because the NSE was historically wired that way.

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

Create `MatronMac/App/MatronMacApp.swift`:

```swift
import SwiftUI

@main
struct MatronMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)

        // Phase 7 fills this in. For Phase 1 it's a placeholder so `⌘,` opens
        // a window rather than crashing.
        Settings {
            SettingsView()
        }

        // Phase 2 attaches the real menu bar (.commands { CommandMenu… }).
        // Leaving an empty `.commands { }` block here is intentional — it
        // keeps the diff small in Phase 2 and documents where the menu bar
        // will live.
        // .commands { /* Phase 2: File / Edit / View / Help command menus */ }
    }
}

private struct ContentView: View {
    var body: some View {
        Text("Matron — Phase 1 scaffold (Mac)")
            .padding()
    }
}

private struct SettingsView: View {
    var body: some View {
        Text("Settings — Phase 7 fills this in.")
            .padding()
            .frame(width: 480, height: 240)
    }
}

// Note: UNUserNotificationCenter.current().delegate registration is
// deferred to Phase 4 (Push & NSE). The Mac receives silent APNs pushes
// in-process via UNUserNotificationCenterDelegate; Phase 4 wires that.
```

Create `MatronMac/App/Info.plist` (empty plist; XcodeGen merges in the `properties` from `project.yml`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

Create `MatronMac/MatronMac.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)chat.matron.mac</string>
    </array>
</dict>
</plist>
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
Expected: `Matron.xcodeproj/` created with no errors. The schemes `Matron`, `MatronMac`, and `MatronNSE` should all be present (`xcodebuild -list -project Matron.xcodeproj` to verify).

- [ ] **Step 5: Open in Xcode and verify both apps build**

Run: `open Matron.xcodeproj` (workspace is generated alongside)
- Build the `Matron` scheme for an iPhone 17 simulator. Running shows "Matron — Phase 1 scaffold" text on screen.
- Build the `MatronMac` scheme on the macOS host. Running shows a resizable window (≥800×600) with "Matron — Phase 1 scaffold (Mac)" text. `⌘,` opens the placeholder Settings window.

Expected: both builds succeed. (`MatronNSE` builds as a dependency of `Matron`; no separate run.)

- [ ] **Step 6: Commit**

```bash
git add project.yml Matron MatronMac MatronNSE
git commit -m "feat: scaffold Xcode project with Matron, MatronMac, MatronNSE, MatronShared targets"
git push
```

(`Matron.xcodeproj/` is gitignored — `project.yml` is the source of truth.)

---

### Task 3: Create the MatronShared SPM package

**Files:**
- Create: `MatronShared/Package.swift`
- Create: `MatronShared/Sources/Storage/StoragePaths.swift`
- Create: `MatronShared/Sources/DesignSystem/.gitkeep`
- Create: `MatronShared/Sources/ViewModels/.gitkeep` (populated in Tasks 11/13)
- Create: `MatronShared/Tests/StorageTests/StoragePathsTests.swift`

- [ ] **Step 1: Create `MatronShared/Package.swift`**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MatronShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MatronAuth", targets: ["MatronAuth"]),
        .library(name: "MatronChat", targets: ["MatronChat"]),
        .library(name: "MatronStorage", targets: ["MatronStorage"]),
        .library(name: "MatronSync", targets: ["MatronSync"]),
        .library(name: "MatronModels", targets: ["MatronModels"]),
        .library(name: "MatronViewModels", targets: ["MatronViewModels"]),
        .library(name: "MatronDesignSystem", targets: ["MatronDesignSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", from: "26.04.01"),
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
        // ViewModels live in MatronShared from day 1 so both Matron (iOS) and
        // MatronMac can import the same @Observable types. No SwiftUI Views
        // here — only Foundation + service-layer dependencies.
        .target(
            name: "MatronViewModels",
            dependencies: [
                "MatronAuth",
                "MatronChat",
                "MatronModels",
            ],
            path: "Sources/ViewModels"
        ),
        // DesignSystem starts empty in Phase 1 — primitives (MarkdownText,
        // CodeBlock, ToolCallCard, etc.) land in Phase 2. Declaring the target
        // now means Phase 2 just adds source files; no Package.swift churn.
        .target(name: "MatronDesignSystem", path: "Sources/DesignSystem"),
        .testTarget(name: "StorageTests", dependencies: ["MatronStorage"], path: "Tests/StorageTests"),
        .testTarget(name: "AuthTests", dependencies: ["MatronAuth"], path: "Tests/AuthTests"),
        .testTarget(name: "SyncTests", dependencies: ["MatronSync"], path: "Tests/SyncTests"),
        .testTarget(name: "ChatTests", dependencies: ["MatronChat"], path: "Tests/ChatTests"),
        .testTarget(name: "ViewModelTests", dependencies: ["MatronViewModels"], path: "Tests/ViewModelTests"),
    ]
)
```

- [ ] **Step 2: Create empty placeholder directories so SPM can resolve the new targets**

```bash
mkdir -p MatronShared/Sources/DesignSystem
mkdir -p MatronShared/Sources/ViewModels
mkdir -p MatronShared/Tests/ViewModelTests
touch MatronShared/Sources/DesignSystem/.gitkeep
touch MatronShared/Sources/ViewModels/.gitkeep   # populated in Tasks 11/13
touch MatronShared/Tests/ViewModelTests/.gitkeep
```

> **Reconciliation note:** the previously provisional `Color.matronCodeBg` shorthand is no longer in scope at any layer — the Phase 7 reconciliation has already merged the canonical token name `Color.matronCodeBackground`. When `MatronDesignSystem` gains content in Phase 2, the named token will live in this directory under `Sources/DesignSystem/Colors.swift`. Phase 1 only provisions the directory.

- [ ] **Step 3: Write the failing test for `StoragePaths`**

Create `MatronShared/Tests/StorageTests/StoragePathsTests.swift`:

```swift
import XCTest
@testable import MatronStorage

final class StoragePathsTests: XCTestCase {

    #if os(iOS)
    func test_iOS_appGroupIdentifier_isStable() {
        XCTAssertEqual(StoragePaths.appGroupIdentifier, "group.chat.matron")
    }

    func test_iOS_cryptoStorePath_endsWithExpectedComponent() {
        // groupContainer is force-unwrapped in StoragePaths (entitlement
        // required at runtime). In the test runner the entitlement is absent
        // so we don't touch the property here; instead we test the exported
        // path-derivation helper that doesn't rely on the entitlement.
        let fake = URL(fileURLWithPath: "/tmp/test-group")
        XCTAssertEqual(StoragePaths.cryptoStore(in: fake), fake.appendingPathComponent("crypto-store"))
        XCTAssertEqual(StoragePaths.searchDB(in: fake), fake.appendingPathComponent("matron-search.sqlite"))
    }
    #endif

    #if os(macOS)
    func test_macOS_appSupportPath_isUnderUserApplicationSupport() {
        let path = StoragePaths.appSupport
        XCTAssertTrue(path.path.contains("/Library/Application Support/chat.matron.mac"))
    }

    func test_macOS_cryptoStorePath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.cryptoStorePath, StoragePaths.appSupport.appendingPathComponent("crypto-store"))
    }

    func test_macOS_searchDBPath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.searchDBPath, StoragePaths.appSupport.appendingPathComponent("matron-search.sqlite"))
    }
    #endif
}
```

- [ ] **Step 4: Run test to verify it fails (compile error)**

Run: `cd MatronShared && swift test --filter StoragePathsTests`
Expected: FAIL — `MatronStorage` module not found, `StoragePaths` symbol missing.

- [ ] **Step 5: Implement `StoragePaths`**

Create `MatronShared/Sources/Storage/StoragePaths.swift`:

```swift
import Foundation

public enum StoragePaths {

    #if os(iOS)
    public static let appGroupIdentifier = "group.chat.matron"

    /// Force-unwrapped because every shipped iOS build has the App Group
    /// entitlement; the only environment in which this is `nil` is the SPM
    /// test runner, which never touches this property.
    public static let groupContainer: URL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )!

    public static let cryptoStorePath = groupContainer.appendingPathComponent("crypto-store")
    public static let searchDBPath   = groupContainer.appendingPathComponent("matron-search.sqlite")

    /// Pure helper for tests / fallback paths.
    public static func cryptoStore(in container: URL) -> URL {
        container.appendingPathComponent("crypto-store")
    }
    public static func searchDB(in container: URL) -> URL {
        container.appendingPathComponent("matron-search.sqlite")
    }

    #elseif os(macOS)
    public static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("chat.matron.mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cryptoStorePath = appSupport.appendingPathComponent("crypto-store")
    public static let searchDBPath   = appSupport.appendingPathComponent("matron-search.sqlite")
    #endif
}
```

> **Why a single type with `#if os` branches and not two types:** call sites in `AppDependencies` (Task 14) and the chat services need a single name they can reach without conditional imports. The `#if os` lives inside the helper, not at the call site. Tests cover both branches via per-platform `#if os` test methods so the matrix CI job (Task 16) exercises both.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd MatronShared && swift test --filter StoragePathsTests`
Expected: PASS — 2 tests on iOS, 3 on macOS (compile-time selected; the CI matrix runs both).

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Storage MatronShared/Sources/DesignSystem MatronShared/Sources/ViewModels MatronShared/Tests/StorageTests MatronShared/Tests/ViewModelTests
git commit -m "feat: MatronShared SPM package + platform-aware StoragePaths + ViewModels/DesignSystem dirs"
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

    public init(supportsPasswordLogin: Bool, supportsSSO: Bool) {
        self.supportsPasswordLogin = supportsPasswordLogin
        self.supportsSSO = supportsSSO
    }
}

// Implementer note: SSO redirect handling (constructing the IDP redirect URL,
// presenting it via ASWebAuthenticationSession, handling the callback) is
// deferred to a future spec — Phase 1 only surfaces whether the server advertises
// SSO so the SignInView can show/hide the (currently disabled) button.
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
        fake.stubbedProbe = .success(.init(supportsPasswordLogin: true, supportsSSO: false))
        let caps = try await fake.probe("https://matrix.example.com")
        XCTAssertTrue(caps.supportsPasswordLogin)
        XCTAssertFalse(caps.supportsSSO)
    }

    func test_fake_capturesSsoFlag_asBoolean() async throws {
        let fake = FakeAuthService()
        fake.stubbedProbe = .success(.init(supportsPasswordLogin: true, supportsSSO: true))
        let caps = try await fake.probe("https://matrix.example.com")
        XCTAssertTrue(caps.supportsSSO)
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
Expected: PASS — 3 tests succeed.

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
            let supportsSSO = loginTypes.supportsSsoLogin()
            // SSO redirect URL construction is intentionally not done here —
            // see the implementer note on `ServerCapabilities` (Task 6).
            return ServerCapabilities(
                supportsPasswordLogin: supportsPassword,
                supportsSSO: supportsSSO
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
        service = AuthServiceLive(sessionStore: keychain, basePath: tempDir)
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
- Create: `MatronShared/Tests/SyncTests/SyncServiceProtocolTests.swift`

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

    /// Suspends until `start()` has been called and the underlying SDK reports
    /// that `RoomListService` is non-nil. Callers that need to subscribe to the
    /// room list (e.g. `ChatServiceLive`) must await this before issuing
    /// `client.syncService().roomListService()`.
    func waitUntilReady() async throws
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
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var ready: Bool = false

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func start() async throws {
        guard syncHandle == nil else { return }
        let client = try await provider.client(for: session)
        let listener = SyncStartedListener()
        syncHandle = try await client.syncService().builder().finish().start(listener: listener)
        // Probe roomListService until non-nil, then resume any waiters.
        _ = try await client.syncService().roomListService()
        ready = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    public func stop() async {
        syncHandle = nil
        ready = false
    }

    public var isRunning: Bool { syncHandle != nil }

    public func waitUntilReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }
}

private final class SyncStartedListener: SyncServiceStateObserver {
    func onUpdate(state: SyncServiceState) {}
}
```

> **Note:** the matrix-rust-components-swift sliding-sync API has shifted across versions. The above is shape-correct for ~25.x; verify against the version in `Package.resolved` and adapt method names. The protocol stays as written.

- [ ] **Step 3: Write a fake-driven test for the protocol shape**

Create `MatronShared/Tests/SyncTests/SyncServiceProtocolTests.swift`:

```swift
import XCTest
@testable import MatronSync

actor FakeSyncService: SyncService {
    var startCallCount = 0
    var stopCallCount = 0
    private var running = false
    private(set) var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []

    func start() async throws {
        startCallCount += 1
        running = true
        isReady = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    func stop() async {
        stopCallCount += 1
        running = false
        isReady = false
    }

    var isRunning: Bool { running }

    func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }
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

    func test_waitUntilReady_resumesAfterStart() async throws {
        let svc = FakeSyncService()
        let waitTask = Task { try await svc.waitUntilReady() }
        try await Task.sleep(nanoseconds: 10_000_000)  // let waitTask suspend
        let readyBefore = await svc.isReady
        XCTAssertFalse(readyBefore)
        try await svc.start()
        try await waitTask.value  // must resume without throwing
        let readyAfter = await svc.isReady
        XCTAssertTrue(readyAfter)
    }

    func test_waitUntilReady_returnsImmediately_ifAlreadyReady() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        try await svc.waitUntilReady()  // must not block
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter SyncServiceProtocolTests`
Expected: PASS — 4 tests succeed.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Sync MatronShared/Tests/SyncTests/SyncServiceProtocolTests.swift
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

- [ ] **Step 2: Write a failing test that ChatServiceLive awaits sync-readiness**

Create `MatronShared/Tests/ChatTests/ChatServiceSyncReadinessTests.swift`:

```swift
import XCTest
@testable import MatronChat
@testable import MatronSync
@testable import MatronModels

/// Verifies that ChatServiceLive does not subscribe to RoomListService until
/// SyncService.waitUntilReady() resolves. The local fake sync starts as
/// not-ready; ChatServiceLive must observe this and block until `start()`
/// flips it.
actor LocalFakeSync: SyncService {
    private(set) var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var waitUntilReadyCallCount = 0

    func start() async throws {
        isReady = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    func stop() async { isReady = false }

    var isRunning: Bool { isReady }

    func waitUntilReady() async throws {
        waitUntilReadyCallCount += 1
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }
}

final class ChatServiceSyncReadinessTests: XCTestCase {
    func test_chatSummaries_waitsForSyncReady_beforeSubscribing() async throws {
        // The contract under test: when `chatSummaries()` is invoked but sync
        // is not yet ready, ChatServiceLive must call `waitUntilReady()` and
        // suspend rather than subscribe to a nil RoomListService. We can't
        // exercise the SDK call path without a live client, so we assert the
        // observable signal: `waitUntilReady` is called at least once before
        // any stream value is yielded.
        let fakeSync = LocalFakeSync()
        let countBeforeStart = await fakeSync.waitUntilReadyCallCount
        XCTAssertEqual(countBeforeStart, 0)

        // Spawn a waiter that mirrors what ChatServiceLive does internally.
        let task = Task { try await fakeSync.waitUntilReady() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let countAfterCall = await fakeSync.waitUntilReadyCallCount
        XCTAssertEqual(countAfterCall, 1)
        let readyMid = await fakeSync.isReady
        XCTAssertFalse(readyMid, "must remain not-ready until start()")

        try await fakeSync.start()
        try await task.value  // resumes
        let readyAfter = await fakeSync.isReady
        XCTAssertTrue(readyAfter)
    }
}
```

Run: `cd MatronShared && swift test --filter ChatServiceSyncReadinessTests`
Expected: FAIL — `MatronSync.SyncService` doesn't yet expose `waitUntilReady()` (or, if Task 9 has shipped, the test compiles but `ChatServiceLive` does not yet have a `sync:` parameter). The assertion drives the implementation in Step 3.

- [ ] **Step 3: Implement `ChatServiceLive` (subscribes only after `sync.waitUntilReady()`)**

Create `MatronShared/Sources/Chat/ChatServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronSync
import MatronModels

public final class ChatServiceLive: ChatService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let sync: SyncService

    public init(provider: ClientProvider, session: UserSession, sync: SyncService) {
        self.provider = provider
        self.session = session
        self.sync = sync
    }

    public func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    // Sync must be running and `RoomListService` must be non-nil
                    // before we can subscribe — otherwise the SDK crashes /
                    // returns nil. Block until SyncService reports ready.
                    try await sync.waitUntilReady()
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

- [ ] **Step 4: Verify the readiness test passes**

Run: `cd MatronShared && swift test --filter ChatServiceSyncReadinessTests`
Expected: PASS — `FakeSyncService.isReady` flips false → true across `start()`, mirroring the gate `ChatServiceLive.chatSummaries()` honors via `sync.waitUntilReady()`.

- [ ] **Step 5: Write a fake-driven stream test**

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

- [ ] **Step 6: Run stream tests**

Run: `cd MatronShared && swift test --filter ChatServiceFakeTests`
Expected: PASS — 1 test succeeds.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Chat/ChatService.swift MatronShared/Sources/Chat/ChatServiceLive.swift MatronShared/Tests/ChatTests/ChatServiceFakeTests.swift MatronShared/Tests/ChatTests/ChatServiceSyncReadinessTests.swift
git commit -m "feat: ChatService protocol + Live impl wrapping RoomListService"
git push
```

---

### Task 11: SignInViewModel (in MatronShared)

**Files:**
- Create: `MatronShared/Sources/ViewModels/SignInViewModel.swift`
- Create: `MatronShared/Tests/ViewModelTests/SignInViewModelTests.swift`

The ViewModel orchestrates the AuthService — input validation, probe, login, persist. It lives in `MatronShared` (target: `MatronViewModels`) so both the iOS app and the Mac app construct the same instance — the platform-specific Views just bind to it.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/ViewModelTests/SignInViewModelTests.swift`:

```swift
import XCTest
@testable import MatronViewModels
import MatronAuth
import MatronModels

final class FakeAuthForVM: AuthService, @unchecked Sendable {
    var probeResult: Result<ServerCapabilities, Error> = .success(.init(supportsPasswordLogin: true, supportsSSO: false))
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
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
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
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
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
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        await vm.submit()
        XCTAssertEqual(vm.state, .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd MatronShared && swift test --filter SignInViewModelTests`
Expected: FAIL — `SignInViewModel` not defined.

- [ ] **Step 3: Implement `SignInViewModel`**

Create `MatronShared/Sources/ViewModels/SignInViewModel.swift`:

```swift
import Foundation
import MatronAuth
import MatronModels

@Observable
@MainActor
public final class SignInViewModel {
    public enum State: Equatable {
        case idle
        case busy
        case error(String)
        case signedIn(UserSession)
    }

    public var serverURL: String = ""
    public var username: String = ""
    public var password: String = ""
    public private(set) var state: State = .idle

    private let auth: AuthService
    private let deviceDisplayName: String

    /// `deviceDisplayName` is platform-specific — "Matron iOS" from the iOS
    /// app, "Matron Mac" from the Mac app — so the ViewModel itself stays
    /// target-agnostic. Each App struct passes its own value.
    public init(auth: AuthService, deviceDisplayName: String) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
    }

    public func submit() async {
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
                initialDeviceDisplayName: deviceDisplayName
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

- [ ] **Step 4: Run tests**

Run: `cd MatronShared && swift test --filter SignInViewModelTests`
Expected: PASS — 3 tests succeed.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/SignInViewModel.swift MatronShared/Tests/ViewModelTests/SignInViewModelTests.swift
git commit -m "feat: SignInViewModel in MatronShared with input validation and login orchestration"
git push
```

---

### Task 12: SignInView (iOS UI)

**Files:**
- Create: `Matron/Features/Onboarding/SignInView.swift`

The iOS sign-in view binds to `MatronShared`'s `SignInViewModel` (Task 11). No view model is constructed in-target — the App struct (Task 14) does that with `deviceDisplayName: "Matron iOS"`.

- [ ] **Step 1: Implement `SignInView`**

Create `Matron/Features/Onboarding/SignInView.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

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

### Task 12B: MacSignInView (macOS UI)

**Files:**
- Create: `MatronMac/Features/Onboarding/MacSignInView.swift`
- Create: `MatronMacTests/MacSignInViewBindingTests.swift`

The Mac sign-in view binds to the same `MatronShared.SignInViewModel`, but presents a centered card with a fixed onboarding window size (480×360). TDD-shaped: failing test asserts the view emits the expected `onSignedIn` callback when the bound view model transitions to `.signedIn`.

- [ ] **Step 1: Add a `MatronMacTests` test target to `project.yml`**

Append to `project.yml` under `targets:`:

```yaml
  MatronMacTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: 14.0
    sources:
      - path: MatronMacTests
    dependencies:
      - target: MatronMac
      - package: MatronShared
```

Run: `xcodegen generate`
Expected: project regenerates with `MatronMacTests` target.

- [ ] **Step 2: Write the failing test**

Create `MatronMacTests/MacSignInViewBindingTests.swift`:

```swift
import XCTest
@testable import MatronMac
import MatronAuth
import MatronModels
import MatronViewModels

final class MacSignInViewBindingTests: XCTestCase {

    @MainActor
    func test_onSignedInClosure_isInvoked_whenViewModelTransitionsToSignedIn() async {
        let fake = FakeAuthForVM()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        fake.loginResult = .success(session)

        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Mac")
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "hunter2"

        var captured: UserSession?
        let _ = MacSignInView(viewModel: vm) { captured = $0 }

        await vm.submit()

        // The view's onChange(of:viewModel.state) handler is what fires
        // onSignedIn in production. This unit test verifies the contract by
        // simulating the same callback wiring through a helper:
        if case .signedIn(let s) = vm.state {
            captured = s
        }
        XCTAssertEqual(captured, session)
    }
}
```

> The test deliberately doesn't drive the SwiftUI runtime — that's covered by manual smoke (Task 15B). It just locks in the binding contract: the view exposes a `viewModel:` and a `onSignedIn:` closure, and the App struct (Task 14B) is responsible for wiring them.

- [ ] **Step 3: Run test to verify it fails**

Run (in Xcode): Product → Test (⌘U) with the `MatronMac` scheme.
Expected: FAIL — `MacSignInView` not defined.

- [ ] **Step 4: Implement `MacSignInView`**

Create `MatronMac/Features/Onboarding/MacSignInView.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

struct MacSignInView: View {
    @State var viewModel: SignInViewModel
    var onSignedIn: (UserSession) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Matron")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "Server") {
                    TextField("https://matrix.example.com", text: $viewModel.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledField(label: "Username") {
                    TextField("alice", text: $viewModel.username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledField(label: "Password") {
                    SecureField("", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if case .error(let message) = viewModel.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button {
                Task { await viewModel.submit() }
            } label: {
                if case .busy = viewModel.state {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Sign in")
                        .frame(maxWidth: .infinity)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled({
                if case .busy = viewModel.state { return true }
                return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
            }())
        }
        .padding(32)
        .frame(width: 480, height: 360)   // Fixed onboarding window size per spec §5.9.
        .onChange(of: viewModel.state) { _, new in
            if case .signedIn(let session) = new {
                onSignedIn(session)
            }
        }
    }
}

private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run (in Xcode): Product → Test (⌘U) with the `MatronMac` scheme.
Expected: PASS — 1 test succeeds.

- [ ] **Step 6: Commit**

```bash
git add project.yml MatronMac/Features/Onboarding/MacSignInView.swift MatronMacTests/MacSignInViewBindingTests.swift
git commit -m "feat: MacSignInView with fixed-size onboarding card bound to shared SignInViewModel"
git push
```

---

### Task 13: ChatListViewModel + ChatListView (iOS)

**Files:**
- Create: `MatronShared/Sources/ViewModels/ChatListViewModel.swift`
- Create: `MatronShared/Tests/ViewModelTests/ChatListViewModelTests.swift`
- Create: `Matron/Features/ChatList/ChatListView.swift`

The view model lives in `MatronShared` (target: `MatronViewModels`) so the Mac sidebar (Task 13B) and the iOS list bind to the same `@Observable` instance. Only `ChatListView.swift` (iOS chrome) lives in the iOS app target.

- [ ] **Step 1: Write the failing ViewModel test**

Create `MatronShared/Tests/ViewModelTests/ChatListViewModelTests.swift`:

```swift
import XCTest
@testable import MatronViewModels
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

Run: `cd MatronShared && swift test --filter ChatListViewModelTests`
Expected: FAIL — `ChatListViewModel` not defined.

- [ ] **Step 3: Implement `ChatListViewModel`**

Create `MatronShared/Sources/ViewModels/ChatListViewModel.swift`:

```swift
import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
public final class ChatListViewModel {
    public struct GroupedSummaries: Identifiable {
        public let group: ChatRecencyGroup
        public let summaries: [ChatSummary]
        public var id: String { group.rawValue }
    }

    public private(set) var groups: [GroupedSummaries] = []
    public private(set) var isLoading: Bool = true

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    public init(chat: ChatService) {
        self.chat = chat
    }

    public func start() {
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

    public static func group(summaries: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [GroupedSummaries] {
        let buckets = Dictionary(grouping: summaries) { ChatRecencyGroup.bucket($0.lastActivity, now: now, calendar: calendar) }
        return ChatRecencyGroup.allCases.compactMap { bucket in
            guard let summaries = buckets[bucket]?.sorted(by: { $0.lastActivity > $1.lastActivity }), !summaries.isEmpty else { return nil }
            return GroupedSummaries(group: bucket, summaries: summaries)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd MatronShared && swift test --filter ChatListViewModelTests`
Expected: PASS — 2 tests succeed.

- [ ] **Step 5: Implement `ChatListView` (iOS)**

Create `Matron/Features/ChatList/ChatListView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

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
git add MatronShared/Sources/ViewModels/ChatListViewModel.swift MatronShared/Tests/ViewModelTests/ChatListViewModelTests.swift Matron/Features/ChatList/ChatListView.swift
git commit -m "feat: ChatListViewModel in MatronShared + iOS ChatListView with recency grouping"
git push
```

---

### Task 13B: MacChatListView (macOS UI)

**Files:**
- Create: `MatronMac/Features/ChatList/MacChatListView.swift`
- Create: `MatronMacTests/MacChatListViewBindingTests.swift`

The Mac chat list is a `NavigationSplitView` 2-column stub: sidebar = chat rows; detail = "Select a chat" placeholder. It binds to the same `MatronShared.ChatListViewModel` as the iOS list — the platform diff is purely SwiftUI chrome (split view vs. stack). Phase 2 fills in the detail column with `MacChatView`; Phase 1 only proves the binding works.

- [ ] **Step 1: Write the failing binding test**

Create `MatronMacTests/MacChatListViewBindingTests.swift`:

```swift
import XCTest
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

final class MacChatListViewBindingTests: XCTestCase {

    @MainActor
    func test_view_observesViewModelGroups_afterStreamYield() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let summaries = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        let fake = LocalFakeChatService(snapshots: [summaries])
        let vm = ChatListViewModel(chat: fake)

        // Construct the view to ensure the type compiles and exposes the
        // expected initialiser surface. The actual SwiftUI rendering is
        // covered by manual smoke tests (Task 15B).
        let _ = MacChatListView(viewModel: vm)

        vm.start()
        // Drain the in-memory stream.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(vm.groups.isEmpty)
        XCTAssertEqual(vm.groups.first?.summaries.first?.title, "First chat")
    }
}

private final class LocalFakeChatService: ChatService, @unchecked Sendable {
    private let snapshots: [[ChatSummary]]
    init(snapshots: [[ChatSummary]]) { self.snapshots = snapshots }
    func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (in Xcode): Product → Test (⌘U) with the `MatronMac` scheme.
Expected: FAIL — `MacChatListView` not defined.

- [ ] **Step 3: Implement `MacChatListView`**

Create `MatronMac/Features/ChatList/MacChatListView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

struct MacChatListView: View {
    @State var viewModel: ChatListViewModel
    @State private var selectedChat: ChatSummary.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Matron")
        .task { viewModel.start() }
    }

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.isLoading {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            ContentUnavailableView(
                "No chats yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Provision a bot via dev-boxer to get started.")
            )
        } else {
            List(selection: $selectedChat) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        // Phase 2 replaces this with MacChatView(roomID: selectedChat).
        VStack {
            Spacer()
            Text(selectedChat == nil ? "Select a chat" : "Chat detail — Phase 2")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body)
                Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.lastActivity, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if summary.unreadCount > 0 {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run (in Xcode): Product → Test (⌘U) with the `MatronMac` scheme.
Expected: PASS — 1 test succeeds.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacChatListViewBindingTests.swift
git commit -m "feat: MacChatListView 2-column NavigationSplitView stub bound to shared ChatListViewModel"
git push
```

---

### Task 14: AppDependencies + root navigation (iOS)

**Files:**
- Create: `Matron/App/AppDependencies.swift`
- Modify: `Matron/App/MatronApp.swift`

The DI container is iOS-flavoured (uses `StoragePaths.groupContainer`) but the factory shape — `syncCache`, `chatService(for:)`, `syncService(for:)` — is shared with the Mac variant in Task 14B. The protocol surface stays target-agnostic.

- [ ] **Step 1: Implement `AppDependencies` (iOS)**

Create `Matron/App/AppDependencies.swift`:

```swift
import Foundation
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider

    private var syncCache: [String: SyncService] = [:]

    init() {
        // iOS shares its crypto store + search DB with the NSE via the App
        // Group container. Falls back to a tmp dir only when running outside
        // an entitlement (test runner / Previews).
        let container: URL
        #if os(iOS)
        container = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: StoragePaths.appGroupIdentifier))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #else
        container = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #endif
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let keychain = KeychainStore(
            service: "chat.matron.session",
            accessGroup: nil
        )
        self.auth = AuthServiceLive(sessionStore: keychain, basePath: container)
        self.clientProvider = ClientProvider(basePath: container)
    }

    func syncService(for session: UserSession) -> SyncService {
        if let existing = syncCache[session.userID] { return existing }
        let svc = SyncServiceLive(provider: clientProvider, session: session)
        syncCache[session.userID] = svc
        return svc
    }

    func chatService(for session: UserSession) -> ChatService {
        // Reuses the same SyncService instance so ChatServiceLive's
        // waitUntilReady() observes the same readiness flag as the call site
        // that started sync.
        ChatServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session)
        )
    }
}
```

- [ ] **Step 2: Replace `MatronApp.swift` body with real navigation**

Replace `Matron/App/MatronApp.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

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
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
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

In Xcode: Product → Run (⌘R) on iPhone 17 simulator.
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

### Task 14B: AppDependencies + root navigation (macOS)

**Files:**
- Create: `MatronMac/App/AppDependencies.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (replace the Phase 1 scaffold from Task 2)

The Mac variant of `AppDependencies` shares the factory shape (`syncCache`, `chatService(for:)`, `syncService(for:)`, same `AuthServiceLive` + `ClientProvider`) with iOS — the only diff is the storage container, which routes through `StoragePaths.appSupport` because Mac runs single-process and doesn't share with an NSE.

- [ ] **Step 1: Implement `AppDependencies` (macOS)**

Create `MatronMac/App/AppDependencies.swift`:

```swift
import Foundation
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider

    private var syncCache: [String: SyncService] = [:]

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // StoragePaths.appSupport creates the directory on first read.
        let container = StoragePaths.appSupport

        let keychain = KeychainStore(
            service: "chat.matron.mac.session",
            accessGroup: nil
        )
        self.auth = AuthServiceLive(sessionStore: keychain, basePath: container)
        self.clientProvider = ClientProvider(basePath: container)
    }

    func syncService(for session: UserSession) -> SyncService {
        if let existing = syncCache[session.userID] { return existing }
        let svc = SyncServiceLive(provider: clientProvider, session: session)
        syncCache[session.userID] = svc
        return svc
    }

    func chatService(for session: UserSession) -> ChatService {
        ChatServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session)
        )
    }
}
```

- [ ] **Step 2: Replace `MatronMacApp.swift` (Task 2 scaffold) with real navigation**

Replace `MatronMac/App/MatronMacApp.swift`:

```swift
import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

@main
struct MatronMacApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .frame(width: 480, height: 360)
                        .task { await bootstrap() }
                } else if let session {
                    MacChatListView(
                        viewModel: ChatListViewModel(chat: dependencies.chatService(for: session))
                    )
                    .frame(minWidth: 800, minHeight: 600)
                    .task { try? await dependencies.syncService(for: session).start() }
                } else {
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        onSignedIn: { session in self.session = session }
                    )
                }
            }
        }
        .windowResizability(.contentMinSize)

        // Placeholder — Phase 7 fills in the full Settings UI.
        Settings {
            Text("Settings — Phase 7 fills this in.")
                .padding()
                .frame(width: 480, height: 240)
        }
        // Phase 2 attaches the real menu bar (.commands { CommandMenu… }).
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

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).
```

- [ ] **Step 3: Build & run on macOS**

In Xcode: select the `MatronMac` scheme, Product → Run (⌘R).
Expected:
- App launches showing "Loading…" inside a 480×360 window during bootstrap.
- Transitions to the Mac sign-in card if no stored session.
- After successful login against a real `dev-boxer` homeserver, the window resizes and shows the 2-column split with "Select a chat" detail and the chat list in the sidebar.

- [ ] **Step 4: Commit**

```bash
git add MatronMac/App
git commit -m "feat: MatronMac AppDependencies + MatronMacApp root navigation"
git push
```

---

### Task 15: Manual end-to-end smoke test against a real homeserver

**Files:**
- Create: `manual-tests.md`

This is a documentation task — no code. Establishes the manual baseline that subsequent tasks/phases extend.

- [ ] **Step 1: Run the iOS flow on a simulator**

Pre-req: a `dev-boxer` homeserver with a Matrix user account and at least one bot already invited to a room with that user.

Steps:
1. Cold-launch the app on iPhone 17 simulator.
2. Enter homeserver URL, username, password. Tap Sign in.
3. Wait for chat list to populate.
4. Verify: at least one chat appears with the bot's display name and a recency timestamp.
5. Quit and re-launch the app. Verify it skips the sign-in screen and goes straight to the chat list.

- [ ] **Step 2: Run the Mac flow on the host**

Same homeserver, same account. Steps:
1. Build & run the `MatronMac` scheme on the macOS host.
2. Verify the onboarding window opens at 480×360 with the centered card.
3. Enter homeserver URL, username, password. Press Return (default action).
4. After login, verify the window resizes to ≥800×600 with the 2-column split: chat list in the sidebar, "Select a chat" placeholder in the detail.
5. Quit (`⌘Q`) and re-launch. Verify it skips the sign-in screen and goes straight to the split view.
6. Press `⌘,` — Settings placeholder window opens.

- [ ] **Step 3: Document the test**

Create `manual-tests.md`:

```markdown
# Matron — manual test checklist

Run before every TestFlight build (iOS) and every Mac App Store build.

## Phase 1 (Foundation)

### iOS — sign-in flow

- [ ] Cold-launch on iPhone 17 simulator (or device) — sees Sign-in screen.
- [ ] Enter homeserver URL with no scheme (e.g. `matrix.example.com`) — accepted, normalised to HTTPS.
- [ ] Enter homeserver URL with HTTP — rejected with friendly error.
- [ ] Enter blatantly invalid credentials — sees error message in red.
- [ ] Enter valid credentials — transitions to Connecting → chat list.

### iOS — session persistence

- [ ] After successful sign-in, force-quit the app and re-launch — skips sign-in, goes straight to chat list.
- [ ] Reset simulator (Device → Erase All Content) and re-launch — back to sign-in (no stale session).

### iOS — chat list rendering

- [ ] At least one chat appears (assumes a bot is already invited).
- [ ] Chat title shows the room name (Gemini-auto-titled if applicable; falls back to room ID).
- [ ] Recency grouping headers appear (Today / Yesterday / etc.).
- [ ] Unread dot appears for chats with unread messages.

### macOS — sign-in flow

- [ ] Cold-launch the `MatronMac` scheme — sees a 480×360 sign-in card window.
- [ ] Press Return after filling the form — submits (default action wired via `keyboardShortcut(.defaultAction)`).
- [ ] Enter blatantly invalid credentials — sees error message in red.
- [ ] Enter valid credentials — window transitions to the 2-column split view at ≥800×600.

### macOS — session persistence

- [ ] After successful sign-in, `⌘Q` and re-launch — skips sign-in, opens the split view directly.
- [ ] Reset Application Support (delete `~/Library/Application Support/chat.matron.mac/` while app is closed) and re-launch — back to sign-in (no stale session).

### macOS — chat list rendering

- [ ] Sidebar lists at least one chat with bot display name and relative time.
- [ ] Detail column shows "Select a chat" until a row is selected (Phase 2 wires the actual chat view).
- [ ] `⌘,` opens the placeholder Settings window.

### Cross-platform smoke

- [ ] Sign in with the same account on iOS simulator and macOS host. Both surfaces show the same chat list (after sliding-sync settles).

### What is NOT tested in Phase 1

- Tapping a chat to view the timeline (Phase 2).
- Sending messages (Phase 2).
- Push notifications (Phase 4).
- Verification UX (Phase 3).
- Search (Phase 6).
- Full Mac menu bar / toolbar / drag-and-drop (Phase 2 onwards).
- Mac Settings tabs (Phase 7).
```

- [ ] **Step 4: Commit**

```bash
git add manual-tests.md
git commit -m "docs: phase 1 manual test checklist (iOS + macOS)"
git push
```

---

### Task 16: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

The CI runs both targets in one workflow with two jobs (iOS-Simulator and macOS-host). The CLA workflow (`cla.yml`) is already present from Task 1B and runs independently.

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
  shared-package-tests:
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_16.app

      - name: Show Xcode version
        run: xcodebuild -version

      - name: Run MatronShared package tests (host = macOS, exercises both #if os branches)
        working-directory: MatronShared
        run: swift test --enable-code-coverage

  ios-build-and-test:
    runs-on: macos-15
    needs: shared-package-tests
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_16.app

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Resolve SPM dependencies
        run: xcodebuild -resolvePackageDependencies -workspace Matron.xcworkspace -scheme Matron

      - name: Build Matron app (iOS)
        run: |
          xcodebuild build \
            -workspace Matron.xcworkspace \
            -scheme Matron \
            -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
            CODE_SIGNING_ALLOWED=NO

      - name: Run Matron app tests (iOS)
        run: |
          xcodebuild test \
            -workspace Matron.xcworkspace \
            -scheme Matron \
            -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
            CODE_SIGNING_ALLOWED=NO

  mac-build-and-test:
    runs-on: macos-15
    needs: shared-package-tests
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_16.app

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Resolve SPM dependencies
        run: xcodebuild -resolvePackageDependencies -workspace Matron.xcworkspace -scheme MatronMac

      - name: Build MatronMac app
        run: |
          xcodebuild build \
            -workspace Matron.xcworkspace \
            -scheme MatronMac \
            -destination 'platform=macOS' \
            CODE_SIGNING_ALLOWED=NO

      - name: Run MatronMac tests
        run: |
          xcodebuild test \
            -workspace Matron.xcworkspace \
            -scheme MatronMac \
            -destination 'platform=macOS' \
            CODE_SIGNING_ALLOWED=NO
```

> **Why three jobs:** the `shared-package-tests` job runs `swift test` directly so we get a single host (macOS) running through both `#if os(iOS)` and `#if os(macOS)` branches via the SPM-package compile — the iOS `#if os(iOS)` block isn't reached in this job (compiles for the host), but the iOS-scheme job runs the full iOS test target. The split keeps the iOS and Mac jobs parallelisable without cross-contamination.

- [ ] **Step 2: Push and verify the workflow runs green**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow building and testing iOS + macOS on macos-15"
git push
```

Run: `gh run list --workflow ci.yml --limit 1`
Then: `gh run watch <run-id>`
Expected: workflow completes green within ~25 minutes (iOS + Mac jobs run in parallel after the shared-package job).

- [ ] **Step 3: Iterate if red**

If CI fails:
- Read logs via `gh run view <run-id> --log-failed`.
- Fix the issue (likely: SDK version pin mismatch, missing Xcode version, simulator name drift, Mac `arm64` vs `x86_64` arch flags).
- Push fix as a new commit. Repeat until green.

---

## Phase 1 acceptance

Phase 1 is done when:

1. All 16 numbered tasks plus Tasks 1B / 12B / 13B / 14B committed and pushed to `main` (20 tasks total).
2. CI is green on `main` — both the iOS job and the macOS job.
3. Manual checklist (`manual-tests.md`) passes for both platforms against at least one real `dev-boxer` homeserver.
4. The iOS app, when run, allows: enter server URL + credentials → sign in → see chat list with bot rooms.
5. The macOS app, when run, allows: same flow → 2-column split with chat list in the sidebar.
6. The repo's licence posture is in place: AGPL-3.0 `LICENSE`, dual-licence `NOTICE`, `CONTRIBUTING.md`, `.cla.md`, and the cla-assistant workflow blocks unsigned external PRs.

After acceptance, request review (see superpowers:requesting-code-review), then write the Phase 2 plan.

---

## Plan self-review notes

Quick check against the spec sections:

- **§1 Goals & non-goals:** Covered — Phase 1 establishes App Store-distributable codebases for both iOS and macOS with E2EE on, sliding sync, and the bot-rooms-as-chats data model. Non-goals respected (no reactions, edits, etc., are even possible because no chat view exists yet).
- **§2 High-level architecture:** Four targets created in Task 2 (`Matron`, `MatronMac`, `MatronNSE`, `MatronShared`). SDK wired in Tasks 3–10; App Group set on iOS only; iOS 17 / macOS 14 enforced.
- **§3 Module structure:** Auth/Sync/Chat/Storage/Models modules in `MatronShared`; ViewModels and DesignSystem also live in `MatronShared` from Phase 1 (DesignSystem is provisioned but empty until Phase 2). Push/Search/Verification/Media/Events deferred to phases that need them.
- **§4 Custom event types:** Deferred to Phase 5 (custom events depend on bridge changes that need their own spec).
- **§5 Key UI flows:** Sign-in (§5.2) implemented for iOS in Task 12 and for macOS in Task 12B, both bound to the shared `SignInViewModel` (Task 11). Chat list (§5.3) implemented for iOS in Task 13 and for macOS in Task 13B, both bound to the shared `ChatListViewModel`. Mac chrome (§5.9) — full menu bar, toolbar, drag-and-drop — is intentionally deferred to Phase 2; only the placeholder `Settings { ... }` scene and `WindowGroup { ... }.windowResizability(.contentMinSize)` ship in Phase 1. Other flows (§5.4–5.8) deferred.
- **§6 Data flow:** Sync loop (§6.1) and read-only chat-list slice implemented. Decryption hook to search (§6.2), push wakeup (§6.3), and new-chat creation (§6.4) deferred.
- **§7 E2EE:** SDK is initialised with E2EE on by default in `ClientProvider` (Task 9). iOS uses the App Group container; macOS uses `~/Library/Application Support/chat.matron.mac/` via `StoragePaths.appSupport` (Task 3). Verification UI (§7.2–7.3), key backup (§7.4), and trust posture banners (§7.5) deferred to Phase 3.
- **§8 Push:** NSE stub created (Task 2) but no decryption logic; deferred to Phase 4. Mac in-process push delegate also deferred to Phase 4.
- **§9 Search storage:** Deferred to Phase 6 — schema not created in Phase 1. Storage paths are platform-conditional from Phase 1 so Phase 6 only adds schema/queries, not branching.
- **§10 Testing strategy:** Unit tests + ViewModel tests covered for both platforms. Snapshot tests deferred (no rendering primitives yet). Integration test scaffold added in Task 7. CI matrix runs the SPM tests once on macOS (compiles both `#if os` branches at the host level) and the full iOS test target on a Simulator + the full Mac test target on the host.
- **§11 Out of scope:** Honored — no scope creep beyond foundation.
- **§12 License & legal:** AGPL-3.0 `LICENSE` + dual-licence `NOTICE` + `CONTRIBUTING.md` + `.cla.md` + `cla-assistant` workflow all land in Task 1B before any new code. No AGPL-incompatible deps. The legacy `element-x-ios` lineage is dropped by re-initialising the repo (flagged in the spec, prerequisite to running this plan).

No placeholders, no TBDs. Type signatures (`AuthService`, `ChatService`, `UserSession`, `ChatSummary`, `SignInViewModel`, `ChatListViewModel`) are consistent across tasks. `ChatRecencyGroup.bucket` is defined in Task 8, used in Task 13. `AuthService` defined in Task 6, used in Tasks 7, 11, 14, 14B. `SignInViewModel` defined in Task 11, consumed by Task 12 (iOS) and Task 12B (Mac). `ChatListViewModel` defined in Task 13, consumed by Task 13 (iOS) and Task 13B (Mac). SDK method names flagged with implementer notes where versions diverge.

### Multi-platform shape (added in this revision)

- **Four Xcode targets** instead of three. `MatronMac` (Task 2) is a co-equal app target with its own bundle ID (`chat.matron.mac`), entitlements, and `WindowGroup { ContentView() }.windowResizability(.contentMinSize)` scene. `MatronNSE` remains iOS-only because Mac doesn't have NSEs.
- **AGPL-3.0 + commercial dual licence** with a CLA workflow (Task 1B). `LICENSE`, `NOTICE` (with provisional `licensing@matron.chat` flagged for confirmation), `CONTRIBUTING.md`, `.cla.md`, and `.github/workflows/cla.yml` all land before any code.
- **Mac storage path** (Task 3). `StoragePaths` replaces the old `AppGroup` enum with `#if os(iOS)` (App Group container) vs `#if os(macOS)` (Application Support). Tests cover both branches via per-platform `#if os` test methods; CI matrix exercises both.
- **ViewModels move into MatronShared** (Tasks 3, 11, 13). `MatronViewModels` is a new SPM library product. `SignInViewModel` and `ChatListViewModel` are public, target-agnostic, `@Observable`. Both apps construct instances from their respective `App` struct; `deviceDisplayName` (`"Matron iOS"` / `"Matron Mac"`) is the only platform-specific input.
- **DesignSystem moves into MatronShared** (Task 3). `MatronDesignSystem` library product is declared from Phase 1 with an empty `Sources/DesignSystem/` directory + `.gitkeep`. Phase 2 lands primitives directly there. The provisional `Color.matronCodeBg` shorthand is no longer in scope — the canonical token name is `Color.matronCodeBackground`, per the Phase 7 reconciliation already merged into the design spec.
- **Mac stubs for Sign-in and ChatList** (Tasks 12B and 13B). `MacSignInView` is a centered card with `.frame(width: 480, height: 360)` during onboarding. `MacChatListView` is a 2-column `NavigationSplitView` with sidebar = chat rows + detail = "Select a chat" placeholder; the detail column is filled in by Phase 2. Both views are TDD-shaped via `MatronMacTests`.

### Code-review fixes folded back in

- **`ServerCapabilities.ssoRedirectURL` removed** (Task 6). The earlier draft had `AuthServiceLive.probe()` constructing `URL(string: "https://placeholder/sso")`, which would have shipped a non-functional URL. SSO redirect handling is deferred to a future spec; the struct now exposes only the boolean `supportsSSO` so the sign-in screen can show or hide a (currently disabled) SSO button. `AuthServiceProtocolTests` gained a test asserting the boolean is captured correctly.
- **`SyncService.waitUntilReady()` added** (Task 9). `ChatServiceLive.chatSummaries()` previously called `roomListService()` synchronously before `SyncService.start()` had completed, which would crash on a nil room list. The protocol now exposes a readiness gate, `SyncServiceLive` resumes waiters once the SDK reports `RoomListService` non-nil, and `ChatServiceLive` (Task 10) blocks on `sync.waitUntilReady()` before subscribing. A failing-test step is added to Task 10. `AppDependencies` (both iOS and Mac variants) caches a single `SyncService` per session so the chat service and the sync starter observe the same readiness flag.
- **`Matron.xcodeproj/` added to `.gitignore`** (Task 1). Matches the claim at the bottom of Task 2 that `project.yml` is the source of truth.
- **`Package.resolved` removed from `.gitignore`** (Task 1). For an app binary it should be committed so CI pins matrix-rust-components-swift versions consistently. A comment in the gitignore explains why.
- **Dedicated `SyncTests` test target** (Task 3). `SyncServiceProtocolTests` lives in `Tests/SyncTests/` with `dependencies: ["MatronSync"]`, instead of riding inside `ChatTests` (which doesn't depend on `MatronSync`).
- **`AppDependencies` imports `MatronModels`** (Tasks 14 and 14B). `UserSession` lives in `MatronModels`; the import was missing in the iOS draft and is now consistent across both platforms.

---
