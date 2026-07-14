# Rich diff cards for file edits

**Date:** 2026-07-14
**Branches:** apps `feat/diff-cards` (stacked on `feat/tool-stream-overlay`, PR #21);
bridge change lands separately in claude-matrix-bridge.
**Decided with Dan:** journal-only (option A); the plain Matrix "✏️ Editing"
indicator is removed entirely (no room message, no journal text mirror) —
part of the ongoing move off Matrix. Subagent edits included, label shown in
the header. Snippet-first presentation (option A): ~12 lines collapsed,
expandable.

## Goal

When the agent edits or writes a file, viewing clients today get a plain
chat message (`✏️ Editing [path](viewer-link)`), mirrored into the journal
as a `text` event. Replace that with a structured journal `diff` event
rendered by the apps as a rich diff card: filename header linking to the
signed viewer URL, green/red colored diff lines, snippet-collapsed.

The journal server already whitelists the `diff` event type (journal.js /
ws.js / push.js); nothing publishes it yet. This spec defines the payload
and both producing (bridge) and consuming (apps) sides.

## Bridge (claude-matrix-bridge)

### 1. `lib/edit-diff.js` — diff computation

New module, unit-tested. Adds the `diff` npm package (jsdiff) as a
dependency. Exported function:

```js
// returns { diff, added, removed, truncated, newFile } or null when the
// tool input has no usable content (defensive; callers skip publishing).
async function computeEditDiff(toolName, input, workdir)
```

- `Edit` → `structuredPatch` of `old_string` → `new_string` (line diff).
  `replace_all` still diffs one occurrence — the payload is a snippet of
  intent, not a byte-accurate file delta.
- `Write` → read the file's current on-disk content at tool_use time
  (`fs.promises.readFile`, fail-open to "new file" on ENOENT or any read
  error); diff old content → `input.content`. Absent file → `newFile: true`
  and an all-additions diff of the content.
- `MultiEdit` → one hunk per entry of `input.edits`, concatenated in order.
- Rendered as unified-diff text: `@@` hunk headers, `+`/`-`/space-prefixed
  lines. No `---`/`+++` file header lines — the card header carries the
  filename.
- Caps: 400 diff lines or 64 KB, whichever hits first; `truncated: true`
  and the text ends at a whole line. `added`/`removed` counts are computed
  BEFORE truncation (the header stays honest).
- Binary/oversized inputs: tool inputs are strings by contract; a Write of
  a huge file is handled by the cap.

### 2. Journal `diff` payload (defined here, server passes through)

```json
{
  "type": "diff",
  "file_path": "/abs/path/to/file.swift",
  "display_path": "Matron/App/File.swift",
  "viewer_url": "https://…/view?token=…",
  "tool": "Edit",
  "label": null,
  "diff": "@@ -10,3 +10,4 @@\n-old\n+new\n+added\n context",
  "added": 12,
  "removed": 3,
  "truncated": false,
  "new_file": false
}
```

- `display_path`: the path as given in the tool input (usually relative or
  absolute as typed); apps show its last component in the header and may
  show the full string on expand.
- `viewer_url`: `generateFileLink(absPath)` — existing HMAC-signed viewer
  link; `null` when `HMAC_SECRET`/`VIEWER_BASE_URL` are unconfigured.
  Links expire (`LINK_EXPIRY_MS`); an expired link opens the viewer's
  error page — accepted, no client-side handling.
- `label`: subagent label string, `null` for main-agent edits.
- `sender`: published as `from: 'assistant'` like other agent events.

New `publishDiff(convoId, payload)` on the journal publisher, following the
`publishText` shape (fails open, buffers like other agent ops).

### 3. Indicator suppression

- **Main agent** (`index.js` tool_use handler, `Write`/`Edit` branches):
  compute the diff, `publishDiff`, and post **nothing** to Matrix — the
  branches stop setting `isKeyEvent`, so no `sendHtml`/`sendCallback` and
  therefore no journal `text` mirror. `session.toolCalls` still gets the
  plain one-line indicator for logging/summary parity.
- **Subagents** (`formatSubagentToolIndicator` Edit/Write/MultiEdit
  branch): the caller publishes the diff with `label` set and skips the
  Matrix message for these tools. Other subagent indicators are untouched.
- publishDiff is async (Write reads the file); fire-and-forget with a
  caught rejection — journal problems must never touch the Matrix hot
  path (same rule as every other journal call).
- Timing semantics unchanged from today: published at tool_use time, so a
  denied edit still shows its card — identical to the current message
  behavior. Accepted.

## Apps (matron-apple)

### 4. `DiffEvent` (MatronEvents) + mapper

```swift
public struct DiffEvent: Equatable, Sendable {
    public let filePath: String?
    public let displayPath: String?
    public let viewerURL: URL?
    public let tool: String?
    public let label: String?        // subagent label
    public let diff: String
    public let added: Int?
    public let removed: Int?
    public let truncated: Bool
    public let newFile: Bool
}
```

`TimelineItem.Kind` gains `case diff(eventID: String, DiffEvent)` (plus the
`kindAsJSON()` case). `JournalTimelineMapper`'s `JournalEventType.diff`
branch maps the new payload into `DiffEvent`. The current bare shape
(`{diff: "…"}` string only, today rendered as a "diff" ToolCallCard) maps
into the SAME `DiffEvent` with nil metadata — one render path, no legacy
card. Missing/empty `diff` string → keep the empty string; the card renders
header-only.

### 5. `DiffCard` (DesignSystem)

New `MatronShared/Sources/DesignSystem/DiffCard.swift`, chrome matching
`ToolCallCard` (matronCodeBg surface, rounded 8, chevron expand/collapse,
Mac hover hint + pointing-hand cursor via the same push/pop pattern).

Header row: chevron · doc icon · **filename** (last path component of
`display_path` ?? `file_path`, bold) · optional dimmed `label` · optional
"new file" caption badge · `+12 −3` counts (green/red, hidden when nil) ·
truncated marker ("…") when `truncated`.

- Filename is tappable when `viewerURL != nil`: opens in the default
  browser via SwiftUI `Link` styling (`@Environment(\.openURL)`), separate
  hit target from the expand chevron. Plain text when nil.
- Body: `diff` split into lines, each rendered monospaced caption with
  prefix coloring — `+` green, `-` red, `@@` secondary/dimmed, others
  primary. Horizontal ScrollView like ToolCallCard's codeView.
- Collapsed (default): first 12 lines, then a dimmed "+N more lines" row
  when more exist. Expanded: all lines (bridge already capped at 400).
  When `truncated`, the last row reads "… diff truncated".
- Accessibility label: "Edited <filename>, 12 additions, 3 removals".

### 6. Rendering + tests

- `TimelineItemView` (iOS) and `MacTimelineItemView` (Mac): new `.diff`
  case, bot-aligned HStack, width caps 480 / 560 (same as tool cards),
  combined accessibility element.
- **Bridge tests** (`test/edit-diff.test.js`): Edit line-diff correctness,
  Write vs existing file, Write new-file, MultiEdit multi-hunk, caps +
  truncated flag, count-before-truncation.
- **App tests:** mapper tests (rich payload → DiffEvent, bare legacy
  payload → DiffEvent with nils, empty diff), DiffEvent equability,
  snapshot tests: collapsed, expanded, new-file badge, truncated,
  subagent-labeled, no-viewer-URL (plain header).
- Full SPM suite + both app targets build.

## Out of scope (explicitly deferred)

- Full Matrix retirement (own future spec; this only removes the
  edit/write indicator).
- Post-hoc correction of denied-edit cards.
- Syntax highlighting inside diff lines.
- Read/Glob/Grep indicators (unchanged).
- matron-web rendering of `diff` events.
