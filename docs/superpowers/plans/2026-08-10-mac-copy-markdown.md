# Mac Copy-as-Markdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Copying a selection from a Mac chat message yields markdown (blank lines between paragraphs, fences, `**`/`*`/`` ` ``, links) as plain text plus the rendered rich text as RTF; selecting the whole message copies the raw source verbatim.

**Architecture:** `MarkdownAttributed.build` annotates every run of the rendered `NSAttributedString` with an inert custom attribute (`MarkdownRunSemantics`: block kind + block identity + inline flags + link). A pure function `MarkdownReconstruction.markdown(from:in:)` rebuilds markdown from those annotations for any character range. A small `NSTextView` subclass used by `SelectableMessageText` overrides `copy(_:)` to write reconstructed markdown (or, for a full selection, the original source) as the plain-text pasteboard flavor alongside the RTF of the rendered selection.

**Tech Stack:** Swift, AppKit (macOS-gated code in the `MatronDesignSystem` SPM target), XCTest.

## Global Constraints

- macOS only; iOS untouched. All new code inside `#if os(macOS)`.
- The semantics attribute must never change layout or rendered appearance; existing `MarkdownAttributedTests` (including size tests) must keep passing.
- `MarkdownRunSemantics` must implement value equality (`isEqual`/`hash`) — `SelectableMessageText.updateNSView` short-circuits on `textStorage.isEqual(to:)` during streaming re-emits and per-build fresh objects would otherwise defeat it.
- New API stays `internal` to `MatronDesignSystem` (tests use `@testable`).
- Tests live in `MatronShared/Tests/DesignSystemSnapshotTests/` beside `MarkdownAttributedTests.swift`; run from `MatronShared/` with `swift test --filter <Class>`. Do NOT run the MatronMac Xcode test scheme (and never without `MATRON_APP_SUPPORT_OVERRIDE`).
- Commit after each task, message style `feat(mac): …` / `test(mac): …`.

## File Structure

- `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift` — gains `MarkdownRunSemantics`, `MarkdownInlineFlags`, the `semanticsKey`, annotation in `build`, `BlockKind` becomes `internal`, `Hashable`, and carries the code-fence language hint.
- `MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift` (new) — pure range → markdown reconstruction.
- `MatronShared/Sources/DesignSystem/SelectableMessageText.swift` — `MessageCopyTextView` subclass + source wiring.
- `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift` (new) — all new tests.

---

### Task 1: Semantic annotations in `MarkdownAttributed`

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift` (new)

**Interfaces:**
- Produces (used by Tasks 2–3):
  - `MarkdownAttributed.semanticsKey: NSAttributedString.Key`
  - `final class MarkdownRunSemantics: NSObject { let block: BlockKind; let blockIdentity: Int; let inline: MarkdownInlineFlags; let link: URL? }`
  - `struct MarkdownInlineFlags: OptionSet, Hashable` with `.bold, .italic, .code, .strikethrough`
  - `enum BlockKind: Hashable` (now `internal`; `codeBlock` case becomes `codeBlock(language: String?)`)

- [ ] **Step 1: Write the failing tests**

Create `MarkdownCopyTests.swift`:

```swift
#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Tests for the copy-time markdown pipeline: run annotation
/// (`MarkdownRunSemantics`), reconstruction (`MarkdownReconstruction`), and
/// the pasteboard override (`MessageCopyTextView`).
final class MarkdownCopyTests: XCTestCase {

    private func convert(_ source: String) -> NSAttributedString {
        MarkdownAttributed.attributedString(for: source)
    }

    private func semantics(
        of attributed: NSAttributedString,
        atFirst substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MarkdownRunSemantics? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("substring \(substring.debugDescription) not found in \(attributed.string.debugDescription)", file: file, line: line)
            return nil
        }
        return attributed.attribute(
            MarkdownAttributed.semanticsKey, at: range.location, effectiveRange: nil
        ) as? MarkdownRunSemantics
    }

    // MARK: - Annotation

    func test_annotation_paragraphAndBoldFlags() {
        let attributed = convert("plain **bold** text")
        let plain = semantics(of: attributed, atFirst: "plain")
        let bold = semantics(of: attributed, atFirst: "bold")
        XCTAssertEqual(plain?.block, .paragraph)
        XCTAssertEqual(plain?.inline, [])
        XCTAssertEqual(bold?.inline, .bold)
        XCTAssertEqual(plain?.blockIdentity, bold?.blockIdentity)
    }

    func test_annotation_blockIdentityIncrementsPerBlock() {
        let attributed = convert("First.\n\nSecond.")
        let first = semantics(of: attributed, atFirst: "First")
        let second = semantics(of: attributed, atFirst: "Second")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.blockIdentity, second?.blockIdentity)
    }

    func test_annotation_codeBlockCarriesLanguage() {
        let attributed = convert("```swift\nlet x = 1\n```")
        let code = semantics(of: attributed, atFirst: "let x")
        XCTAssertEqual(code?.block, .codeBlock(language: "swift"))
    }

    func test_annotation_linkCarriesURL() {
        let attributed = convert("see [docs](https://example.com)")
        let link = semantics(of: attributed, atFirst: "docs")
        XCTAssertEqual(link?.link, URL(string: "https://example.com"))
    }

    func test_annotation_everyCharacterAnnotated() {
        let attributed = convert("# H\n\npara `code`\n\n- item\n\n> quote")
        var uncovered = 0
        attributed.enumerateAttribute(
            MarkdownAttributed.semanticsKey,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value == nil { uncovered += 1 }
        }
        XCTAssertEqual(uncovered, 0)
    }

    /// `updateNSView` short-circuits on `isEqual(to:)`; semantics must
    /// compare by VALUE — the conversion cache can be evicted between a
    /// build and a streaming re-emit, yielding fresh objects for identical
    /// content. (Comparing two `convert` results would pass trivially via
    /// the cache's pointer equality, so construct directly.)
    func test_semantics_valueEqualityAndHash() {
        let a = MarkdownRunSemantics(
            block: .listItem(ordinal: 2), blockIdentity: 3,
            inline: [.bold], link: URL(string: "https://e.com")
        )
        let b = MarkdownRunSemantics(
            block: .listItem(ordinal: 2), blockIdentity: 3,
            inline: [.bold], link: URL(string: "https://e.com")
        )
        let c = MarkdownRunSemantics(
            block: .paragraph, blockIdentity: 3, inline: [.bold], link: nil
        )
        XCTAssertTrue(a.isEqual(b))
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertFalse(a.isEqual(c))
        XCTAssertFalse(a.isEqual("not semantics"))
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `semanticsKey`, `MarkdownRunSemantics` undefined.

- [ ] **Step 3: Implement the annotation**

In `MarkdownAttributed.swift`:

3a. Change `private enum BlockKind` → `enum BlockKind: Hashable` and give the code-block case its language: `case codeBlock(language: String?)`. In `init`, change `case .codeBlock:` → `case .codeBlock(let languageHint): self = .codeBlock(language: languageHint); return`. All other `case .codeBlock` matches/`isCodeBlock` checks (`if case .codeBlock = self`) keep compiling unchanged; verify `paragraphStyle`'s `switch` still matches with `case .codeBlock:`.

3b. Add below the `BlockKind` definition:

```swift
/// Inline-style flags for one rendered run, mirrored from
/// `InlinePresentationIntent` at build time for copy-time reconstruction.
struct MarkdownInlineFlags: OptionSet, Hashable {
    let rawValue: Int
    static let bold = MarkdownInlineFlags(rawValue: 1 << 0)
    static let italic = MarkdownInlineFlags(rawValue: 1 << 1)
    static let code = MarkdownInlineFlags(rawValue: 1 << 2)
    static let strikethrough = MarkdownInlineFlags(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ intent: InlinePresentationIntent) {
        var flags: MarkdownInlineFlags = []
        if intent.contains(.stronglyEmphasized) { flags.insert(.bold) }
        if intent.contains(.emphasized) { flags.insert(.italic) }
        if intent.contains(.code) { flags.insert(.code) }
        if intent.contains(.strikethrough) { flags.insert(.strikethrough) }
        self = flags
    }
}

/// Inert semantic annotation applied to every run of the rendered string so
/// `MarkdownReconstruction` can rebuild markdown from a selection. Never
/// carries visual attributes — layout must be identical with or without it.
/// Value equality (`isEqual`/`hash`) is load-bearing: `SelectableMessageText`
/// skips storage updates when the rebuilt string `isEqual(to:)` the current
/// one, and each build creates fresh semantics objects.
final class MarkdownRunSemantics: NSObject {
    let block: BlockKind
    /// Increments at each block boundary so two adjacent blocks of the same
    /// kind (consecutive list items) stay distinguishable.
    let blockIdentity: Int
    let inline: MarkdownInlineFlags
    let link: URL?

    init(block: BlockKind, blockIdentity: Int, inline: MarkdownInlineFlags, link: URL?) {
        self.block = block
        self.blockIdentity = blockIdentity
        self.inline = inline
        self.link = link
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownRunSemantics else { return false }
        return block == other.block
            && blockIdentity == other.blockIdentity
            && inline == other.inline
            && link == other.link
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(block)
        hasher.combine(blockIdentity)
        hasher.combine(inline)
        hasher.combine(link)
        return hasher.finalize()
    }
}
```

3c. Add the key on `MarkdownAttributed`:

```swift
/// Custom attribute carrying `MarkdownRunSemantics` for copy-time
/// reconstruction. Inert for layout.
static let semanticsKey = NSAttributedString.Key("matron.markdown.semantics")
```

3d. In `build(from:)`, thread the annotation through. Add loop state next to `isFirstBlock`:

```swift
var blockIdentity = 0
var previousSemantics: MarkdownRunSemantics?
```

Replace the block-boundary separator append (the `output.append(NSAttributedString(string: "\n"))` inside the `previousIntent != nil, intent != previousIntent` branch) with:

```swift
if !output.string.hasSuffix("\n") {
    var separatorAttrs: [NSAttributedString.Key: Any] = [:]
    if let previousSemantics {
        // The separator belongs to the block it terminates, so
        // reconstruction sees the identity change exactly at the
        // next block's first character.
        separatorAttrs[Self.semanticsKey] = previousSemantics
    }
    output.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
}
blockIdentity += 1
isFirstBlock = false
```

After `previousIntent = intent`, build the run's semantics once (markers share it minus inline flags):

```swift
let semantics = MarkdownRunSemantics(
    block: block,
    blockIdentity: blockIdentity,
    inline: MarkdownInlineFlags(run.inlinePresentationIntent ?? []),
    link: run.link
)
previousSemantics = semantics
```

(Move the `if intent != previousIntent, let marker = block.marker` marker-append ABOVE `previousIntent = intent` as it is today — only the semantics construction goes after; the marker append changes to attach a marker-flavored semantics:)

```swift
if intent != previousIntent, let marker = block.marker {
    var markerAttrs = runAttributes(block: block, inline: [], link: nil, isFirstBlock: isFirstBlock)
    markerAttrs[Self.semanticsKey] = MarkdownRunSemantics(
        block: block, blockIdentity: blockIdentity, inline: [], link: nil
    )
    output.append(NSAttributedString(string: marker, attributes: markerAttrs))
}
```

Careful with ordering: the boundary branch (`previousIntent != nil, intent != previousIntent`) runs first and bumps `blockIdentity`; the marker branch keeps its existing `intent != previousIntent` condition and position; `previousIntent = intent` stays where it is; semantics construction goes right after it.

And the text append gains the attribute:

```swift
var attrs = runAttributes(
    block: block,
    inline: run.inlinePresentationIntent ?? [],
    link: run.link,
    isFirstBlock: isFirstBlock
)
attrs[Self.semanticsKey] = semantics
output.append(NSAttributedString(string: text, attributes: attrs))
```

The parse-failure fallback path stays unannotated (reconstruction passes it through verbatim). The trailing-newline trim loop is unchanged.

- [ ] **Step 4: Run the new tests and the existing regression suite**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -5 && swift test --filter MarkdownAttributedTests 2>&1 | tail -5`
Expected: both PASS ("Executed N tests, with 0 failures" — assert the count line exists, a destination/toolchain error can masquerade as a pass).

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown
git add MatronShared/Sources/DesignSystem/MarkdownAttributed.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift
git commit -m "feat(mac): annotate rendered markdown runs with copy semantics"
```

---

### Task 2: `MarkdownReconstruction` — range → markdown

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift`

**Interfaces:**
- Consumes: `MarkdownAttributed.semanticsKey`, `MarkdownRunSemantics`, `MarkdownInlineFlags`, `BlockKind` (Task 1).
- Produces (used by Task 3): `enum MarkdownReconstruction { static func markdown(from attributed: NSAttributedString, in range: NSRange) -> String }`

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownCopyTests.swift`:

```swift
    // MARK: - Reconstruction

    private func reconstruct(_ source: String) -> String {
        let attributed = convert(source)
        return MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: 0, length: attributed.length)
        )
    }

    func test_reconstruct_paragraphsSeparatedByBlankLine() {
        XCTAssertEqual(reconstruct("First one.\n\nSecond one."), "First one.\n\nSecond one.")
    }

    func test_reconstruct_inlineStyles() {
        XCTAssertEqual(
            reconstruct("a **bold** b *ital* c `code` d ~~gone~~"),
            "a **bold** b *ital* c `code` d ~~gone~~"
        )
    }

    func test_reconstruct_nestedBoldItalic_noBrokenDelimiters() {
        let out = reconstruct("**bold *both* bold**")
        XCTAssertFalse(out.contains("****"))
        XCTAssertEqual(out, "**bold *both* bold**")
    }

    func test_reconstruct_codeBlockFencesAndNewlines() {
        XCTAssertEqual(
            reconstruct("```swift\nlet a = 1\nlet b = 2\n```"),
            "```swift\nlet a = 1\nlet b = 2\n```"
        )
    }

    func test_reconstruct_codeBlockBetweenParagraphs() {
        XCTAssertEqual(
            reconstruct("Before.\n\n```\nx\n```\n\nAfter."),
            "Before.\n\n```\nx\n```\n\nAfter."
        )
    }

    func test_reconstruct_unorderedList() {
        XCTAssertEqual(
            reconstruct("- one\n- two\n\nAfter."),
            "- one\n- two\n\nAfter."
        )
    }

    func test_reconstruct_orderedList() {
        XCTAssertEqual(reconstruct("1. one\n2. two"), "1. one\n2. two")
    }

    func test_reconstruct_header() {
        XCTAssertEqual(reconstruct("## Title\n\nBody."), "## Title\n\nBody.")
    }

    func test_reconstruct_blockQuote() {
        XCTAssertEqual(reconstruct("> quoted line"), "> quoted line")
    }

    func test_reconstruct_link() {
        XCTAssertEqual(
            reconstruct("see [docs](https://example.com) now"),
            "see [docs](https://example.com) now"
        )
    }

    func test_reconstruct_partialRangeMidParagraph_plainFragment() {
        let attributed = convert("hello plain world")
        let range = (attributed.string as NSString).range(of: "plain")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "plain"
        )
    }

    func test_reconstruct_partialRange_listItemWithoutMarker_noSynthesizedMarker() {
        let attributed = convert("- alpha bravo")
        let range = (attributed.string as NSString).range(of: "bravo")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "bravo"
        )
    }

    func test_reconstruct_unannotatedString_identity() {
        let plain = NSAttributedString(string: "raw\ntext, untouched")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(
                from: plain, in: NSRange(location: 0, length: plain.length)
            ),
            "raw\ntext, untouched"
        )
    }

    /// Fixed-point: reconstructing the full range and re-rendering yields the
    /// same rendered string (byte-identity with the source is the fast path's
    /// job, not reconstruction's).
    func test_reconstruct_fullMessage_fixedPoint() {
        let source = "# H\n\npara **bold** and [l](https://e.com)\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n> bye"
        let rendered = convert(source)
        let rebuilt = MarkdownReconstruction.markdown(
            from: rendered, in: NSRange(location: 0, length: rendered.length)
        )
        XCTAssertEqual(convert(rebuilt).string, rendered.string)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -10`
Expected: COMPILE FAILURE — `MarkdownReconstruction` undefined.

- [ ] **Step 3: Implement**

Create `MarkdownReconstruction.swift`:

```swift
#if os(macOS)
import AppKit

/// Rebuilds markdown source from a range of a `MarkdownAttributed`-rendered
/// string, driven by the `MarkdownRunSemantics` annotations laid down at build
/// time. Pure and deterministic: (attributed string, range) → markdown.
///
/// Best-effort by design: a partial selection inside a styled run wraps the
/// fragment; nesting/indentation flattened by rendering stays flat. The
/// full-selection case is handled upstream by `MessageCopyTextView`, which
/// copies the original source verbatim instead of calling this.
enum MarkdownReconstruction {

    static func markdown(from attributed: NSAttributedString, in range: NSRange) -> String {
        var blocks: [Block] = []

        attributed.enumerateAttribute(MarkdownAttributed.semanticsKey, in: range) { value, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
            guard let semantics = value as? MarkdownRunSemantics else {
                // Unannotated text (parse-failure fallback) passes through
                // verbatim as its own pseudo-block.
                if blocks.last?.identity == Block.verbatimIdentity {
                    blocks[blocks.count - 1].segments.append(Segment(text: text, inline: [], link: nil))
                } else {
                    blocks.append(Block(
                        kind: .paragraph,
                        identity: Block.verbatimIdentity,
                        segments: [Segment(text: text, inline: [], link: nil)]
                    ))
                }
                return
            }
            let segment = Segment(text: text, inline: semantics.inline, link: semantics.link)
            if blocks.last?.identity == semantics.blockIdentity {
                blocks[blocks.count - 1].segments.append(segment)
            } else {
                blocks.append(Block(kind: semantics.block, identity: semantics.blockIdentity, segments: [segment]))
            }
        }

        var output = ""
        var previousKind: BlockKind?
        for block in blocks {
            if previousKind != nil {
                output += separator(from: previousKind, to: block.kind)
            }
            output += render(block)
            previousKind = block.kind
        }
        return output
    }

    // MARK: - Model

    private struct Segment {
        let text: String
        let inline: MarkdownInlineFlags
        let link: URL?
    }

    private struct Block {
        /// Identity for coalescing unannotated pass-through text.
        static let verbatimIdentity = Int.min
        let kind: BlockKind
        let identity: Int
        var segments: [Segment]
    }

    // MARK: - Block rendering

    /// Consecutive list items are separated by a single newline (a blank line
    /// would split the markdown list); everything else gets a blank line.
    /// Verbatim pass-through blocks keep whatever newlines they carried.
    private static func separator(from previous: BlockKind?, to next: BlockKind) -> String {
        if case .listItem = previous, case .listItem = next { return "\n" }
        return "\n\n"
    }

    private static func render(_ block: Block) -> String {
        if block.identity == Block.verbatimIdentity {
            return block.segments.map(\.text).joined()
        }

        // Code blocks reproduce their text verbatim inside fences — inline
        // flags never apply there (the mono font is block presentation).
        if case .codeBlock(let language) = block.kind {
            let body = trimTrailingNewlines(block.segments.map(\.text).joined())
            return "```\(language ?? "")\n\(body)\n```"
        }

        var text = trimTrailingNewlines(inlineMarkdown(block.segments))

        switch block.kind {
        case .header(let level):
            text = String(repeating: "#", count: level) + " " + text
        case .blockQuote:
            text = text
                .components(separatedBy: "\n")
                .map { "> " + $0 }
                .joined(separator: "\n")
        case .listItem:
            // The rendered marker is part of the text ("• " / "N. ").
            // Translate the bullet; ordered markers are already markdown. A
            // partial selection that missed the marker stays markerless.
            if text.hasPrefix("\u{2022} ") {
                text = "- " + text.dropFirst(2)
            }
        case .paragraph, .codeBlock:
            break
        }
        return text
    }

    private static func trimTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: - Inline rendering

    /// Delimiter emission order: outermost first. Closing happens in reverse.
    private static let delimiterOrder: [(MarkdownInlineFlags, String)] = [
        (.bold, "**"),
        (.italic, "*"),
        (.strikethrough, "~~"),
        (.code, "`"),
    ]

    /// Streams segments through an open-delimiter stack so nested styles emit
    /// properly nested markdown (`**bold *both* bold**`) instead of broken
    /// adjacent pairs (`**bold ***both*** bold**`). Whitespace at style edges
    /// is shifted outside the delimiters — `** bold**` doesn't parse.
    private static func inlineMarkdown(_ segments: [Segment]) -> String {
        var output = ""
        var open: [MarkdownInlineFlags] = []

        func close(downTo keep: Int) {
            while open.count > keep {
                let flag = open.removeLast()
                let delimiter = delimiterOrder.first { $0.0 == flag }!.1
                // Shift trailing spaces/tabs outside the closing delimiter.
                var trailing = ""
                while let last = output.last, last == " " || last == "\t" {
                    trailing = String(output.removeLast()) + trailing
                }
                output += delimiter + trailing
            }
        }

        for segment in segments {
            if let link = segment.link {
                // A link renders as its own unit; close everything first so
                // the bracket never splits an emphasis span.
                close(downTo: 0)
                output += "[\(segment.text)](\(link.absoluteString))"
                continue
            }

            let target = delimiterOrder.map(\.0).filter { segment.inline.contains($0) }
            let common = zip(open, target).prefix { $0 == $1 }.count
            close(downTo: common)

            var text = segment.text
            for flag in target.dropFirst(open.count) {
                // Shift leading whitespace outside the opening delimiter.
                while let first = text.first, first == " " || first == "\t" {
                    output += String(text.removeFirst())
                }
                output += delimiterOrder.first { $0.0 == flag }!.1
                open.append(flag)
            }
            output += text
        }
        close(downTo: 0)
        return output
    }
}
#endif
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -5`
Expected: PASS with an "Executed N tests, with 0 failures" line. If a reconstruction test fails on exact whitespace, inspect the actual output — the parser may normalize (e.g. soft breaks) — and adjust the EXPECTED string only when the difference is parser normalization that re-renders identically (verify with the fixed-point test), never to paper over lost structure.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown
git add MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift
git commit -m "feat(mac): reconstruct markdown from rendered-run annotations"
```

---

### Task 3: `MessageCopyTextView` — pasteboard override + wiring

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/SelectableMessageText.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift`

**Interfaces:**
- Consumes: `MarkdownReconstruction.markdown(from:in:)` (Task 2), `MouseTrackingRescueTextView` (existing).
- Produces: `final class MessageCopyTextView: MouseTrackingRescueTextView { var markdownSource: String }` used by `SelectableTextViewRepresentable`.

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownCopyTests.swift`:

```swift
    // MARK: - Copy override

    private func makeCopyView(_ source: String) -> MessageCopyTextView {
        let view = MessageCopyTextView()
        view.markdownSource = source
        view.textStorage?.setAttributedString(MarkdownAttributed.attributedString(for: source))
        return view
    }

    func test_copy_fullSelection_copiesRawSourceVerbatim() {
        let source = "First **bold**.\n\nSecond with [l](https://e.com)."
        let view = makeCopyView(source)
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .rtf))
    }

    func test_copy_partialSelection_reconstructsMarkdown() {
        let view = makeCopyView("plain **bold** tail")
        let full = view.textStorage!.string as NSString
        // Select from "bold" through "tail" — excludes the plain prefix.
        let start = full.range(of: "bold").location
        view.setSelectedRange(NSRange(location: start, length: full.length - start))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "**bold** tail")
    }

    func test_copy_emptySelection_doesNotClearPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        let view = makeCopyView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sentinel")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -10`
Expected: COMPILE FAILURE — `MessageCopyTextView` undefined.

- [ ] **Step 3: Implement**

In `SelectableMessageText.swift`:

3a. Add the subclass (below the representable, above `Coordinator` or as a top-level type in the same file):

```swift
/// The message-body text view: `MouseTrackingRescueTextView`'s tracking-loop
/// protections plus markdown-preserving copy. `copy(_:)` is the single seam —
/// ⌘C, the Edit menu, and the context menu all route through it for a
/// non-editable text view.
final class MessageCopyTextView: MouseTrackingRescueTextView {
    /// Raw markdown source of the rendered message. A selection covering the
    /// whole storage copies this verbatim (perfect fidelity, matching the
    /// message context menu's Copy); partial selections reconstruct.
    var markdownSource: String = ""

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        // Deterministic no-op on empty selection — `super.copy` with no
        // selection has unspecified behavior and must not clear the
        // pasteboard.
        guard range.length > 0, let storage = textStorage else { return }

        let markdown: String
        if range == NSRange(location: 0, length: storage.length), !markdownSource.isEmpty {
            markdown = markdownSource
        } else {
            markdown = MarkdownReconstruction.markdown(from: storage, in: range)
        }

        // Plain text carries the markdown; RTF carries the rendered look so
        // rich-text targets keep formatting.
        let selected = storage.attributedSubstring(from: range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        if let rtf = selected.rtf(
            from: NSRange(location: 0, length: selected.length),
            documentAttributes: [:]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(markdown, forType: .string)
    }
}
```

3b. Wire it in `SelectableTextViewRepresentable`. In `makeNSView`, change `let textView = MouseTrackingRescueTextView()` → `let textView = MessageCopyTextView()` and add `textView.markdownSource = source` before `return`. Update the comment on that line to note the subclass adds markdown-preserving copy. Change `updateNSView(_ textView: NSTextView, …)` signature's body to also refresh the source: add at the top

```swift
(textView as? MessageCopyTextView)?.markdownSource = source
```

(`NSViewRepresentable`'s `NSViewType` is `NSTextView`; keep the existing signature and cast, matching how the coordinator already casts for `noteLinkClickHandled`.)

- [ ] **Step 4: Run the full new-test class + regression neighbors**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && swift test --filter MarkdownCopyTests 2>&1 | tail -5 && swift test --filter MarkdownAttributedTests 2>&1 | tail -5 && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter SelectableMessageTextSnapshotTests 2>&1 | tail -5`
Expected: all PASS with "Executed N tests, with 0 failures" lines.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown
git add MatronShared/Sources/DesignSystem/SelectableMessageText.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift
git commit -m "feat(mac): copy selection as markdown with RTF companion flavor"
```

---

### Task 4: Full verification + PR

**Files:** none new.

- [ ] **Step 1: Run the whole shared-package suite**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown/MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test 2>&1 | tail -8`
Expected: "Executed N tests, with 0 failures" (assert the count line exists). Pre-existing unrelated failures: compare against the same command on origin/main before blaming this change.

- [ ] **Step 2: Build the Mac app**

Run: `cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown && xcodegen generate 2>&1 | tail -2 && xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Debug -derivedDataPath build/mac-copy build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Do NOT install or launch — the live Mac app stays untouched.

- [ ] **Step 3: Push + open PR**

```bash
cd /Users/danbarker/Dev/matron-worktrees/mac-copy-markdown
git push -u origin feat/mac-copy-markdown
gh pr create --title "Mac: copy selection preserves newlines and markdown formatting" --body "$(cat <<'EOF'
## What

Copying a selection from a Mac chat message now yields markdown as the
plain-text pasteboard flavor — blank lines between paragraphs, restored
fences/inline syntax/links/list markers — plus the rendered rich text as RTF.
Selecting the whole message copies the raw source verbatim (byte-identical
with the message context menu's Copy).

## Why

`MarkdownAttributed` joins blocks with a single newline (paragraph gaps are
`paragraphSpacing`), and all markdown syntax is gone by render time — so a
copied selection pasted anywhere lost paragraph breaks, and pasted into a
markdown-aware target merged paragraphs outright.

## How

- `MarkdownAttributed.build` annotates every run with an inert
  `MarkdownRunSemantics` attribute (block kind + identity, inline flags,
  link, fence language).
- `MarkdownReconstruction` (new, pure) rebuilds markdown for any character
  range from those annotations.
- `MessageCopyTextView` (subclass of `MouseTrackingRescueTextView`) overrides
  `copy(_:)`: full selection → raw source; partial → reconstruction; writes
  `.string` (markdown) + `.rtf` (rendered) flavors.

Spec: docs/superpowers/specs/2026-08-10-mac-copy-markdown-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Report**

Report PR URL to Dan with a note that the installed Mac app needs a rebuild+reinstall to pick it up (fold into the pending reinstall he already owes for the allowances/push fixes).
