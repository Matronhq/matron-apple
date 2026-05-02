# Matron iOS — design spec

**Date:** 2026-05-02
**Status:** Draft, awaiting user review
**Repo (target):** `matronhq/matron-ios` (to be re-initialised; current contents are an Element X fork under AGPL and will be removed before any new code lands)

---

## 1 — Goals & non-goals

### Goals

- Native iOS app for Matrix, App Store distributable. No AGPL or copyleft code in the binary.
- Bot-first chat UX: ChatGPT/Claude.ai-inspired layout — sidebar of chats, single-pane chat view, minimalist.
- Optimised for talking to AI bots over E2EE Matrix in a closed personal ecosystem (the user's own homeserver, only their own bots).
- One Matrix room per chat conversation; multiple chats per bot. Bot auto-titles each chat via server-side Gemini Flash.
- Excellent rendering of long markdown + code blocks, plus distinctive UX for tool-call cards and "ask the user" prompts.
- E2EE on by default with first-class device verification (SAS) and recovery key flows.
- iOS push notifications via APNs (silent encrypted pushes, decrypted on-device by a Notification Service Extension).
- Local full-text search across all chats.

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
- macOS/iPadOS-specific layouts (the SwiftUI codebase will run on iPad but layouts are iPhone-first in MVP).

---

## 2 — High-level architecture

```
┌──────────────────────────────────────────────────────────┐
│                       iOS app target                     │
│  ┌────────────────────────────────────────────────────┐  │
│  │              SwiftUI views (per feature)           │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │ binds to                        │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │   @Observable ViewModels (per screen / feature)    │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │ calls                           │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │              Service layer (Swift)                 │  │
│  │   AuthService · SyncService · ChatService ·        │  │
│  │   PushService · VerificationService · MediaService │  │
│  │   SearchService                                    │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │ wraps                           │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │   matrix-rust-sdk-swift  (Apache 2.0, via SPM)     │  │
│  │   Client · RoomListService · Timeline · Encryption │  │
│  └──────────────────────┬─────────────────────────────┘  │
└─────────────────────────┼────────────────────────────────┘
                          │ sliding sync over HTTPS
                          ▼
                  matron-server (Tuwunel)
                          │
                          ▼
                  bot accounts (Claude bridge, etc.)

┌──────────────────────────────────────────────────────────┐
│         NotificationServiceExtension target              │
│  Receives silent APNs push → uses matrix-rust-sdk-swift  │
│  (NotificationClient) to fetch + decrypt the event →     │
│  rewrites the notification with cleartext title/body.    │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│         Sygnal-compatible HTTP pusher (server-side)      │
│  Lives alongside matron-server. Receives Matrix push     │
│  events, forwards as silent APNs pushes to the app.      │
└──────────────────────────────────────────────────────────┘
```

### Three Xcode targets

1. **`Matron`** — the iOS app (SwiftUI, MVVM, iOS 17+).
2. **`MatronNSE`** — Notification Service Extension (decrypts push payloads).
3. **`MatronShared`** — local Swift Package holding services + models reused by app and NSE.

### Architectural choices

- **Pattern: MVVM, no Coordinators.** SwiftUI views bind to `@Observable` ViewModels. Navigation goes through native `NavigationStack` typed paths. Coordinators (Element X-style FlowCoordinator) are deliberately omitted — they duplicate `NavigationStack`'s declarative model. If complex multi-screen flows arise later, introduce Coordinators per-flow rather than as a global pattern.
- **Sync: matrix-rust-sdk sliding sync** — required for responsive room list. Tuwunel (matron-server) supports it.
- **Crypto store sharing** — app and NSE both open the same SDK crypto store inside an App Group container (`group.chat.matron`). matrix-rust-sdk supports concurrent-process access via internal locking.
- **Minimum target: iOS 17.** Gives us `@Observable`, modern `NavigationStack`, mature SwiftUI APIs. Matches Element X's target.
- **License posture: nothing AGPL/GPL in the binary.** matrix-rust-sdk-swift (Apache 2.0) and any other SPM dependencies must be Apache 2.0 / MIT / BSD. Element X is studied for architectural inspiration only — no code translation, no derivative work.

---

## 3 — Module structure

```
MatronShared/                    (local SPM package, depended on by Matron + MatronNSE)
├── Sources/
│   ├── Auth/                    AuthService, login, logout, server URL discovery
│   ├── Sync/                    ClientProvider, SyncService (sliding sync wrapper)
│   ├── Chat/                    ChatService, RoomListWrapper, Timeline wrapper
│   ├── Verification/            SAS verification flow, recovery key
│   ├── Push/                    Pusher registration, NSE-shared decoding
│   ├── Media/                   Image/file fetch + cache, mxc:// resolution
│   ├── Search/                  SQLite FTS5 service (see §5.8)
│   ├── Models/                  Plain-Swift DTOs: ChatSummary, BotIdentity, Message
│   ├── Events/                  Custom event type defs (chat.matron.tool_call, …)
│   └── Storage/                 App Group paths, crypto store init
└── Tests/                       Unit tests per module

Matron/                          (iOS app target)
├── App/                         MatronApp, root navigation, session restore
├── Features/
│   ├── Onboarding/              Combined server URL + login screen, then verification
│   ├── ChatList/                Sidebar, chat-summary rows, new-chat button, search bar
│   ├── Chat/                    Timeline view, composer, slash command palette
│   │   ├── Rendering/           Markdown, code block, tool-call card, ask-user sheet
│   │   └── Composer/            Input field, slash menu, attachment picker
│   ├── BotProfile/              Per-bot view: list of chats with that bot
│   ├── Verification/            SAS verification UI, recovery flows
│   ├── Search/                  Search results screen (chats + messages)
│   └── Settings/                Account, push prefs, server info, sign-out
├── Resources/                   Assets, Localizable, fonts
└── DesignSystem/                Colors, typography, spacing, shared View modifiers

MatronNSE/                       (Notification Service Extension target)
├── NotificationService.swift    Entry point, calls into MatronShared.Push
└── Info.plist
```

### Conventions

- `Features/` modules follow a uniform shape: `*View.swift`, `*ViewModel.swift`, optional component sub-folder. No cross-feature imports — features only talk to the service layer.
- `DesignSystem/` is the single source of truth for color, type ramp, spacing tokens, and shared view primitives (`ChatBubble`, `ToolCallCard`, `CodeBlock`, etc.).
- `MatronShared` services expose protocol interfaces for testing (real impl + fake impl side-by-side per protocol).

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

ChatGPT/Claude.ai-inspired layout. Phone-first; iPad gets a split view "for free" via SwiftUI.

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

- NSE receives APNs push with `event_id` + `room_id`.
- `NotificationService` (in `MatronNSE`) opens a read-only SDK client against the shared crypto store.
- Calls `NotificationClient.getNotification(roomID, eventID)`.
- Builds title/body/avatar, returns the rewritten `UNNotificationContent`.
- App, when next foregrounded, runs sync to catch up — push wakeups don't update app state directly.

### 6.4 — New chat creation

- App: `ChatService.createChat(with: BotID)` calls `Client.createRoom(invite: [bot_user_id], encrypted: true, isDirect: false)`.
- The new room appears in the next sliding sync update.
- Bot side: bridge auto-joins on invite, spawns a fresh Claude session, writes `chat.matron.session_meta`.
- UI navigates to the chat view as soon as the room ID is known (timeline starts empty, fills as bot joins and sends initial message).

---

## 7 — E2EE, verification & key recovery

### 7.1 — Crypto store

- SDK creates a SQLite-backed crypto store inside the App Group container (`group.chat.matron`).
- App and NSE both open the SAME store. matrix-rust-sdk supports this via internal locking.
- Store is encrypted at rest with a passphrase derived from a Keychain-stored key (Keychain access group shared with NSE).

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
- Pusher holds an APNs auth key (signed JWT) for the Matron app's bundle ID.
- When the iOS app registers a push token, it tells the homeserver to send pushes via this pusher.

### 8.2 — App side

On launch (after auth):
- Request push notification permission.
- Get APNs device token.
- Call `POST /_matrix/client/v3/pushers` to register the token.
- Configure default push rules: notify on every event in joined rooms (only bot rooms exist in this ecosystem; per-room mute is in the long-press menu).

### 8.3 — Receiving a push

- Server-side push rule matches → pusher sends a silent APNs notification with `event_id` + `room_id` (no message content; encrypted events are opaque to the server).
- iOS wakes the NSE.
- NSE opens shared crypto store + SDK client (read-only mode), decrypts the event, returns title/body/avatar.
- Notification: title = bot display name, body = decrypted text (or "📎 image" / "🔧 tool call"), thread identifier = room ID.
- App icon badge = total unread count from the room list summary.

### 8.4 — Tap to open

- Tapping a notification deep-links into the chat view for that room ID. Single SwiftUI navigation push from chat list, so back returns to the list.

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

- Path: `App Group / matron-search.sqlite`.
- iOS `NSFileProtectionComplete` so it's encrypted at rest with the device passcode.
- The DB is wiped on sign-out.

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

- `MarkdownText`, `CodeBlock`, `ToolCallCard` (collapsed + expanded + each status), `AskUserSheet` (text/choice/multi/boolean variants), `AttachmentImage`, `AttachmentFile`.
- Light + dark mode, dynamic type sizes (S, L, XXXL).
- Not snapshotting full screens — too brittle, low value.

### Integration tests — one happy-path flow against a real homeserver

- Spin up a test matron-server in CI (docker-compose), create user, create bot, send a message round-trip, assert decryption.
- One test, end-to-end. Catches "did we wire the SDK up correctly" regressions that no unit test will.

### Manual test checklist (`docs/manual-tests.md`)

- SAS verification with a real other device.
- Push notification arrives on a physical device (TestFlight build).
- Attachment picker (image, file) end-to-end.
- Run before each TestFlight build.

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
- **macOS / iPad-optimised layouts** — current spec runs on iPad but uses iPhone layouts.
- **Reactions, replies, edits** — if user research surfaces a need.
- **Voice / video calls** — Matrix Element Call integration.
- **Background sync without push** — silent sync to keep local state warm. Currently, app catches up on launch + push wakeups handle real-time.
- **Multiple accounts** — connecting to multiple matron-servers from one app install.
- **Widget / Lock Screen activity** — show current chat status on Lock Screen / Home Screen.
- **Offline composer / queued sends** — currently send fails if offline. Could queue locally and retry.
- **Server-side / cross-device search index** — current search is per-device only.
- **Camera capture in composer** — only photo library / files in MVP.
- **Device manager screen** — sign-out only of *this* device from MVP Settings.

---

## 12 — License & legal

- App binary, dependencies, and all bundled code: Apache 2.0 / MIT / BSD only. No GPL/AGPL/LGPL.
- The `matronhq/matron-ios` repo is currently a fork of `element-hq/element-x-ios` (AGPL). Before any new code lands, the repo will be re-initialised: history wiped, fork relationship dropped, fresh `LICENSE` (Apache 2.0 recommended) committed.
- Element X iOS may be **studied** for architectural patterns (architectures aren't copyrightable). No code translation, no derivative work. When in doubt, build it from first principles using only the matrix-rust-sdk-swift API surface as reference.
- Bridge code (`claude-matrix-bridge`) remains AGPL — that's fine, it's a separate process talking over the wire. The AGPL "use" boundary doesn't extend to network clients.
- App Store submission requires: privacy policy URL, App Privacy disclosures (Matrix ID + push token transmitted to user's homeserver; no third-party analytics), encryption export compliance (uses standard E2EE — qualifies for ITSAppUsesNonExemptEncryption=NO if we use only standard ciphers via the SDK; verify before submission).
