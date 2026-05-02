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
