# Matron — manual test checklist

Run before every TestFlight build (iOS) and every Mac App Store build.

## Sign-in and the conversation list

### iOS — sign-in flow

- [ ] Cold-launch on iPhone simulator (or device) — sees Sign-in screen.
- [ ] Enter a server URL with no scheme (e.g. `journal.example.com`) — accepted, normalised to HTTPS.
- [ ] Enter a non-loopback server URL with HTTP — rejected with friendly error.
- [ ] Enter blatantly invalid credentials — sees error message in red.
- [ ] Enter valid credentials — transitions to Connecting → conversation list.

### iOS — session persistence

- [ ] After successful sign-in, force-quit the app and re-launch — skips sign-in, goes straight to the conversation list.
- [ ] Reset simulator (Device → Erase All Content) and re-launch — back to sign-in (no stale session).

### iOS — conversation list rendering

- [ ] At least one conversation appears (assumes an agent session exists on the journal).
- [ ] Each row shows the conversation's title (falls back to its id when it has none).
- [ ] Recency grouping headers appear (Today / Yesterday / etc.).
- [ ] Unread dot appears for conversations with unread messages.

### macOS — sign-in flow

- [ ] Cold-launch the `MatronMac` scheme — sees a 480×360 sign-in card window.
- [ ] Press Return after filling the form — submits (default action wired via `keyboardShortcut(.defaultAction)`).
- [ ] Enter blatantly invalid credentials — sees error message in red.
- [ ] Enter valid credentials — window transitions to the split view at ≥800×600.

### macOS — session persistence

- [ ] After successful sign-in, `⌘Q` and re-launch — skips sign-in, opens the split view directly.
- [ ] Reset Application Support (delete `~/Library/Application Support/chat.matron.app/` while app is closed) and re-launch — back to sign-in (no stale session).

### macOS — conversation list rendering

- [ ] Sidebar lists at least one conversation with its title and relative time.
- [ ] Detail column shows "Select a chat" until a row is selected.
- [ ] `⌘,` opens the Settings window.

### Cross-platform smoke

- [ ] Sign in with the same account on iOS simulator and macOS host. Both show the same conversation list once the journal sync settles.

## Chat experience — iOS

### Chat navigation

- [ ] Tap a conversation row → `ChatView` opens with that conversation's title.
- [ ] Tap "← Back" on the nav bar → returns to the conversation list, scrolled to its previous position.
- [ ] Sign in fresh on an account with no conversations → the list shows the "no chats yet" empty state (not a blank list).

### Chat list actions

- [ ] Pull the conversation list down → spinner appears, list refreshes.
- [ ] Long-press a conversation row → context menu shows notification settings, Pin and Archive.
- [ ] Tap "Archive" → the row moves out of the list and into Archived.

### Sending

- [ ] Type a plain text message and send → appears in the timeline as "me" (right-aligned).
- [ ] Type `/` → slash palette appears. Type `/sta` → only `/start`, `/status` are shown.
- [ ] Tap a slash command → it pre-fills the composer **and the palette closes**.
- [ ] Tap send on a slash-prefilled message → message goes through; palette stays closed for the rest of the input cycle.
- [ ] Type only spaces → send button stays disabled.
- [ ] Tap 📎 → choose a photo → it sends as an image attachment.
- [ ] Tap 📎 → choose two photos of the same type back-to-back → both upload distinct files.
- [ ] Tap 📎 → choose a file → it sends as a file attachment.
- [ ] Send a local message → the timeline scrolls to the bottom **even before the server echo arrives**.

### Receiving + rendering

- [ ] The agent sends a markdown reply with a code block → renders with monospaced code; the inline Copy button writes to the system pasteboard.
- [ ] The agent sends an image → renders via `AttachmentImage` (bytes resolved via `MediaService`; the in-memory cache prevents re-fetch on scroll).
- [ ] The agent sends a file → renders as `AttachmentFile` with filename + size.
- [ ] A media download fails (simulate by killing network mid-fetch) → no infinite re-fetch loop in the network log.

### History

- [ ] Scroll to the top of the timeline → older messages page in.
- [ ] Long-press a text message → menu shows Copy / Share / **View source**.
- [ ] Tap "View source" → sheet opens with the event printed as pretty JSON; tap **Done** to dismiss.
- [ ] Long-press an image / file / state-change row → "View source" still appears (it's not text-only).

### Read state

- [ ] Open a conversation that has unread messages → the unread count clears.
- [ ] Open the same conversation a second time after one new message → the new message is marked read too (no off-by-one).

## Chat experience — Mac

### Chat navigation (Mac)

- [ ] Click a conversation row in the sidebar → detail column shows `MacChatView` with that conversation's title.
- [ ] With conversation A selected, send a message in another conversation (e.g. via iOS) → A stays selected on Mac.
- [ ] With no selection, the detail column shows the "Select a chat" placeholder.

### Chat list actions (Mac)

- [ ] Hover a conversation row → background tint appears; cursor stays default.
- [ ] Press `⌘R` (View → Refresh) → the list and the open conversation refresh; new messages flow in.
- [ ] No pull-to-refresh gesture (Mac has no touch gesture); refresh works only via `⌘R`.

### New chat creation (Mac)

- [ ] **File** → **New Chat** (`⌘N`) → `MacNewChatSheet` opens.

### Sending (Mac)

- [ ] Type a plain text message in the composer → send via `↩` → appears as "me" in the timeline.
- [ ] Type `/sta` → slash palette appears with `/start`, `/status`.
- [ ] Press `⇧⌘K` with empty composer → slash palette opens (pinned via `palettePinnedOpen`).
- [ ] Drag an image onto the composer → `ComposerDropDelegate` handles it → it sends as an image attachment.
- [ ] Drag a file (e.g. PDF) onto the composer → it sends as a file attachment.
- [ ] Send a local message → timeline scrolls to bottom before the server echo lands.

### Menu bar (Mac)

- [ ] **File** → **Sign Out…** → signs out and returns to the sign-in window.
- [ ] **Edit** → **Find in Chat** (`⌘F`) → opens the in-chat search bar.
- [ ] **Edit** → **Slash Command** (`⇧⌘K`) → opens the slash palette in the focused composer.
- [ ] **View** → **Toggle Sidebar** (`⌘⇧S`) → sidebar collapses / expands.
- [ ] **Go** → **Search…** (`⌘K`), **Go** → **Go to Number…** (`⌘J`), or the **Search** entry at the foot of the nav column → the Search page fills the main column with its field focused, and the Search entry is tinted. Type a word → after a short pause, sections appear in order: Conversations, Items, Missions, Projects, Memories, Messages; a loosely matched row carries a grey "similar words", "similar meaning" or "some words" tag. The chips narrow the page to one kind. Type a number (`412` or `#412`) → a **Go to** row comes first, saying what it is; press Return or click it → an item opens under For you, a mission or project on its page, a milestone on its mission's. A number nothing carries says "Nothing is numbered 412." and the page stays. Click any other row → it opens and the page steps aside; Search again shows the same text and results.
- [ ] iPhone: the tab bar reads Coordinator · For you · Conversations · More, with the round **Search** button beside it. More lists Projects and Settings (only Settings on a journal without projects); each opens in More's place with a back button to the list, and its stack is kept when you leave and come back. Type in its field → the same sections as on the Mac; tap a row → it opens on the Search tab's own stack (a memory opens under Projects) and Back returns to the results. A number and the keyboard's Search key opens it. The For you and Projects tabs no longer show a number button.

### Receiving + rendering (Mac)

- [ ] The agent sends markdown with a code block → `MarkdownText` + `CodeBlock` render correctly; the Copy button writes to `NSPasteboard`.
- [ ] The agent sends an image → `AttachmentImage` renders it.
- [ ] The agent sends a file → `AttachmentFile` shows filename + size.

### History (Mac)

- [ ] Scroll to the top of the timeline → older messages page in.
- [ ] Right-click a message → menu shows Copy / Share / **View source**.
- [ ] "View source" opens a sheet with the event printed as pretty JSON; click **Done** (or press Esc / ⏎) to dismiss.

### Read state (Mac)

- [ ] Click into a conversation with unread messages → the unread badge clears.

## Chat experience — cross-platform

- [ ] Sign in to the same account on iOS and macOS. Send a message from iOS → it appears on Mac within a few seconds.
- [ ] Send a message from Mac → appears on iOS within a few seconds.
- [ ] Send an image from iOS → renders correctly on Mac (and vice-versa).
- [ ] Archive a conversation on one platform → it leaves the list on the other within a few seconds.

## More conversation checks

### Cross-message selection + transcript copy — Mac

- [ ] Press inside message A's text and drag downward into message C: A highlights from the press point to its end, B fully, C from its start to the pointer; all three spans are the same colour.
- [ ] Release, press ⌘C, paste into TextEdit: three lines `[dd/mm/yyyy, hh:mm] Name: text`, first and last lines carry only the selected part; "Me" for own messages.
- [ ] Edit ▸ Copy is enabled after the drag and produces the same text.
- [ ] Right-click on a highlighted body: first item is "Copy 3 Messages" and produces the same text. Right-click on the bubble margin (outside the text) offers the same item.
- [ ] Drag upward (press in C, drag into A): mirrored spans, same copy.
- [ ] Drag out of A then back into A: the cross-message highlight clears and an ordinary within-A selection follows the pointer.
- [ ] Drag across a tool-call card / diff / image: the card shows no highlight and is absent from the copy; a captioned image copies as `[Photo] <caption part>`.
- [ ] Hold the pointer below the timeline's bottom edge mid-drag: the timeline scrolls and the selection keeps extending.
- [ ] A left-click anywhere clears the highlight; switching chats clears it; the previous chat's ⌘C no longer copies a transcript.
- [ ] Clicking a link in a message still opens it (single click, no drag). Double-click still selects a word; triple-click a paragraph; shift-click extends within a message.
- [ ] A message that is still streaming while inside the selection keeps its highlight after each delta.
- [ ] Sub-chat pane open beside the parent: a drag in one never highlights the other.
- [ ] Right-click on a highlighted body AND right-click on the bubble margin: in both menus "Copy N Messages" is enabled (not greyed out) and clicking it copies — a silent no-op here means the controller's left-click monitor cleared the selection before the item acted.
- [ ] Inside a message taller than the window, drag to the bottom edge of the viewport and hold: the message scrolls and the selection keeps growing within it (no cross-message escalation until the pointer actually leaves the message).
- [ ] Park the pointer below the viewport inside a very tall message: scrolling continues until the pointer moves; the selection then escalates normally on the next movement.
- [ ] A double-click on a word still selects the word even though the first click of the pair is handled by the takeover loop.
- [ ] Known change: dragging an existing text selection out of a message to another app no longer starts a drag (the takeover loop owns plain presses).

### Agent-chat rooms inside a participant's chat — Mac

- [ ] Open a chat that takes part in an agent-chat room: the header shows "Rooms · n". A chat in no room shows no such control. Both the session that started a room and the one invited into it show it.
- [ ] One room: clicking "Rooms · 1" opens the room in the side pane (the one subagent chats use), read-only; clicking it again closes the pane.
- [ ] Several rooms: "Rooms · n" is a menu listing every room, newest activity first; the open room is ticked, and picking it closes the pane.
- [ ] The pane's header shows the room's title and state, a switcher among this chat's rooms, and "Open this room as a chat", which selects the room in the sidebar (where it has a composer).
- [ ] Opening Tasks & decisions or a subagent closes the room pane, and opening a room closes those: one side pane at a time.
- [ ] Narrow window (under about 820 pt of detail): the room takes over the detail area with a back chevron.
- [ ] Back / Forward restores a room that was open beside a chat; switching to another chat never carries the room over.
- [ ] Reading a room in the pane clears its unread count in the sidebar.

### Agent-chat rooms inside a participant's chat — iOS

- [ ] A chat that takes part in a room shows a "Rooms · n" chip under the title, beside the mission chip when there is one.
- [ ] One room: the chip opens the room as a sheet, read-only. Several: the sheet opens on a list, and a row pushes that room inside the sheet.
- [ ] "Open this room as a chat" (top right in the sheet) closes the sheet and pushes the room's own chat.
- [ ] An item link or conversation link tapped in the room closes the sheet and opens its destination.
- [ ] A subtask card tapped in the room pushes that subagent inside the sheet; Back returns to the room.

## Latest briefing card (Projects)

> Needs a journal with Coordinator briefings (https://github.com/Matronhq/matron-journal/pull/131) and a Coordinator set. On an older journal, or with no Coordinator, the card must not show at all.

### Both platforms

- [ ] Projects shows a "Latest briefing · N minutes ago" card above the project cards, with a two-line plain-text preview: the heading on line 1, the first body line on line 2 (no `##`, list markers or `**`); the age moves on with the minute.
- [ ] Before any briefing exists the card reads "No briefing yet" with "Ask for one".
- [ ] The ↻ button (VoiceOver: "Ask the Coordinator for a new briefing") turns the footer into a spinner + "Refreshing…" and greys the button; a second device's card shows the same within a second or two (`briefing` frame).
- [ ] When the Coordinator publishes, the card updates on its own: new age, new preview, footer gone.
- [ ] A refresh nobody answers within 10 minutes turns into "The Coordinator hasn't answered." with "Try again" (no frame for a timeout — the card re-reads at `expires_at`).
- [ ] Right after an ask the button stays grey for about two minutes, then comes back by itself.
- [ ] Turn the network off and on: the card re-reads on reconnect.
- [ ] Clear the Coordinator in Settings: the card disappears after the next read (reconnect or reopening Projects).
- [ ] Tap/click the card: the full briefing opens with its date, rendered markdown, and "Open in chat".
- [ ] In the reader, a `matron://item/<n>` link opens that item, a `matron://project/<n>` or `matron://mission/<n>` link opens that page, and a conversation link opens that chat — each closes the reader first.
- [ ] "Open in chat" closes the reader and opens the Coordinator conversation scrolled to the briefing's own message.

### iOS

- [ ] The reader is a sheet with a "Latest briefing" title and Done; pull-to-refresh on Projects still works with the card on top.

### Mac

- [ ] The reader is a sheet with a "Latest briefing" title bar and Done (Return closes it); it resizes from 520×420.

## Markdown attachment preview

Send a few files from an agent with `send_attachment` (a `.md` file, one with `text/markdown` and no extension, a `.md` over 2 MB, a `.txt`), and attach a `.md` to a tracker item and to a comment.

- [ ] Tapping/clicking a `.md` chip in chat, in an item body and in a comment opens the preview instead of downloading; the `.txt` and the over-2 MB file download/open as before.
- [ ] The file renders with headings, lists, tables, code blocks and links at the item reading size; the header shows the file name.
- [ ] Source shows the raw text in monospace, selectable; toggling back shows the rendered file.
- [ ] Copy puts the raw markdown on the clipboard; Share offers the system share sheet with the file; Save writes a `.md` file.
- [ ] `![x](https://…)` and `![x](./img.png)` show as "x" — no network request for the image. http(s) and mailto links open outside the app; `./other.md` and `#anchor` links are plain text.
- [ ] With the network off, the preview shows "Couldn’t load this file." with Retry and Download; Retry works once the network is back.

### iOS

- [ ] The preview is a full-height sheet with a close button; Download in the error state opens today's file sheet.

### Mac

- [ ] The preview is a side panel on the right of the window; the chat (or item) beside it still scrolls, selects and accepts typing.
- [ ] Clicking another `.md` replaces the panel's content; Esc and the close button close it.

## Files: paste and the share sheet (iOS)

### Paste a copied file

- [ ] In Files, hold a zip and choose Copy. In a chat, tap the composer twice and choose Paste: the zip joins the tray as a chip showing its own name and size, and nothing is typed into the field.
- [ ] Repeat with a file from iCloud Drive and with a PDF. Send: the message shows the file under the same name.
- [ ] Paste a file over 50 MB: it is refused with a message naming the file.

### Share sheet

- [ ] In Files, hold a file and choose Share: Matron is in the row of apps. Choosing it opens "Send to Matron" with the file, a message field and the conversations, the Coordinator ticked.
- [ ] Pick another conversation, add a message, Send: a progress bar, then "Sent", and the sheet closes. The conversation shows the file with the message, as one message.
- [ ] Share two photos from Photos: both arrive in one message.
- [ ] The Coordinator is the first row, "New conversation" the second, then the rest by how recently they were used. Typing in the search hides "New conversation".
- [ ] Pick "New conversation" (with more than one box, a Box row appears, set to the box used most recently), add a message, Send: "Starting a new conversation…", then "Sent". The app shows a new conversation on that box holding the file and the message.
- [ ] The same with the box asleep: "Waking the box…" until it answers, then it sends.
- [ ] Share a page from Safari: the link is in the message field and sends as text.
- [ ] In flight mode the conversations still list. Send reports that the server could not be reached, and Send works once back online without the file uploading twice.
- [ ] Signed out of the app: the sheet says to sign in first.

## CarPlay (voice mode on a car's display)

Needs a build that carries the CarPlay entitlement: a Debug build in the
Simulator with its CarPlay display open, or a device build once the
entitlement is granted (README, "CarPlay"). Use a demo account.

### Launch
- [ ] Open Matron on the car's display. The voice-control screen shows, and within a second or two it says how many things need you and is listening ("Listening"), without a tap.
- [ ] With nothing needing you, it says so and listens on the conversation used last; the title names that conversation.
- [ ] Signed out on the iPhone: the display says "Sign in on iPhone" and has no Talk button.
- [ ] Start with the iPhone locked and the app not running: voice mode still starts and reads the queue.

### Nothing to read
- [ ] While the agent speaks, the display shows "Speaking" (or "<box> is speaking") and never the words. Check a reply, an item's title and a prompt's question: none appears on the display.
- [ ] An item with exactly two answers shows them as two buttons; pressing one sends it. An item with three or four answers shows Skip and Stop, and is answered by voice.

### Audio
- [ ] Play music in the car, then open Matron: the music stops while it listens or speaks, and comes back by itself while the agent works ("Working") and after Stop.
- [ ] Stop while it speaks: it goes quiet, the display shows "Ready" and a Talk button; Talk opens the microphone.
- [ ] Skip while it reads the queue: it moves on to the next thing.
- [ ] Say "cancel", or press Cancel, during "Sending: Go": nothing is sent.

### Conversations
- [ ] Chats opens a list of at most twelve conversations, each with its box and "Working" where it is. The microphone closes while the list shows.
- [ ] Choosing one returns to the voice screen, listening on that conversation; what you say next goes to it.
- [ ] Back from the list without choosing: the voice screen returns with the microphone closed and a Talk button.

### Leaving and coming back
- [ ] Switch to another CarPlay app mid-reply, then back: voice mode is listening again, and a reply that was cut off is said again.
- [ ] Unplug the car (or close the Simulator's CarPlay display) mid-sitting: the microphone closes and the iPhone's own voice-note button works again.
- [ ] While voice mode runs on the car, the iPhone offers no voice-mode button and a voice note cannot be started. While the iPhone is recording a voice note, the car says "In use on iPhone"; Talk works once the note is done.
- [ ] Sign out on the iPhone mid-sitting: the car stops and says "Sign in on iPhone".

### In a real car (not possible in the Simulator)
- [ ] Talking over the agent through the car's speakers and microphone interrupts it, and the agent's own voice does not.
- [ ] "Hey Siri, open Matron" opens it listening.

### Mac table timeline — Mac

Use a long conversation (thousands of events) unless an item says otherwise.

- [ ] Press in message A's text, drag down past the bottom edge and hold: the timeline autoscrolls, the selection keeps extending through rows that were never on screen, and all spans are the same colour. Release, right-click: "Copy N Messages" shows the right N (count the messages between A and the release point), and ⌘C pastes N `[dd/mm/yyyy, hh:mm] Name: text` lines, first and last trimmed to the selected part.
- [ ] Same drag upward past the top edge: the timeline scrolls up (loading older history if needed) and the copy is the mirrored transcript.
- [ ] Hover a fenced code block and click its copy button: the button turns into a checkmark for about a second, then reverts; the pasteboard holds only the code (no fence, no language tag). Scroll the row off screen and back mid-checkmark: no stale checkmark on a different block.
- [ ] Right-click a message that links a tracker item: "Open Item #N" opens the item. Right-click a message that links a conversation: "Open Conversation" opens it.
- [ ] Conversation-link pills under a bubble show the linked conversation's title (not a raw id) and open it on click.
- [ ] Scroll up to read history while a reply streams in at the bottom: the rows on screen don't move at all while the reply grows, and the jump button appears.
- [ ] Stay at the bottom while a reply streams: the growing tail stays pinned to the bottom, with no jitter or gap under the last line.
- [ ] Scroll up, click the jump button: lands at the very bottom, and a new message after that keeps it pinned.
- [ ] Scroll far up, then use the top-right jump-to-my-message pill (or ⇧⌘U): your last own message lands at the top of the viewport and flashes; the jump-to-bottom button then takes you back down.
- [ ] Send a message while scrolled up in history: the timeline jumps to your message at the bottom and stays pinned while the reply streams.
- [ ] Find in Chat (⌘F) → click a Message result, and the TOC → click an entry: the target row lands at the top of the viewport and flashes once. Repeat for a message far back in history (not loaded yet).
- [ ] While reading history (not at the bottom), resize the window narrower and wider, and drag the sub-chat / items split divider: the message at the top of the viewport stays at the top, no bubble is clipped or overlaps its neighbour, and text rewraps cleanly after the drag ends.
- [ ] Answer an ask-user card in the timeline: the card's row grows/shrinks to fit the answered state with no overlap or gap, and rows below move with it.
- [ ] Click an image in a hosted row (photo, pasted image): the image preview opens; ← / → step through the conversation's images.
- [ ] Scroll to the middle of a chat, open and close the sub-chat or items pane, then switch to another chat and back: each time the same message is at the top where you left it.
- [ ] Scroll to the bottom, start a long reply streaming, then flick the trackpad up hard and let go: the timeline coasts up and the reader stays exactly where the momentum left them while the reply grows (no snap back to the bottom); the jump button appears.
- [ ] Click into a message's text, then press Page Up, Home and space (and Page Down / End): the timeline pages through history, older messages load at the top as you reach it, and the jump button appears as soon as you leave the bottom; paging back down to the very bottom hides it again and the next reply stays pinned.
- [ ] Press in a message, drag up past the top edge and hold until that message has scrolled far off screen (its row is recycled), keep dragging, then release: the selection still starts at the original press point, no highlight lands on an unrelated row, and "Copy N Messages" copies the right range.
- [ ] Edit ▸ Copy with a cross-message selection: pastes the same `[dd/mm/yyyy, hh:mm] Name: text` transcript as ⌘C.
- [ ] Select part of one message with formatting (bold, a link, a list) and copy, then paste into TextEdit (rich text): the formatting comes across (RTF on the pasteboard alongside the plain text); pasting into a plain-text field gives the markdown.
- [ ] Select text wholly inside one fenced code block and copy: the pasteboard holds the bare code (no fence, no language tag, no surrounding prose).
- [ ] An agent-chat request card and an agent-spawn request card in the timeline: Approve / Decline work, the card updates to its resolved state and its row resizes with no overlap; a started spawn's "Open room" opens it.
- [ ] Item, milestone and mission cards/markers in the timeline: clicking each opens the tracker item pane, or the mission page, to the right entry.
- [ ] A subtask card in the timeline: clicking it opens the sub-chat pane on that sub-chat.
- [ ] Click a file attachment in a hosted row: the spinner shows while it downloads, then the file opens in its default app.
- [ ] Drag a file and an image from Finder over the timeline rows (not only the empty area) and drop: the drop overlay shows while hovering anywhere on the column, and both land as attachments in the composer.
- [ ] The chat header (title bar accessory), the top banners (usage, compact, offline) and the composer sit cleanly around the timeline: nothing shifts, overlaps or loses clicks.
- [ ] Settings ▸ Advanced has no "Chat timeline" switch.

## Voice note start (the first words are kept)

Needs a real device with a microphone; the simulator's synthetic mic is live at once.

- [ ] iPhone and Mac, with Bluetooth earbuds connected and with none: press the mic and start talking the moment the bar shows the red dot and the timer. Play the sent note back: the first word is there.
- [ ] With Bluetooth earbuds, the bar shows a grey dot and "Starting microphone…" for a moment first; the send arrow is grey and does nothing until the timer appears. Cancel in that state leaves nothing recorded.
- [ ] Mac hotkey: the start sound plays only when the timer appears, not when the key is pressed.
- [ ] The recording bar names the microphone under the timer. iPhone with AirPods connected: it still says the iPhone's microphone; pick AirPods from the menu mid-note and the rest of the note comes from AirPods (play it back). The pick is remembered for the next note; pick the iPhone microphone to go back.
- [ ] Mac with AirPods as the system input: the bar says AirPods while starting; pick the built-in microphone and the note starts over on it, nothing lost. The next note starts on the built-in microphone straight away. Pick another mic once the timer runs (AirPods to the built-in microphone, say): the bar names it at once, and the note switches to it without stopping. Keep talking through the switch, then play the sent note back: every word is there, the first part from the old mic and the rest from the new one. The next note starts on the new mic. "System default" goes back to following macOS.
- [ ] Mac: unplug a picked USB microphone, then start a note: it records from the system default instead.

## Notifications that say what they are about

Needs a real iPhone and a journal that seals notification content. The simulator does not run the notification extension for a simulated push, so the opening step cannot be checked there.

- [ ] Sign in, allow notifications, leave the app. Have an agent file a question for you: the notification shows the question's title, "Question" and the conversation's name under it, and the start of its text. Not "Your agent needs you".
- [ ] With Settings ▸ Notifications ▸ Show Previews set to "When Unlocked", lock the iPhone and have another item filed: the lock screen shows a notification from Matron with no text until the iPhone is unlocked.
- [ ] A question with buttons: hold the notification, the item's buttons are there with its labels. Tap one: the item shows that answer in the app and on another device, and the app did not open.
- [ ] A first question with a set of buttons never seen before on this iPhone shows them too (the extension registers them as it arrives).
- [ ] A notice: hold the notification, tap Seen: the notice closes.
- [ ] Tap an item's notification: the app opens on that item, not on its conversation.
- [ ] Two questions from one conversation: both notifications stay. A follow-up comment on one of them replaces that one's notification.
- [ ] Turn on airplane mode, tap a button on a notification: a notification comes back saying the answer was not confirmed; tapping it opens the item.
- [ ] Sign out and in again, then have an item filed: its notification still shows its text (the new session registered a new key).
- [ ] Settings ▸ Notifications in the app, Coordinator mode: "Coordinator finished a turn" is off; the Coordinator finishing a turn sends nothing, an item for you still does.
