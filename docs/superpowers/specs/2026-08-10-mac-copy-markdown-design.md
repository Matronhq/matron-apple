# Mac Copy-as-Markdown Design

**Date:** 2026-08-10
**Status:** Approved by Dan (chat, 2026-08-10)
**Platforms:** macOS only. iOS untouched.

## Problem

Selecting and copying text from a Mac chat message loses structure:

1. **Newlines**: `MarkdownAttributed` joins blocks with a single `\n` and
   supplies the visual paragraph gap via `paragraphSpacing`. Copied text
   therefore has no blank lines between paragraphs — pasted into a
   markdown-aware target, paragraphs merge into one.
2. **Markdown formatting**: by copy time all syntax is gone. Bold/italic are
   fonts, code blocks have no fences, links lose URLs (the URL lives only in
   the `.link` attribute), list items carry literal "• " markers.

The context-menu "Copy" (`MacChatView.swift:905`) already copies the raw
markdown body — but only for the whole message. Drag-selection and ⌘A+⌘C go
through `NSTextView`'s default copy, which yields the flattened rendered text.

## Approach (approved)

Reconstruct markdown at copy time from semantic annotations laid down at
build time. Rejected alternatives: newline-only fix (doesn't cover the
formatting half); source-location re-parse via swift-markdown (new
dependency, render-path rewrite — not justified).

### 1. Annotate at build time (`MarkdownAttributed`)

`build(from:)` already knows each run's semantics when it assembles the
string. Add one custom attribute key, applied per run:

- `MarkdownAttributed.semanticsKey` (`NSAttributedString.Key`, e.g.
  `"matron.markdown.semantics"`) → a `MarkdownRunSemantics` value (final
  class, since attribute values must be objects) carrying:
  - `block`: paragraph | header(level) | codeBlock | blockQuote |
    listItem(ordinal: Int?)
  - `blockIdentity`: an `Int` that increments at each block boundary
    (derived from the existing `previousIntent != intent` check), so the
    reconstructor can tell two adjacent list items apart even though their
    `BlockKind` is equal.
  - `inline`: bold / italic / code / strikethrough flags
  - `link`: `URL?`
- List markers ("• " / "N. ") and the inter-block "\n" get the same
  semantics as their block so every character in the string is annotated.

No visual change. Existing attributes untouched.

### 2. Reconstruct on copy (`MarkdownReconstruction`)

New file `MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift`
(macOS-gated), a pure function:

```swift
enum MarkdownReconstruction {
    /// Rebuild markdown for `range` of an annotated rendered string.
    static func markdown(from attributed: NSAttributedString, in range: NSRange) -> String
}
```

Rules, driven by the semantics attribute:

- **Block separation**: when `blockIdentity` changes, emit `\n\n` (one blank
  line) — except between two consecutive `listItem` blocks, which get a
  single `\n` (a blank line between markdown list items splits the list).
- **Code blocks**: wrap each contiguous `codeBlock` region in ```` ``` ````
  fences on their own lines. Interior newlines pass through verbatim.
- **Headers**: prefix `#` × level + space; header text otherwise plain (the
  bold font is presentation, not source).
- **Block quotes**: prefix each line with `> `.
- **List items**: rendered marker "• " → `- `; "N. " stays as-is. If the
  selection starts mid-item (marker not selected), do not synthesize one.
- **Inline styles**: wrap maximal same-styled runs with `**` (bold), `*`
  (italic), `` ` `` (inline code), `~~` (strikethrough). Nesting order:
  code innermost; bold+italic compose as `***text***`.
- **Links**: `[text](url)` from the `.link`/semantics URL. Matrix/mxc
  accent text (no `.link` attribute, but semantics carries the URL) is
  emitted the same way only when a URL is present; otherwise plain text.
- **Unannotated text** (parse-failure fallback path renders plain): passes
  through verbatim — the function degrades to identity.
- Partial selection inside a styled run wraps the fragment best-effort
  (accepted tradeoff).

### 3. Copy override (`SelectableMessageText`)

- `SelectableTextViewRepresentable` sets `textView.markdownSource = source`
  (new property on `MouseTrackingRescueTextView` or a small subclass in the
  same file, `MessageCopyTextView`, extending it — subclass preferred so the
  copy behavior stays with the message view, not every rescue text view).
- Override `copy(_ sender:)`:
  - If `selectedRange` covers the entire text storage → pasteboard string =
    the raw `markdownSource` verbatim (perfect fidelity).
  - Else → `MarkdownReconstruction.markdown(from:in:)`.
  - Declare `[.rtf, .string]`; write the markdown as `.string` and the
    selected attributed substring as RTF (`NSAttributedString`
    `rtf(from:documentAttributes:)`) so rich-text targets keep visual
    formatting.
- `copy(_:)` is the single seam: the Copy menu item, ⌘C, and the context
  menu all route through it for a non-editable text view. Cut is
  unavailable (not editable); drag-out of selected text is out of scope.

## Scope

- Applies to message bodies and image captions on Mac (all
  `SelectableMessageText` call sites in `MacTimelineItemView`).
- Terminal/live-output panes (`TerminalPane`), composer, and iOS are
  untouched.
- The existing context-menu "Copy" (whole raw body) is unchanged — it and
  the full-selection fast path now agree byte-for-byte.

## Testing

Unit tests in
`MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift`
(plain XCTest beside `MarkdownAttributedTests.swift`, macOS-gated), all
through the pure function, round-tripping `MarkdownAttributed` output:

1. Two paragraphs → copied text separated by a blank line.
2. Bold / italic / inline code / strikethrough → `**` / `*` / `` ` `` / `~~`.
3. Fenced code block → fences restored, interior newlines intact.
4. Unordered + ordered lists → `- ` / `1. ` items, single newlines between
   items, blank line before following paragraph.
5. Header → `#`-prefix restored.
6. Block quote → `> ` prefix restored.
7. Link → `[text](url)`.
8. Partial range mid-paragraph → plain fragment, no spurious syntax.
9. Full range of a message with all constructs ≈ re-parses to the same
   rendered string (annotate → reconstruct → annotate fixed point), since
   byte-identity with the original source is not guaranteed for
   reconstruction (the full-selection fast path covers byte-identity and is
   exercised via a direct unit test of the range check + source property).
10. Parse-failure fallback (unannotated string) → identity.

No snapshot tests needed (no visual change). Run scoped:
`swift test --filter MarkdownCopyTests` plus the existing
`MarkdownAttributedTests` for regressions.

## Risks

- The semantics attribute must never alter layout: it's an inert custom
  key, and `MarkdownAttributedTests` height/size tests guard regressions.
- `updateNSView`'s `isEqual(to:)` comparison now also compares the custom
  attribute — values are per-build fresh objects, so `isEqual` must be
  implemented on `MarkdownRunSemantics` (value equality) to keep the
  "unchanged content" short-circuit working during streaming re-emits.
