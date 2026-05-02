# Matron — multi-platform design spec (iOS + macOS)

**Date:** 2026-05-02
**Status:** Revised — multi-platform from day 1 (iOS + native macOS as co-equal targets), AGPL-3.0 + commercial dual-licensing.
**Repo (target):** `matronhq/matron-ios` (to be re-initialised before any new code lands; the repo currently contains an Element X fork whose history and copyright lineage will be dropped — the project itself will be AGPL-3.0 with commercial licensing available by arrangement, see §12).

---

## 1 — Goals & non-goals

### Goals

- **Native iOS and native macOS** apps for Matrix — both App Store distributable, both treated as first-class. iPad runs the iOS app via adaptive layout (`NavigationSplitView` collapses on iPhone, expands on iPad).
- Bot-first chat UX: ChatGPT/Claude.ai-inspired layout — sidebar of chats, single-pane chat view, minimalist. Single main window on Mac (focus on one chat at a time; no multi-window sprawl).
- Optimised for talking to AI bots over E2EE Matrix in a closed personal ecosystem (the user's own homeserver, only their own bots).
- One Matrix room per chat conversation; multiple chats per bot. Bot auto-titles each chat via server-side Gemini Flash.
- Excellent rendering of long markdown + code blocks, plus distinctive UX for tool-call cards and "ask the user" prompts.
- E2EE on by default with first-class device verification (SAS) and recovery key flows.
- Push notifications via APNs on both platforms — iOS uses a Notification Service Extension to decrypt silent pushes; macOS handles them in-process via `UNUserNotificationCenterDelegate` (Mac apps run their full process for delivered notifications, no extension needed).
- Local full-text search across all chats (per-device; same SQLite FTS5 store on both platforms).

### Non-goals (MVP)

- Threads, spaces, voice, video, calls.
- Reactions, replies, edits, redactions of others' messages.
- Block, ignore, report.
- Polls, location, stickers, custom emoji packs, voice broadcasts.
- Public room directory / discovery, user search, multi-account, identity-server / 3PID linking.
- Power-levels admin UI, integration manager, widgets.
- Federation discovery (any user-supplied homeserver works, but no `.well-known` browsing UI).
- In-app bot installation (server-side via `dev-boxer add-bot` only; in-app provisioning is deferred to a later spec).

### Explicitly later-phase (not in this spec)

- In-app "create new bot" flow (calling a future server API).
- Multi-bot rooms.
- iPadOS-specific layouts (the iOS app already adapts via `NavigationSplitView` to give iPad a sidebar in landscape; bespoke iPad-specific UI — e.g. drag-and-drop between chats, multi-column custom layouts — is deferred).

---

## 2 — High-level architecture

```
┌─────────────────────────┐  ┌─────────────────────────┐
│   Matron (iOS app)      │  │   MatronMac (macOS app) │
│   iPhone + iPad         │  │   single main window    │
│  ┌───────────────────┐  │  │  ┌───────────────────┐  │
│  │ SwiftUI views     │  │  │  │ SwiftUI views     │  │
│  │ NavigationStack / │  │  │  │ NavigationSplit-  │  │
│  │ adaptive Split    │  │  │  │ View 2-col + menu │  │
│  └─────────┬─────────┘  │  │  └─────────┬─────────┘  │
└────────────┼────────────┘  └────────────┼────────────┘
             │                            │
             ▼                            ▼
┌──────────────────────────────────────────────────────────┐
│                    MatronShared (SPM)                    │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ ViewModels  (per feature, @Observable, target-      │ │
│  │              agnostic — used by both apps)          │ │
│  ├─────────────────────────────────────────────────────┤ │
│  │ DesignSystem — rendering primitives                 │ │
│  │ MarkdownText · CodeBlock · ToolCallCard ·           │ │
│  │ AskUserSheetBody · SessionMetaHeader · Attachment*  │ │
│  ├─────────────────────────────────────────────────────┤ │
│  │ Service layer                                       │ │
│  │ AuthService · SyncService · ChatService ·           │ │
│  │ PushService · VerificationService · MediaService ·  │ │
│  │ SearchService                                       │ │
│  ├─────────────────────────────────────────────────────┤ │
│  │ matrix-rust-sdk-swift (Apache 2.0, via SPM)         │ │
│  │ Client · RoomListService · Timeline · Encryption    │ │
│  └──────────────────────┬──────────────────────────────┘ │
└─────────────────────────┼────────────────────────────────┘
                          │ sliding sync over HTTPS
                          ▼
                  matron-server (Tuwunel)
                          │
                          ▼
                  bot accounts (Claude bridge, etc.)

┌──────────────────────────┐   ┌──────────────────────────────┐
│ MatronNSE (iOS-only)     │   │ MatronMac in-process push    │
│ NotificationService-     │   │ UNUserNotificationCenter-    │
│ Extension. Receives      │   │ Delegate. Same PushDecoder   │
│ silent APNs → calls      │   │ from MatronShared, called    │
│ shared PushDecoder →     │   │ in-process — no extension,   │
│ rewrites notification.   │   │ no App Group complications.  │
└──────────────────────────┘   └──────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│         Sygnal-compatible HTTP pusher (server-side)      │
│  Lives alongside matron-server. Two app entries —        │
│  chat.matron.ios + chat.matron.mac (with .dev variants   │
│  for sandbox builds). Forwards Matrix push events as     │
│  silent APNs pushes to the appropriate app.              │
└──────────────────────────────────────────────────────────┘
```

### Four Xcode targets

1. **`Matron`** — iOS app (SwiftUI, MVVM, iOS 17+). Runs on iPhone and iPad; iPad inherits via adaptive `NavigationSplitView`.
2. **`MatronMac`** — native macOS app (SwiftUI, macOS 14+, single main window, Mac chrome — menu bar, Settings scene, toolbar, hover states, keyboard shortcuts).
3. **`MatronNSE`** — Notification Service Extension, **iOS-only**. macOS does not have NSEs; Mac handles pushes in-process.
4. **`MatronShared`** — local Swift Package, depended on by all three apps. Holds services, models, ViewModels, design-system primitives, and event-type definitions.

### Architectural choices

- **Pattern: MVVM, no Coordinators.** SwiftUI views bind to `@Observable` ViewModels (target-agnostic, in `MatronShared`). Navigation goes through native `NavigationStack` (iOS) and `NavigationSplitView` (Mac, and iPad-adaptive on iOS). Coordinators (Element X-style FlowCoordinator) are deliberately omitted — they duplicate the declarative model. If complex multi-screen flows arise later, introduce Coordinators per-flow rather than as a global pattern.
- **Per-platform views, shared everything else.** `Matron/Features/` and `MatronMac/Features/` each contain their own `*View.swift` files tailored to platform conventions. The corresponding `*ViewModel.swift` lives in `MatronShared/Sources/ViewModels/` and is imported by both. Design-system primitives (`MarkdownText`, `CodeBlock`, `ToolCallCard`, etc.) are shared in `MatronShared/Sources/DesignSystem/` and render identically on both platforms.
- **Sync: matrix-rust-sdk sliding sync** — required for responsive room list. Tuwunel (matron-server) supports it.
- **Crypto store sharing (iOS).** iOS app and NSE both open the same SDK crypto store inside an App Group container (`group.chat.matron`). matrix-rust-sdk supports concurrent-process access via internal locking.
- **Crypto store (Mac).** Single-process — no App Group needed. Store lives in `~/Library/Application Support/chat.matron.mac/` (`NSApplicationSupportDirectory`) and is encrypted at rest with a passphrase derived from a Keychain-stored key.
- **Minimum targets: iOS 17, macOS 14.** Both give us `@Observable`, modern `NavigationStack` / `NavigationSplitView`, mature SwiftUI scene APIs (`Settings { ... }`, `.commands { ... }`).
- **License posture: AGPL-3.0 + commercial dual-licensing.** Matron HQ retains copyright; the public licence is AGPL-3.0; commercial terms available by arrangement for redistributors who can't comply. App Store distribution by the copyright holder is unaffected (binary licensed under App Store EULA; AGPL governs source redistribution by third parties). Element X is studied for architectural inspiration only — no code translation, no derivative work. Dependencies must be AGPL-compatible (matrix-rust-sdk-swift Apache 2.0 ✓; MIT/BSD/Apache 2.0/MPL all fine; pure-GPL with no AGPL permission is excluded). See §12.

---

## 3 — Module structure

```
MatronShared/                    (local SPM package, depended on by Matron + MatronMac + MatronNSE)
├── Sources/
│   ├── Auth/                    AuthService, login, logout, server URL discovery
│   ├── Sync/                    ClientProvider, SyncService (sliding sync wrapper)
│   ├── Chat/                    ChatService, RoomListWrapper, Timeline wrapper
│   ├── Verification/            SAS verification flow, recovery key (DTOs in VerificationDTOs.swift)
│   ├── Push/                    Pusher registration, PushDecoder shared by NSE (iOS) and
│   │                            UNUserNotificationCenterDelegate (Mac)
│   ├── Media/                   Image/file fetch + cache, mxc:// resolution
│   ├── Search/                  SQLite FTS5 service (see §5.8)
│   ├── Models/                  Plain-Swift DTOs: ChatSummary, BotIdentity, Message
│   ├── Events/                  Custom event type defs (chat.matron.tool_call, …)
│   ├── Storage/                 App Group paths (iOS), Application Support paths (Mac), crypto store init
│   ├── ViewModels/              @Observable ViewModels per feature, target-agnostic.
│   │                            Used by both Matron/Features/ and MatronMac/Features/.
│   └── DesignSystem/            Colors, typography, spacing tokens; shared rendering primitives:
│                                MarkdownText, CodeBlock, ToolCallCard, AskUserSheetBody,
│                                SessionMetaHeader, AttachmentImage, AttachmentFile, MessageBubble.
└── Tests/                       Unit tests per module + snapshot tests for DesignSystem
                                 (light/dark/XXXL × iOS/Mac variants)

Matron/                          (iOS app target — iPhone + iPad)
├── App/                         MatronApp, root navigation, session restore
├── Features/                    NavigationSplitView-based views (auto-collapses to a stack on
│   │                            iPhone, expands to sidebar+detail on iPad in landscape).
│   ├── Onboarding/              Combined server URL + login screen, then verification
│   ├── ChatList/                List, chat-summary rows, new-chat button, search bar
│   ├── Chat/                    Timeline view, composer, slash command palette
│   │   └── Composer/            Input field, slash menu, attachment picker
│   ├── BotProfile/              Per-bot view: list of chats with that bot
│   ├── Verification/            SAS verification UI, recovery flows
│   └── Search/                  Search results screen (chats + messages)
└── Resources/                   Assets, Localizable, fonts

MatronMac/                       (macOS app target — native, single main window)
├── App/                         MatronMacApp, scenes (WindowGroup main + Settings),
│                                .commands menu bar, restore window state
├── Features/                    NavigationSplitView 2-column layouts (sidebar + detail);
│   │                            Mac chrome (toolbar, hover states, drag-and-drop, ⌘ shortcuts).
│   ├── Onboarding/              Centered card layout, fixed window size during sign-in
│   ├── ChatList/                Sidebar column with chat rows
│   ├── Chat/                    Detail column: timeline + composer with .onDrop
│   ├── BotProfile/              Sheet (single-window pattern; no third column)
│   ├── Verification/            SAS as a Mac sheet; recovery key with native paste detection
│   ├── Search/                  Toolbar field + ⌘F focus + results panel replaces detail
│   └── Settings/                Native Settings { } scene (Preferences window, ⌘, opens it)
└── Resources/                   Assets (Mac icon set 16/32/.../1024), Localizable

MatronNSE/                       (Notification Service Extension target — iOS-only)
├── NotificationService.swift    Entry point, calls into MatronShared.Push.PushDecoder
└── Info.plist
```

### Conventions

- `Features/` modules in each app follow a uniform shape: `*View.swift` (platform-tailored, in app target) + corresponding `*ViewModel.swift` (in `MatronShared/Sources/ViewModels/`) + optional component sub-folder. No cross-feature imports — features only talk to the service layer.
- `MatronShared/Sources/DesignSystem/` is the single source of truth for color, type ramp, spacing tokens, and shared view primitives. Both apps consume directly; primitives render identically on both platforms.
- `MatronShared` services expose protocol interfaces for testing (real impl + fake impl side-by-side per protocol).
- Snapshot tests run against both platforms when the primitive is cross-platform (most of `DesignSystem/`); Mac-only or iOS-only chrome (toolbars, menu bar, NSE) is snapshot-tested only on the relevant platform.

---

## 4 — Custom event types & contracts

The wire-protocol contract between the iOS app and bots. Lives under the `chat.matron.*` namespace.

### 4.1 — `chat.matron.tool_call` — collapsible tool-call card

Sent by the bot when it invokes a tool. Renders as a collapsed card by default.

```json
{
  "type": "chat.matron.tool_call",
  "content": {
    "msgtype": "chat.matron.tool_call",
    "body": "Read(/etc/hosts)",          // text fallback for non-Matron clients
    "tool": "Read",
    "args": { "file_path": "/etc/hosts" },
    "status": "running",                 // "running" | "ok" | "error"
    "result": null,                      // populated on completion (string or object)
    "result_truncated": false,
    "started_at": 1745000000000,
    "ended_at": null
  }
}
```

Updates use `m.replace` (re-send with the same `m.relates_to.event_id`). The app re-renders the card in place.

### 4.2 — `chat.matron.ask_user` — interactive prompt sheet

Sent by the bot when it needs an answer. App pops a half-sheet with the prompt and the appropriate input. The user's response goes back as a normal `m.room.message` with `m.in_reply_to` referencing the prompt event so the bot can correlate.

```json
{
  "type": "chat.matron.ask_user",
  "content": {
    "msgtype": "chat.matron.ask_user",
    "body": "Which file should I edit?",   // fallback for non-Matron clients
    "prompt": "Which file should I edit?",
    "input": {
      "kind": "choice",                    // "text" | "choice" | "multi_choice" | "boolean"
      "options": [
        { "id": "a", "label": "src/main.rs" },
        { "id": "b", "label": "src/lib.rs" }
      ],
      "allow_other": true                  // text input alongside choices
    },
    "expires_at": 1745000060000            // optional; sheet auto-dismisses
  }
}
```

Wires into the bridge's existing `ask-user` MCP server: that MCP emits this event in addition to (or instead of) its current text prompt.

### 4.3 — `chat.matron.session_meta` — chat metadata (state event)

State event the bridge writes when starting a chat. Lets the app show a small "Session: claude-sonnet-4-7 · workdir ~/foo" header.

```json
{
  "type": "chat.matron.session_meta",
  "state_key": "",
  "content": {
    "session_id": "abc123",
    "model": "claude-sonnet-4-7",
    "workdir": "~/my-app",
    "started_at": 1745000000000
  }
}
```

### 4.4 — Standard event types we render

- `m.room.message` with `msgtype: m.text` (markdown via `format: org.matrix.custom.html`)
- `m.room.message` with `msgtype: m.image`, `m.file`
- `m.room.name` updates (Gemini Flash auto-titles)
- `m.room.encryption`, `m.room.encrypted` (transparent — handled by SDK)
- `m.room.member` (small inline state changes only when relevant)

### 4.5 — Sending side (composer)

Composer sends only `m.room.message` (`m.text` with markdown HTML body, or `m.image` / `m.file` for attachments). Slash commands (`/start`, `/stop`, `!start`, etc.) are sent as plain text — the bridge already parses them. No client-side slash handling beyond a palette/autocomplete that prefills the input.

### 4.6 — Bridge changes implied (separate spec)

These are bridge-side changes the iOS app depends on. They will get their own bridge spec when built.

- Handle being invited to new rooms (auto-join, spawn fresh Claude session per room).
- Emit `chat.matron.tool_call` events when Claude invokes tools (gated behind a config flag for backwards compatibility).
- Update `ask-user` MCP to emit `chat.matron.ask_user` events alongside text prompts.
- Write `chat.matron.session_meta` on session start.

The iOS app degrades gracefully if these aren't present — tool calls fall back to text in the timeline; ask-user prompts show as text messages; session header is hidden if no `session_meta`.

---

## 5 — Key UI flows

ChatGPT/Claude.ai-inspired layout. iOS is phone-first; iPad gets a split view "for free" via adaptive `NavigationSplitView`. Mac is its own native target with single-window 2-column layout and full Mac chrome (menu bar, Settings scene, toolbar, keyboard shortcuts, drag-and-drop, hover states). Per-platform UX details are captured in §5.1–5.8 below; Mac-specific chrome (menu bar, window, Settings scene) is consolidated in §5.9.

### 5.1 — App launch

- Cold start → restore session if access token + crypto store present → straight to chat list.
- Token missing or expired → onboarding.
- Crypto store present but no signed device → verification prompt before chat list is interactive.

### 5.2 — Onboarding

Two screens:

1. **Sign in** — single screen with: server URL field (prefilled with last value, validated against `/_matrix/client/versions`), username field, password field, and an "SSO" button if the server advertises it. One screen, one submit.
2. **Verify this device** — if other devices exist, drive SAS verification with one of them; if not, prompt to enter recovery key. If neither possible (true first device), generate recovery key and require the user to confirm they've saved it.

### 5.3 — Chat list (the home)

Single-pane sidebar-as-content on phone:

```
┌─ Matron ────────────────────── ✏️ ─┐
│ Search…                            │
├────────────────────────────────────┤
│ Today                              │
│  ◉ Refactoring auth middleware    │
│    Claude · 2m                     │
│  ◉ Dependabot weekly digest       │
│    Linear · 1h                     │
│ Yesterday                          │
│  ◉ Org checkout regression   │
│    Claude · 18h                    │
│ Earlier                            │
│  …                                 │
└────────────────────────────────────┘
```

- Grouped by recency (Today / Yesterday / Last 7 days / Earlier).
- Each row: chat title (Gemini-auto-named), bot name, relative time. Unread dot if unread.
- ✏️ button → "New chat" sheet: pick a bot → new room created and bot invited → push to chat view.
- Pull-to-refresh forces a sync. Long-press row → mute / leave (forget room).
- Search bar enters the unified search screen (§5.8).

### 5.4 — Chat view

```
┌─ ← Refactoring auth middleware ⓘ ─┐
│ Claude · sonnet-4-7 · ~/org   │   ← session_meta header (collapsible)
├────────────────────────────────────┤
│  You                               │
│  Can you look at the auth bug?     │
│                                    │
│  Claude                            │
│  Sure — let me check the code…     │
│                                    │
│  ▸ Read(src/auth.rs)               │   ← collapsed tool_call card
│  ▸ Bash(cargo test auth)           │
│                                    │
│  Found it. The token expiry check… │
│  ```rust                           │
│  fn check_expiry(…) -> bool { … }  │   ← syntax-highlighted code block
│  ```                               │
├────────────────────────────────────┤
│ /                          📎  ➤   │   ← composer
└────────────────────────────────────┘
```

- Timeline scrolls; SDK provides paginated history.
- Rendering primitives: `MarkdownText`, `CodeBlock`, `ToolCallCard`, `AttachmentImage`, `AttachmentFile`. No bubbles around bot messages (ChatGPT-style); user messages get a subtle background.
- Tool call cards: collapsed shows "tool name + 1-line arg summary"; tap to expand args + result. Status icon: spinner / checkmark / red x.
- Ask-user sheet appears as a modal half-sheet anchored to the prompt event; non-dismissable until answered or expired.
- Composer: text field with growing height. `/` prefix opens the slash palette: a list of recognised commands (`/start`, `/stop`, `/restart`, `/resume`, `/sessions`, `/status`, …). Selecting one inserts it; user can edit args. The palette is local — driven by a static list per bot for MVP (Matron app knows the Claude bridge's commands).
- 📎 = attachment picker (image, file). Sent as `m.image` / `m.file`. No camera in MVP.
- Long-press a message → copy / share / view source. No reactions, replies, edits.

### 5.5 — Bot profile (ⓘ from chat header)

- Bot avatar, display name, Matrix ID.
- "All chats with this bot" — a list of every room with this bot, newest first.
- "Start new chat" button (same as ✏️ from list, prefilled with bot).

### 5.6 — Settings

Single screen:
- Account (display name, avatar, Matrix ID, sign out).
- This device (device ID, verification status, "Show recovery key").
- Notifications (system push enabled; per-chat mute is in long-press, not here).
- Server (URL, version).
- About (build version, licenses).

### 5.7 — Verification (ongoing)

When a new chat appears with an unverified device on the bot's side (e.g. just ran `dev-boxer add-bot` for a new box), the chat view shows a banner: "This device hasn't been verified — verify to read encrypted messages." Tap → SAS emoji compare. Matches the existing dev-boxer flow.

### 5.8 — Search

Unified search across chat titles, bot names, and message content.

- Search bar in the chat list opens the search screen.
- Two result sections: **Chats** (titles/bot-name match) and **Messages** (FTS5 plaintext match).
- Each Message result row: bot avatar, chat title, sender, snippet with the matched terms highlighted, relative time.
- Tap a Message result → open chat scrolled to that event with the message briefly highlighted.
- Empty state on first run shows "Indexing chats…" with progress; backfill runs async.

Implementation: see §6 (data flow) and §9 (search storage details).

### 5.9 — Mac-specific UX

The macOS app is a native SwiftUI target with single-main-window focus (no multi-window sprawl). All flows above apply; Mac additions:

**Window management**
- Single `WindowGroup` for the main window. Minimum size **800×600**, default opens at **1100×750**.
- `.windowResizability(.contentMinSize)`; SwiftUI restores size + position automatically.
- Closing the last window quits the app (no menu-bar-only mode in MVP).

**Settings scene**
- Native `Settings { SettingsView }` — opens with **`⌘,`** as a Preferences window.
- Tabbed layout (Account / This Device / Notifications / Server / About) using `TabView` with the macOS Preferences look. Same `SettingsViewModel` from `MatronShared`; iOS renders as a stack of sections, Mac as Preferences tabs.

**Menu bar (`.commands { ... }`)**

| Menu | Item | Shortcut |
|---|---|---|
| File | New Chat | `⌘N` |
| | Sign Out… | — |
| Edit | Find in Chat | `⌘F` |
| | Slash Command | `⌘K` |
| View | Toggle Sidebar | `⌘⇧S` |
| | Increase / Decrease / Reset Font Size | `⌘+` / `⌘-` / `⌘0` |
| Window | (default) | |
| Help | Verify This Device… | — |
| | Show Recovery Key… | — |

**Toolbar (per-window)**
- Left: sidebar toggle button (mirrors `⌘⇧S`).
- Center: chat title + `session_meta` strip (model · workdir, when present).
- Right: ⓘ info button → bot profile sheet; search field (focused by `⌘F`).

**Hover states**
- Chat list rows: subtle background tint + show "last message preview" line on hover (hidden by default to keep list dense).
- Tool-call cards: cursor turns to pointer; "Click to expand" hint on hover.

**Drag-and-drop**
- Composer accepts dragged images and files via `.onDrop(of: [.image, .fileURL], delegate: ...)`.
- Chat list: not droppable in MVP (no chat reordering).

**Layout structure**
- 2-column `NavigationSplitView` (sidebar = chat list; detail = current chat).
- Bot profile renders as a sheet (single-window-focus pattern; no third column).

---

## 6 — Data flow

### 6.1 — Sync loop

- `SyncService` owns the `Client` and starts sliding sync on launch.
- `RoomListService` emits a stream of room summaries (added/updated/removed). `ChatService` maps them to `ChatSummary` DTOs and exposes them to the chat-list ViewModel via an `AsyncSequence`.
- Per-room timelines are lazily created on demand by the chat ViewModel (`Timeline.subscribe`).
- All event decryption happens inside the SDK; the app sees plaintext events in its callbacks.

### 6.2 — Decryption hook → search index

- `ChatService` registers a per-room timeline listener.
- For each `m.text` message (and tool_call result), `SearchService.index(roomID, eventID, sender, timestamp, plaintext)` is called.
- `SearchService` writes to SQLite FTS5 in a background queue.
- Backfill: on first launch, `SearchService.backfill(roomID)` paginates the room timeline backward (via the SDK) and indexes results until either the room start is hit or a configurable depth limit (default: 1000 events / 90 days).

### 6.3 — Push wakeup

**iOS path:**
- NSE receives APNs push with `event_id` + `room_id`.
- `NotificationService` (in `MatronNSE`) opens a read-only SDK client against the shared crypto store (App Group container).
- Calls `NotificationClient.getNotification(roomID, eventID)`.
- Builds title/body/avatar, returns the rewritten `UNNotificationContent`.
- App, when next foregrounded, runs sync to catch up — push wakeups don't update app state directly.

**Mac path:**
- App's `UNUserNotificationCenterDelegate` receives the silent APNs push directly (no extension; Mac apps receive notifications in-process).
- Calls into the same `MatronShared.Push.PushDecoder` — single-process access to the crypto store, no App Group complications.
- Updates the notification's title/body/avatar via the completion handler, posts it to the Notification Center.
- App is already running (or relaunched); state may be live, so push handling can opportunistically refresh the affected room as well.

### 6.4 — New chat creation

- App: `ChatService.createChat(with: BotID)` calls `Client.createRoom(invite: [bot_user_id], encrypted: true, isDirect: false)`.
- The new room appears in the next sliding sync update.
- Bot side: bridge auto-joins on invite, spawns a fresh Claude session, writes `chat.matron.session_meta`.
- UI navigates to the chat view as soon as the room ID is known (timeline starts empty, fills as bot joins and sends initial message).

---

## 7 — E2EE, verification & key recovery

### 7.1 — Crypto store

**iOS:**
- SDK creates a SQLite-backed crypto store inside the App Group container (`group.chat.matron`).
- App and NSE both open the SAME store. matrix-rust-sdk supports this via internal locking.
- Store is encrypted at rest with a passphrase derived from a Keychain-stored key (Keychain access group shared with NSE).

**Mac:**
- Single-process — no App Group / NSE sharing required.
- Store lives in `~/Library/Application Support/chat.matron.mac/` (`NSApplicationSupportDirectory`).
- Same encrypted-at-rest scheme: passphrase derived from a Keychain-stored key. macOS Keychain auto-syncs to iCloud Keychain when the user has it enabled, so a Mac install can pick up keys from the iOS install via SSSS recovery (per §7.4).

### 7.2 — Device verification (SAS)

**Scenario A — first-ever device (true greenfield user):**
- Generate cross-signing keys + SSSS recovery key on login.
- Show recovery key once; require user to tick "I've saved this." Re-enter it to confirm.
- Store recovery key encrypted in iCloud Keychain so iCloud-restored device installs can recover.

**Scenario B — additional device:**
- App requests verification from another logged-in device.
- That device shows the SAS request; user accepts.
- Both screens show the 7-emoji set; user confirms match.
- On match, this device is signed by the user's master key.
- Fallback: enter recovery key directly if no other device is reachable.

### 7.3 — Verifying bots

Bots from `dev-boxer add-bot` cross-sign themselves and emit a verification request. The app must:
- Surface incoming verification requests as a top-of-list banner ("`@box4` wants to verify").
- Tap → SAS emoji screen, identical to device verification.
- On match, the bot is trusted; future messages decrypt without warning.
- Chat view shows an inline banner for unverified bot devices, linking to the verification flow.

### 7.4 — Key backup

- SSSS (server-side secret storage) backed by the recovery key.
- Auto-restore on new device install: user enters recovery key during onboarding's verification step → keys download → message history decrypts.
- No "key backup setup wizard" — automatic on first login.

### 7.5 — Trust posture

We do **not** auto-trust new bot devices. Unverified-device messages show a warning marker; chat header offers verification. Matches the `dev-boxer` model.

### 7.6 — What the app does NOT do

- No identity-server lookups (3PID).
- No device manager screen with per-device sign-out (deferred; sign-out only of *this* device from Settings).
- No room-key sharing UI (SDK handles request-and-share automatically with verified devices).
- No QR-code verification (SAS only — simpler and we control both ends).

---

## 8 — Push notifications

### 8.1 — Server side

- A **Sygnal**-compatible HTTP pusher runs alongside `matron-server`. Sygnal itself is Apache 2.0 — we can use it directly, or write a thin replacement.
- Pusher holds APNs auth keys (signed JWT) for **two** bundle IDs: `chat.matron.ios` (iPhone/iPad app) and `chat.matron.mac` (Mac app), each with `.dev` variants for sandbox builds.
- When the apps register a push token (see §8.2), they tell the homeserver to send pushes via this pusher with the appropriate `app_id`.

### 8.2 — App side

**iOS** (Matron target):
On launch (after auth):
- Request push notification permission.
- Get APNs device token.
- Call `POST /_matrix/client/v3/pushers` with `app_id = chat.matron.ios` (or `.dev` for debug builds).
- Configure default push rules: notify on every event in joined rooms (only bot rooms exist in this ecosystem; per-room mute is in the long-press menu).

**Mac** (MatronMac target):
On launch (after auth):
- Request notification permission via `UNUserNotificationCenter`.
- Get APNs device token via `NSApplication.registerForRemoteNotifications()`.
- Same pusher registration call, but `app_id = chat.matron.mac` (or `.dev`).
- Same push rules.

### 8.3 — Receiving a push

**iOS:**
- Server-side push rule matches → pusher sends a silent APNs notification with `event_id` + `room_id` (no message content; encrypted events are opaque to the server).
- iOS wakes the NSE.
- NSE opens shared crypto store + SDK client (read-only mode) via the App Group, decrypts the event, returns title/body/avatar.

**Mac:**
- Same APNs path; the silent push arrives directly to the running app's `UNUserNotificationCenterDelegate`.
- Delegate calls into `MatronShared.Push.PushDecoder` in-process — single-process crypto store access, no App Group needed.
- Same title/body/avatar build path.

**Both platforms:**
- Notification: title = bot display name, body = decrypted text (or "📎 image" / "🔧 tool call"), thread identifier = room ID.
- App icon badge = total unread count from the room list summary.

### 8.4 — Tap to open

- **iOS:** Tapping a notification deep-links into the chat view for that room ID. Single SwiftUI navigation push from chat list, so back returns to the list.
- **Mac:** Tapping focuses the main window and navigates the detail column to the room. The sidebar updates selection so it's clear which chat is open. If the app is hidden, it activates first.

---

## 9 — Search storage

### 9.1 — Schema

```sql
CREATE VIRTUAL TABLE messages_fts USING fts5(
    room_id UNINDEXED,
    event_id UNINDEXED,
    sender UNINDEXED,
    timestamp UNINDEXED,
    body,
    tokenize='porter unicode61'
);

CREATE TABLE indexed_rooms (
    room_id TEXT PRIMARY KEY,
    backfill_complete INTEGER NOT NULL DEFAULT 0,
    backfill_oldest_event_id TEXT,
    backfill_event_count INTEGER NOT NULL DEFAULT 0
);
```

### 9.2 — File location & protection

- **iOS path:** `App Group / matron-search.sqlite`. `NSFileProtectionComplete` so it's encrypted at rest with the device passcode (file is pre-created with the protection attribute set, then opened — see Phase 6 plan).
- **Mac path:** `~/Library/Application Support/chat.matron.mac/matron-search.sqlite`. macOS doesn't have iOS-style file protection classes; encryption at rest comes from FileVault (which the user is responsible for enabling). The path is sandbox-private regardless.
- The DB is wiped on sign-out on both platforms.

### 9.3 — Index lifecycle

- New events: indexed inline as the timeline listener fires, on a background `DispatchQueue`.
- Backfill: on first launch per room, paginate backward via SDK until depth limit or room start. Default limit: 1000 events or 90 days, whichever comes first. Configurable later.
- Update: edited messages aren't supported (we cut edits) so no update path needed; redactions remove the row.

### 9.4 — Query

```sql
SELECT room_id, event_id, sender, timestamp,
       snippet(messages_fts, 4, '<mark>', '</mark>', '…', 32) AS snippet
FROM messages_fts
WHERE messages_fts MATCH ?
ORDER BY timestamp DESC
LIMIT 100;
```

Snippets are rendered with the matched terms highlighted.

---

## 10 — Testing strategy

Pragmatic, not exhaustive. The SDK is well-tested upstream; our job is to test the seams.

### Unit tests (XCTest) — `MatronShared` services

- Auth: server URL validation, login flow happy path + auth errors (mock HTTP).
- Chat: timeline → ChatSummary mapping, custom-event parsing (`tool_call`, `ask_user`, `session_meta`) — round-trip JSON fixtures.
- Push: NSE notification payload construction from a fixture event.
- Search: FTS index/query round-trip, snippet generation, backfill bookkeeping.
- Verification: SAS state machine glue (the SDK exposes the state, we test our wrapper).
- Models: pure-Swift DTO tests for any non-trivial mapping.

### ViewModel tests — `Matron` features

- Drive each ViewModel with a fake service (protocol-based). Assert the published state after each input.
- Cover: chat list grouping by recency, new-chat creation flow, slash-command palette filtering, ask-user sheet state transitions, search-result ordering.

### Snapshot tests (swift-snapshot-testing) — rendering primitives only

- `MarkdownText`, `CodeBlock`, `ToolCallCard` (collapsed + expanded + each status), `AskUserSheet` (text/choice/multi/boolean variants), `AttachmentImage`, `AttachmentFile`, `MessageBubble`, `SessionMetaHeader` (collapsed + expanded).
- Each primitive snapshots **6 variants**: `{iOS, Mac} × {light, dark, accessibility5}`.
- Mac-only chrome (toolbar layouts, command-menu surfaces) snapshots under Mac scheme only; iOS-only chrome (tab bars if any) under iOS scheme only.
- Not snapshotting full screens — too brittle, low value.

### Integration tests — one happy-path flow against a real homeserver

- Spin up a test matron-server in CI (docker-compose), create user, create bot, send a message round-trip, assert decryption.
- Two CI jobs: iOS Simulator + macOS host. Same `HappyPathTests.swift` runs against both schemes (`MatronIntegrationTests` for iOS, `MatronMacIntegrationTests` for Mac). ~5 min added CI time per push.
- Catches "did we wire the SDK up correctly" regressions that no unit test will, on both platforms.

### Manual test checklist (`docs/manual-tests.md`)

Split into platform sections:

**iOS per-TestFlight regression**
- SAS verification with a real other device.
- Push notification arrives on a physical iPhone/iPad (TestFlight build).
- Attachment picker (image, file) end-to-end.

**Mac per-App-Store-build regression**
- Menu bar items + keyboard shortcuts work (`⌘N`, `⌘F`, `⌘K`, `⌘⇧S`, `⌘+`/`-`/`0`, `⌘,`).
- Sidebar toggle, window position restores, drag-and-drop attachments into composer.
- Settings Preferences window opens with `⌘,`; tabs render correctly.
- Mac push notification arrives on a real Mac with the app backgrounded.

**Cross-platform smoke**
- Sign in with the same account on iOS and Mac → both see same chat list → send from one → receive on the other within seconds.

Run before each TestFlight build / Mac App Store build.

### What we don't test

- The SDK's own behavior (encryption, sliding sync, etc.) — trust upstream.
- SwiftUI navigation transitions — too much effort, too little payoff.
- Visual design beyond snapshots of primitives.

---

## 11 — Out of scope (deferred to future specs)

Captured here so the door's open without bloating MVP.

- **In-app bot provisioning** — UI to call a future `matron-server` API for "create new bot account." Replaces the `dev-boxer add-bot` CLI for end users.
- **Multi-bot rooms** — group rooms with multiple bots coordinating. Member list, mentions, etc.
- **Threads** — if any bots ever need them.
- **iPad-optimised bespoke layouts** — current spec gives iPad an adaptive `NavigationSplitView` automatically; iPad-specific UI (drag-between-chats, multi-column custom layouts) is a future spec.
- **Mac multi-window** — single main window in MVP per "focus on one thing at a time" stance. Detached chat windows / multiple main windows could come later if usage signals demand.
- **Mac menu-bar-only mode** — currently closing the last window quits the app; running as a faceless menu-bar utility (like Slack's small mode) is deferred.
- **Reactions, replies, edits** — if user research surfaces a need.
- **Voice / video calls** — Matrix Element Call integration.
- **Background sync without push** — silent sync to keep local state warm. Currently, app catches up on launch + push wakeups handle real-time.
- **Multiple accounts** — connecting to multiple matron-servers from one app install.
- **Widget / Lock Screen activity (iOS)** — show current chat status on Lock Screen / Home Screen.
- **Mac widgets / Today extension** — same idea on Mac.
- **Offline composer / queued sends** — currently send fails if offline. Could queue locally and retry.
- **Server-side / cross-device search index** — current search is per-device only.
- **Camera capture in composer (iOS)** — only photo library / files in MVP.
- **Device manager screen** — sign-out only of *this* device from MVP Settings.

---

## 12 — License & legal

### 12.1 — Project licence

- **Public licence: AGPL-3.0.** Source is published under AGPL-3.0; third parties redistributing source or running modified versions over a network must comply (publish their source under AGPL-3.0).
- **Commercial licensing available by arrangement.** Matron HQ retains copyright and offers commercial terms to redistributors who can't comply with AGPL. This is the same dual-licensing model Matrix.org / Element / Synapse use.
- **App Store distribution by the copyright holder is unaffected.** The iOS and Mac binaries on Apple's App Stores are licensed to end users under the standard App Store EULA; AGPL governs source redistribution by third parties only. The copyright holder is free to distribute their own code under any terms.

### 12.2 — Repo posture

- The `matronhq/matron-ios` repo currently contains a fork of `element-hq/element-x-ios` (AGPL). Before any new code lands, the repo will be re-initialised: history wiped, fork relationship dropped. Fresh `LICENSE` (AGPL-3.0) and clean Matron HQ copyright lineage committed in Phase 1.
- Element X iOS may be **studied** for architectural patterns (architectures aren't copyrightable). No code translation, no derivative work. When in doubt, build from first principles using only the matrix-rust-sdk-swift API surface as reference.

### 12.3 — Dependencies

- Dependencies must be AGPL-compatible:
  - Apache 2.0 ✓ (matrix-rust-sdk-swift, swift-snapshot-testing).
  - MIT / BSD / MPL-2.0 ✓.
  - LGPL with linking exception ✓.
  - **Pure GPL without an explicit AGPL permission is excluded** (would conflict with the AGPL distribution).
- Bridge code (`claude-matrix-bridge`) remains AGPL — that's fine, it's a separate process talking over the wire. The AGPL "use" boundary doesn't extend to network clients.

### 12.4 — Contributor agreement

- Dual-licensing requires that the copyright holder retain the right to relicense contributions under both AGPL and commercial terms. Either:
  - **Copyright assignment** — contributors assign copyright to Matron HQ on contribution; or
  - **Contributor License Agreement (CLA)** — contributors grant Matron HQ a perpetual, irrevocable, worldwide licence to use, modify, sublicense, and relicense their contribution under any terms.
- MVP plan uses **option 2 (CLA)** via `cla-assistant.io` (GitHub bot blocks unsigned PRs from external contributors). `CONTRIBUTING.md` explains the model; `.cla.md` holds the CLA text. Both committed in Phase 1.
- Internal/founder commits don't need a separate CLA — copyright is held by the legal entity that employs the founders.

### 12.5 — App Store submission

- **iOS App Store** + **Mac App Store** submissions require:
  - Privacy policy URL (one URL covers both apps).
  - App Privacy disclosures: Matrix ID + push token transmitted to the user's homeserver; no third-party analytics.
  - Encryption export compliance: uses standard E2EE via matrix-rust-sdk — qualifies for `ITSAppUsesNonExemptEncryption=NO` if we use only standard ciphers via the SDK. Verify before submission for both binaries.
  - Two App Store Connect records (one per platform) since iOS and Mac App Store binaries are submitted separately.
  - Mac builds are notarized via App Store Connect upload (no separate notarization step).
