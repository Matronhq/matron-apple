# Matron — manual test checklist

Run before every TestFlight build (iOS) and every Mac App Store build.

## Phase 1 (Foundation)

### iOS — sign-in flow

- [ ] Cold-launch on iPhone simulator (or device) — sees Sign-in screen.
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

## Phase 2 (Chat experience) — iOS

### Chat navigation

- [ ] Tap a chat row → `ChatView` opens with that chat's title.
- [ ] Tap ⓘ in the toolbar → `BotProfileView` opens, showing all chats with that bot.
- [ ] From `BotProfileView`, tap "Start new chat" → the bot picker sheet opens; pick a bot → new room is created and `ChatView` opens with an empty timeline.
- [ ] Tap "← Back" on the nav bar → returns to the chat list, scrolled to its previous position.
- [ ] Sign in fresh on a brand-new account with no rooms → chat list shows the "no chats yet" empty state (not a blank list).

### Chat list actions

- [ ] Pull the chat list down → spinner appears, list refreshes (round-trips via `ChatService.refresh()`).
- [ ] Long-press a chat row → context menu shows "Mute" and "Leave" actions.
- [ ] Tap "Mute" → row's bot stops sending iOS notifications; verify by sending a message from the bot.
- [ ] Tap "Leave" → row disappears from the list; the room is no longer in `chatSummaries()`.

### New chat creation

- [ ] Tap ✏️ on the chat list → `NewChatSheet` opens listing known bots.
- [ ] Pick a bot → new room is created, `NewChatSheet` dismisses, `ChatView` opens automatically.
- [ ] Verify the bot has joined (state change appears or first bot message comes through).

### Sending

- [ ] Type a plain text message and send → appears in the timeline as "me" (right-aligned).
- [ ] Type `/` → slash palette appears. Type `/sta` → only `/start`, `/status` are shown.
- [ ] Tap a slash command → it pre-fills the composer **and the palette closes** (regression for the palette-stays-open bug — round-1 bugbot fix #1).
- [ ] Tap send on a slash-prefilled message → message goes through; palette stays closed for the rest of the input cycle.
- [ ] Type only spaces → send button stays disabled (regression for the whitespace-only-send bug — round-1 bugbot fix #3).
- [ ] Tap 📎 → choose a photo → sends as `m.image`. Bot rooms should ack receipt.
- [ ] Tap 📎 → choose two photos of the same type back-to-back → both upload distinct files (regression for the temp-filename collision — round-2 bugbot fix #4).
- [ ] Tap 📎 → choose a file → sends as `m.file`. Bot rooms should ack receipt.
- [ ] Send a local message → confirm the timeline auto-scrolls to the bottom **even before the remote echo arrives** (regression for the `.onChange(of: items.count)` bug — round-3 bugbot fix #5).

### Receiving + rendering

- [ ] Bot sends a markdown reply with a code block → renders with monospaced code; the inline Copy button writes to the system pasteboard.
- [ ] Bot sends an image → renders via `AttachmentImage` (image bytes resolved via `MediaService`; the in-memory cache prevents re-fetch on scroll — round-2 bugbot fix #2).
- [ ] Bot sends a file → renders as `AttachmentFile` with filename + size.
- [ ] Bot sends a message that fails to decode media (simulate by killing network mid-fetch) → no infinite re-fetch loop in the network log (regression for round-1 bugbot fix #8).

### History

- [ ] Scroll to the top of the timeline → older messages paginate in.
- [ ] Long-press a text message → menu shows Copy / Share / **View source**.
- [ ] Tap "View source" → sheet opens with the DTO printed as pretty JSON; tap **Done** to dismiss.
- [ ] Long-press an image / file / state-change row → "View source" still appears (it's not text-only).

### Read state

- [ ] Open a chat that has unread messages → confirm the unread count clears (regression for the `markAsRead` race — round-3 bugbot fix #3).
- [ ] Open the same chat a second time after sending one new message → the new message is included in the read receipt (no off-by-one).

## Phase 2 (Chat experience) — Mac

### Chat navigation (Mac)

- [ ] Click a chat row in the sidebar → detail column shows `MacChatView` with that chat's title.
- [ ] With chat A selected, send a message in another chat (e.g. via iOS) → confirm chat A stays selected on Mac (regression for round-3 bugbot fix #6, the `Hashable` selection bug).
- [ ] Click ⓘ in the toolbar → `MacBotProfileSheet` opens as a full-window sheet.
- [ ] From the sheet, click "Start new chat" → sheet dismisses, `MacNewChatSheet` opens.
- [ ] Click another chat in the sheet's "All chats" list → sidebar selection moves to that chat, sheet dismisses.
- [ ] With no selection, the detail column shows the "Select a chat" placeholder.

### Chat list actions (Mac)

- [ ] Hover a chat row → background tint appears; cursor stays default.
- [ ] Right-click a chat row → context menu shows "Mute" and "Leave".
- [ ] Press `⌘R` (or click the toolbar refresh button) → forces a sync; new messages flow in.
- [ ] No pull-to-refresh gesture (Mac has no touch gesture); refresh works only via `⌘R` / button.

### New chat creation (Mac)

- [ ] Click ✏️ on the sidebar toolbar → `MacNewChatSheet` opens.
- [ ] Pick a bot → new room is created, sheet dismisses, sidebar selection moves to the new room.

### Sending (Mac)

- [ ] Type a plain text message in the composer → send via `↩` → appears as "me" in the timeline.
- [ ] Type `/sta` → slash palette appears with `/start`, `/status`.
- [ ] Press `⌘K` with empty composer → slash palette opens (pinned via `palettePinnedOpen`).
- [ ] Drag an image onto the composer → `ComposerDropDelegate` handles it → image sends as `m.image`.
- [ ] Drag a file (e.g. PDF) onto the composer → sends as `m.file`.
- [ ] Send a local message → timeline scrolls to bottom before the remote echo lands.

### Menu bar (Mac)

- [ ] **File** → **New Chat** (`⌘N`) → `MacNewChatSheet` opens.
- [ ] **File** → **Sign Out…** → posts `.signOut` notification (full sign-out wired in Phase 7).
- [ ] **Edit** → **Find in Chat** (`⌘F`) → focuses the toolbar search-field placeholder (full search lands Phase 6).
- [ ] **Edit** → **Slash Command** (`⌘K`) → opens the slash palette in the focused composer.
- [ ] **View** → **Toggle Sidebar** (`⌘⇧S`) → sidebar collapses / expands.
- [ ] **View** → **Increase / Decrease / Reset Font Size** (`⌘+` / `⌘-` / `⌘0`) → notification fires (full font-scale wiring lands in Phase 7).
- [ ] **Help** → **Verify This Device…** / **Show Recovery Key…** → entries are present (Phase 3 wires the flows).

### Receiving + rendering (Mac)

- [ ] Bot sends markdown with a code block → `MarkdownText` + `CodeBlock` render correctly; the Copy button writes to `NSPasteboard`.
- [ ] Bot sends an image → `AttachmentImage` renders the resolved `mxc://` content.
- [ ] Bot sends a file → `AttachmentFile` shows filename + size.

### History (Mac)

- [ ] Scroll to the top of the timeline → older messages paginate in.
- [ ] Right-click a message → menu shows Copy / Share / **View source**.
- [ ] "View source" opens a sheet with the DTO printed as pretty JSON; click **Done** (or press Esc / ⏎) to dismiss.

### Read state (Mac)

- [ ] Click into a chat with unread messages → confirm the unread badge clears.

## Phase 2 — Cross-platform

- [ ] Sign in to the same account on iOS and macOS. Send a message from iOS → it appears on Mac within a few seconds (sliding-sync).
- [ ] Send a message from Mac → appears on iOS within a few seconds.
- [ ] Send an image from iOS → renders correctly on Mac (and vice-versa).
- [ ] Mute a room from iOS → confirm Mac no longer pings (push wiring lands in Phase 4, but the in-app notification setting should round-trip).
- [ ] Leave a room from one platform → it disappears from the other within a few seconds.

### What is NOT tested in Phase 2

- Verification UX / cross-device session verification (Phase 3).
- Push notifications (Phase 4).
- Custom event types — `tool_call`, `ask_user`, `session_meta` rendering (Phase 5).
- Message search (Phase 6).
- Mac Settings tabs (Phase 7).
- Sign-out flow end-to-end (Phase 7 — File → Sign Out posts the notification today, but the listener side ships in Phase 7).
- Mac font-scaling end-to-end (Phase 7 — `⌘+` / `⌘-` / `⌘0` post notifications today, but no view yet observes them).
- Settings deep-links from BotProfile (Phase 7).
