# Per-chat media & links browser — design

**Date:** 2026-08-13 · **Requested by:** Dan ("can we make it so that there is a
browser to view past media and links for each chat like in whatsapp")

## Goal

A per-conversation browser — WhatsApp's "Media, Links and Docs" — opened from
the chat toolbar on both platforms, with three tabs:

- **Media** — thumbnail grid of the chat's `image` attachments; tap opens the
  existing zoom/pan viewer.
- **Files** — list of the chat's `file` attachments; tap opens/shares through
  the existing download path.
- **Links** — every http(s) URL that appeared in the chat's text messages,
  from **any sender, user messages included** (Dan's call, 2026-08-13),
  deduplicated, newest first; tap opens the default browser.

Strictly per-conversation: a parent chat does not pool its sub-chats' media.
Everything reads from the local store — works offline, no journal or bridge
changes.

## Non-goals (v1)

- No cross-chat/global media search.
- No deletion or quota management from the browser.
- No sub-chat toolbar entry (sub-chats are still browsable once opened as
  chats in their own right on Mac; iOS entry is parent-chat toolbar only).
- No thumbnail pre-generation server-side — grids load full blobs through the
  existing media cache, downscaled client-side.

## Why not the timeline?

`ChatViewModel.items` is a 120-row *window* (the blank-chat fix, PR history
2026-07-27) — it cannot see a chat's older attachments. The browser therefore
queries the full local event history in `JournalStore` (GRDB `event` table,
every event since pairing, including everything the 120-row window scrolled
past).

## Data layer (`MatronShared/Sources/Journal/JournalStore.swift`)

Two new read-only queries, both `ORDER BY seq DESC` on the existing
`idx` for `(convo_id, seq)`:

```swift
/// `image`/`file` events for one conversation, newest first.
public func attachmentEvents(convoID: String) throws -> [JournalEvent]
// WHERE convo_id = ? AND type IN ('image','file')

/// `text` events that plausibly contain a URL, newest first — cheap SQL
/// prefilter (`payload LIKE '%http%'`); precise extraction happens in Swift.
public func linkCandidateEvents(convoID: String) throws -> [JournalEvent]
```

The payload contract is the one `JournalTimelineMapper` already parses:
`blob_ref` → `serverURL/media/<ref>`, `name`, `size`, `caption`; tombstoned
attachments (journal reaper, PR matron-journal#63) carry `expired: true` and a
null `blob_ref`.

## Extraction & model (`MatronShared/Sources/ViewModels/MediaBrowserViewModel.swift`)

`@MainActor @Observable final class MediaBrowserViewModel`, created per sheet
presentation with `(store, convoID, serverURL, mediaService)`:

- `load()` runs the two store queries off the main actor, then maps:
  - `mediaItems: [MediaEntry]` — `id` (seq), `url`, `caption`, `expired`.
  - `fileItems: [FileEntry]` — `id`, `url`, `name`, `sizeBytes`, `caption`,
    `expired`.
  - `links: [LinkEntry]` — `id` (URL string), `url`, `firstLine` of the
    containing message for context, `timestamp`.
- Link extraction uses `NSDataDetector(.link)` per candidate body (handles
  trailing punctuation, markdown, angle brackets), filtered to `http`/`https`
  schemes, deduplicated by `absoluteString` keeping the **newest** occurrence.
  Agent chats are URL-dense; dedup + newest-first is the noise control.
- Thumbnails ride the same fetch the timeline uses (`MediaService`), with the
  browser VM holding its own small LRU of downscaled images (target ~200 pt
  cell, `CGImageSourceCreateThumbnailAtIndex`) so a 12 MB original doesn't
  live once per grid cell.

## UI (`MatronShared/Sources/DesignSystem` + platform wrappers)

Shared `MediaBrowserView` (MatronShared) with a segmented `Picker` for
Media / Files / Links:

- **Media**: `LazyVGrid` (adaptive ~110 pt cells), async thumbnail per cell
  with a placeholder; expired items render a dimmed slash-photo glyph.
- **Files**: rows reuse `AttachmentFile` (spinner/"Downloading…" state from
  apps PR #138 composes here for free once merged; expired rows render the
  "Expired" treatment from the reaper follow-up).
- **Links**: rows of URL + message-context line + relative date.
- Empty states per tab ("No media yet" etc.).

Platform wiring, mirroring existing sheets:

- **Mac** (`MacChatView` / `MacChatToolbar`): a `photo.on.rectangle.angled`
  toolbar button → `.sheet` (rigid frame, per the Mac sheet sizing rule).
  Media tap feeds the existing `ImagePreview` sheet path; file tap uses
  `ChatViewModel.writeTempFile` → `NSWorkspace.open`.
- **iOS** (`ChatView`): its own top-bar-trailing button (the only existing
  trailing `Menu` is the Subagents switcher — wrong home for this) →
  `.sheet`. That makes at most three trailing items (subagents · media ·
  info); iOS 26 truncates leading *text*, never trailing buttons (probe,
  2026-08-09). Media tap presents the pinch-zoom previewer; file tap routes
  through `onPreview(.file(...))` (Share sheet, as today); links via
  `openURL`.

Tab state, selection, and dismissal are local `@State`; nothing persists.

## Error handling

- Store read failure → sheet shows a plain "Couldn't load" state (no crash,
  no partial tabs).
- Blob fetch failure / 404 (reaped server-side before the tombstone syncs) →
  the cell/row falls back to the expired treatment after the failed fetch,
  same channel the timeline uses.

## Testing

- `JournalStore` query tests: type filtering, ordering, convo isolation
  (sub-chat events excluded), LIKE prefilter recall.
- Link extraction tests: bare URLs, markdown, trailing punctuation, non-http
  schemes rejected, dedup keeps newest, multi-URL messages.
- `MediaBrowserViewModel` tests with fake store/media service, including
  expired tombstones.
- Snapshot tests: three tabs × populated/empty, standard `assertVariants`
  matrix (recorded once, determinism re-run; `MATRON_SKIP_SNAPSHOT_TESTS`
  honored).
- Both scheme builds + full SPM suite; MatronMacTests scoped with
  `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE`.

## Rollout

Single PR on `feat/media-links-browser` (worktree
`~/Dev/matron-apple-media-browser`), standard bot triage, Dan admin-merges,
Release installs on both platforms.
