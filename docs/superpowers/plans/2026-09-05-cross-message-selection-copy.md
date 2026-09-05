# Cross-Message Selection + Transcript Copy (Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Mac, click inside one message, drag into another, and copy the selected span as a WhatsApp-style transcript (`[date, time] Name: text`) via ⌘C, Edit ▸ Copy, or a right-click "Copy N Messages" item.

**Architecture:** A per-timeline `MessageSelectionController` (macOS, `MatronDesignSystem`) owns the cross-message selection: an anchor and head `(itemID, charIndex)`, a registry of live message text views keyed by item id, and the row order handed in by the timeline. `MessageCopyTextView` (the existing per-message `NSTextView`) runs its own tracking loop for plain single-click presses so a drag can hand off to the controller when it leaves the message vertically; the highlight is drawn with TextKit rendering/temporary attributes so every span looks the same whether or not its view is focused. A pure `TranscriptFormatter` (`MatronChat`) produces the text; `MacChatView` bridges controller spans to `TimelineItem`s.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (`NSTextView`, TextKit 2 with a TextKit 1 fallback for tabled messages), Observation (`@Observable`), XCTest, SwiftPM tests (`swift test`), xcodegen-managed Xcode project.

**Spec:** `docs/superpowers/specs/2026-09-05-cross-message-selection-copy-design.md`

## Global Constraints

- macOS only. Every new AppKit file is wrapped in `#if os(macOS) … #endif`; the shared package also builds for iOS 17.
- Package language mode is Swift 5.10 (no Swift 6 strict-concurrency changes). New classes touching AppKit are `@MainActor`.
- No SwiftUI row may read controller state in its body except the context-menu builder; the eager timeline's per-row `Equatable` gates and the `MacTimelineListContent` `==` must stay untouched in behaviour.
- All existing `SelectableMessageText(_:)` call sites, previews and tests must compile unchanged (new parameters default to `nil`).
- Own messages are labelled `Me`; others use `MacTimelineItemView.displayName(for:)`.
- Timestamp format: `DateFormatter` `dateStyle: .short`, `timeStyle: .short`, bracketed: `[05/09/2026, 14:33]` (en_GB).
- Images copy as `[Photo]`, files as `[File: <filename>]`, each followed by a space and the selected caption text when non-empty. Tool calls, diffs, cards, state notices, indicators are omitted.
- Package tests: run from `MatronShared/` with `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter <Class>`; the final full run uses `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`.
- Mac app build: `xcodegen generate` (only if project.yml or the Mac file set changed — this plan adds no Mac-target files) then `xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`.
- Mac unit tests: ALWAYS pass `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport` (the unsandboxed Debug test host otherwise writes into the live app's journal store) and scope with `-only-testing:MatronMacTests`.
- Commit after every task; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never run `git config user.*` in this worktree.

## File Structure

| File | Responsibility |
|---|---|
| `MatronShared/Sources/Chat/TranscriptFormatter.swift` (new) | Pure: `[TranscriptEntry]` → WhatsApp-style text. Cross-platform. |
| `MatronShared/Tests/ChatTests/TranscriptFormatterTests.swift` (new) | Formatter tests with pinned locales/time zone. |
| `MatronShared/Sources/DesignSystem/MessageSelectionController.swift` (new, macOS) | `CrossSelectionTarget` protocol; `MessageSelectionController` (registry, order, anchor/head, span math, nearest-view fallback, clear monitor, transcript provider + copy). |
| `MatronShared/Tests/DesignSystemSnapshotTests/MessageSelectionControllerTests.swift` (new, macOS) | Span math, fallback, clear, order, copy routing with fake targets. |
| `MatronShared/Sources/DesignSystem/SelectableMessageText.swift` (modify) | `itemID`/controller plumbing on the representable; `MessageCopyTextView` gains `CrossSelectionTarget` conformance, highlight via rendering attributes, copy/validate/menu routing, and the takeover tracking loop. |
| `MatronShared/Sources/DesignSystem/MouseTrackingRescueTextView.swift` (modify) | `resolveLinkPressIfNeeded(expected:)` so the takeover path can dispatch a clean link click without the "swallowed" log. |
| `MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift` (new, macOS) | Escalation band math, highlight attribute application, copy/validate/menu routing. |
| `MatronMac/Features/Chat/MacTimelineItemView.swift` (modify) | Pass `itemID: item.id` to the three `SelectableMessageText` call sites. |
| `MatronMac/Features/Chat/MacChatView.swift` (modify) | Own a controller per `MacChatView` and per `MacSubChatPane`; inject via environment; feed `orderedIDs`; install the transcript provider; row context-menu item; clear on disappear. |
| `manual-tests.md` (modify) | Manual checklist for the drag. |
| `docs/superpowers/specs/2026-09-05-cross-message-selection-copy-design.md` (modify) | Two amendments: no `slot` (an item has either a body or a caption text view, never both); highlight via rendering attributes and an attribute-readback test instead of a snapshot. |

---

### Task 1: TranscriptFormatter

**Files:**
- Create: `MatronShared/Sources/Chat/TranscriptFormatter.swift`
- Test: `MatronShared/Tests/ChatTests/TranscriptFormatterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct TranscriptEntry: Equatable, Sendable {
      public let timestamp: Date
      public let name: String
      public let text: String
      public init(timestamp: Date, name: String, text: String)
  }
  public enum TranscriptFormatter {
      public static func format(_ entries: [TranscriptEntry],
                                locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/ChatTests/TranscriptFormatterTests.swift
import XCTest
@testable import MatronChat

final class TranscriptFormatterTests: XCTestCase {

    private let gb = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-05 14:33:00 UTC
    private let t1 = Date(timeIntervalSince1970: 1_788_705_180)
    /// 2026-09-05 14:35:00 UTC
    private let t2 = Date(timeIntervalSince1970: 1_788_705_300)

    func test_singleEntry_enGB() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Claude", text: "hello")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Claude: hello")
    }

    func test_singleEntry_enUS() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Me", text: "hello")],
            locale: us, timeZone: utc)
        // en_US short date/time — narrow no-break space before PM on recent
        // Foundation; normalise to a plain space before asserting.
        let normalised = out.replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(normalised, "[9/5/26, 2:33 PM] Me: hello")
    }

    func test_entriesSeparatedBySingleNewline_noTrailingNewline() {
        let out = TranscriptFormatter.format([
            TranscriptEntry(timestamp: t1, name: "Me", text: "one"),
            TranscriptEntry(timestamp: t2, name: "Claude", text: "two"),
        ], locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Me: one\n[05/09/2026, 14:35] Claude: two")
        XCTAssertFalse(out.hasSuffix("\n"))
    }

    func test_multiLineTextContinuesUnprefixed() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Claude", text: "line 42 expects\nthe fixture is unsorted")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Claude: line 42 expects\nthe fixture is unsorted")
    }

    func test_leadingAndTrailingNewlinesTrimmedPerEntry_innerWhitespaceKept() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Me", text: "\n\n  two  spaces\n\n")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Me:   two  spaces")
    }

    func test_emptyList_isEmptyString() {
        XCTAssertEqual(TranscriptFormatter.format([], locale: gb, timeZone: utc), "")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter TranscriptFormatterTests 2>&1 | tail -5`
Expected: build FAILS with `cannot find 'TranscriptFormatter' in scope` / `TranscriptEntry`.

- [ ] **Step 3: Implement the formatter**

```swift
// MatronShared/Sources/Chat/TranscriptFormatter.swift
import Foundation

/// One line of a copied transcript: who said what, when.
public struct TranscriptEntry: Equatable, Sendable {
    public let timestamp: Date
    public let name: String
    public let text: String

    public init(timestamp: Date, name: String, text: String) {
        self.timestamp = timestamp
        self.name = name
        self.text = text
    }
}

/// WhatsApp-style transcript text:
///
/// ```
/// [05/09/2026, 14:33] Claude: line 42 expects
/// the fixture is unsorted
/// [05/09/2026, 14:35] Me: ok, fix
/// ```
///
/// Date and time follow the locale's short styles (so the user's pasted
/// text reads like their other apps); multi-line bodies continue on their
/// own lines unprefixed; entries are joined by one newline with no
/// trailing newline. Pure and cross-platform — the Mac cross-message copy
/// is the first consumer.
public enum TranscriptFormatter {
    public static func format(
        _ entries: [TranscriptEntry],
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard !entries.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return entries.map { entry in
            let stamp = formatter.string(from: entry.timestamp)
            let body = trimNewlines(entry.text)
            return "[\(stamp)] \(entry.name): \(body)"
        }.joined(separator: "\n")
    }

    /// Trims leading/trailing line breaks only — inner spaces and indents
    /// are part of the message (code, lists) and are kept verbatim.
    private static func trimNewlines(_ text: String) -> String {
        var scalars = Substring(text)
        while let first = scalars.first, first.isNewline { scalars = scalars.dropFirst() }
        while let last = scalars.last, last.isNewline { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter TranscriptFormatterTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`. If the en_US assertion fails only on the separator between date and time (`, ` vs `,\u{202F}`), normalise `\u{202F}` in the test as shown; if it fails on the date pattern itself, print the actual string and pin THAT — the short style is what the spec wants, not a literal pattern.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/TranscriptFormatter.swift MatronShared/Tests/ChatTests/TranscriptFormatterTests.swift
git commit -m "feat(chat): TranscriptFormatter — WhatsApp-style [date, time] Name: text

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: MessageSelectionController (span math, registry, fallback, copy routing)

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MessageSelectionController.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MessageSelectionControllerTests.swift`

**Interfaces:**
- Produces (all macOS, `@MainActor`):
  ```swift
  public protocol CrossSelectionTarget: AnyObject {
      var selectionItemID: String? { get }
      var storageLength: Int { get }
      /// Frame in WINDOW coordinates (AppKit, y-up), used for the nearest-row fallback.
      var frameInWindow: NSRect { get }
      func characterIndex(atWindowPoint point: NSPoint) -> Int
      /// `nil` clears the highlight; a range applies it.
      func setCrossSelection(_ range: NSRange?)
      /// Markdown for the current cross-selection range ("" when none/empty).
      func crossSelectionMarkdown() -> String
  }

  public struct SelectedSpan: Equatable {
      public let id: String
      /// `nil` = the message has no text view (image without caption, card).
      public let text: String?
  }

  public struct Transcript { public let text: String; public let messageCount: Int }

  @MainActor @Observable public final class MessageSelectionController {
      public init()
      @ObservationIgnored public var orderedIDs: [String]
      /// Observed: drives the context-menu item and ⌘C validation.
      public private(set) var hasSelection: Bool
      /// Installed by the timeline host; builds the transcript from `selectedSpans()`.
      @ObservationIgnored public var transcriptProvider: (() -> Transcript)?
      /// Seam for tests; defaults to `Pasteboard.copy`.
      @ObservationIgnored public var pasteboardWriter: (String) -> Void
      /// Seam for tests; defaults to hit-testing the window's view tree.
      @ObservationIgnored public var hitTester: (NSPoint, NSWindow) -> CrossSelectionTarget?
      public func register(_ target: CrossSelectionTarget)
      public func unregister(_ target: CrossSelectionTarget)
      public func beginCrossMessage(anchorID: String, charIndex: Int)
      public func extend(toWindowPoint point: NSPoint, window: NSWindow?)
      public func finish()
      public func clear()
      public func selectedSpans() -> [SelectedSpan]
      public func copyTranscript()
      /// Ids between anchor and head (inclusive) in row order; empty when no selection.
      public var selectedIDs: [String] { get }
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/MessageSelectionControllerTests.swift
#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// Span math and registry behaviour of the cross-message selection
/// controller, driven with fake targets (no windows, no AppKit text views).
@MainActor
final class MessageSelectionControllerTests: XCTestCase {

    /// A stand-in message body: `length` characters laid out as one line
    /// per 10 characters inside `frame` (window coords, y-up), so a window
    /// point maps to a character index deterministically.
    final class FakeTarget: CrossSelectionTarget {
        let selectionItemID: String?
        let storageLength: Int
        let frameInWindow: NSRect
        var applied: [NSRange?] = []
        var current: NSRange?
        var markdown: (NSRange) -> String = { r in "chars \(r.location)..<\(r.location + r.length)" }

        init(id: String, length: Int, frame: NSRect) {
            selectionItemID = id
            storageLength = length
            frameInWindow = frame
        }

        func characterIndex(atWindowPoint point: NSPoint) -> Int {
            // Above the frame (y-up: y > maxY) → 0; below → length; inside →
            // proportional to the distance from the top edge.
            if point.y >= frameInWindow.maxY { return 0 }
            if point.y <= frameInWindow.minY { return storageLength }
            let fraction = (frameInWindow.maxY - point.y) / frameInWindow.height
            return min(storageLength, max(0, Int((fraction * CGFloat(storageLength)).rounded(.down))))
        }

        func setCrossSelection(_ range: NSRange?) {
            applied.append(range)
            current = range
        }

        func crossSelectionMarkdown() -> String {
            guard let current, current.length > 0 else { return "" }
            return markdown(current)
        }
    }

    private var controller: MessageSelectionController!
    // Rows stacked top→bottom in a 400pt-tall window: A (y 300–360),
    // B (200–240), C (100–160). Gap between them is card/padding space.
    private var a: FakeTarget!
    private var b: FakeTarget!
    private var c: FakeTarget!

    override func setUp() {
        super.setUp()
        controller = MessageSelectionController()
        controller.hitTester = { _, _ in nil }   // force the nearest-row fallback
        a = FakeTarget(id: "a", length: 60, frame: NSRect(x: 0, y: 300, width: 300, height: 60))
        b = FakeTarget(id: "b", length: 40, frame: NSRect(x: 0, y: 200, width: 300, height: 40))
        c = FakeTarget(id: "c", length: 60, frame: NSRect(x: 0, y: 100, width: 300, height: 60))
        controller.orderedIDs = ["a", "b", "c"]
        // Register out of row order on purpose — order must come from `orderedIDs`.
        controller.register(c)
        controller.register(a)
        controller.register(b)
    }

    func test_noSelection_initially() {
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertEqual(controller.selectedSpans(), [])
    }

    func test_dragDown_anchorToEnd_middlesFull_headFromStart() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 10)
        // Pointer halfway down C → index 30 of 60.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertTrue(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(a.current, NSRange(location: 10, length: 50))
        XCTAssertEqual(b.current, NSRange(location: 0, length: 40))
        XCTAssertEqual(c.current, NSRange(location: 0, length: 30))
    }

    func test_dragUp_anchorFromStart_headToEnd() {
        controller.beginCrossMessage(anchorID: "c", charIndex: 20)
        // Pointer inside A, a quarter of the way down → index 15.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 345), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(a.current, NSRange(location: 15, length: 45))
        XCTAssertEqual(b.current, NSRange(location: 0, length: 40))
        XCTAssertEqual(c.current, NSRange(location: 0, length: 20))
    }

    func test_headEqualsAnchor_collapsesToWithinMessageRange() {
        controller.beginCrossMessage(anchorID: "b", charIndex: 30)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 230), window: nil) // index 10 of B
        XCTAssertEqual(controller.selectedIDs, ["b"])
        XCTAssertEqual(b.current, NSRange(location: 10, length: 20))
        XCTAssertNil(a.current)
        XCTAssertNil(c.current)
    }

    func test_pointerInGapAboveHead_givesZeroLengthHeadSpan() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        // y = 250 is between A (minY 300) and B (maxY 240); nearer B by 10 vs 50.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 250), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertEqual(b.current, NSRange(location: 0, length: 0))
        XCTAssertEqual(controller.selectedSpans(), [
            SelectedSpan(id: "a", text: "chars 0..<60"),
            SelectedSpan(id: "b", text: ""),
        ])
    }

    func test_pointerBelowEverything_selectsThroughLastRowFully() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 5)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 10), window: nil)
        XCTAssertEqual(c.current, NSRange(location: 0, length: 60))
    }

    func test_directHitWins_overNearest() {
        controller.hitTester = { [b] _, _ in b }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        // Geometrically nearest is C, but the hit test says B.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertNil(c.current)
    }

    func test_extendingShrinksPreviouslySelectedRows() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)  // through C
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)  // back to B
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertNil(c.current, "a row that left the range must have its highlight cleared")
    }

    func test_idsWithoutTarget_areInSelectedIDs_butSpanTextIsNil() {
        controller.orderedIDs = ["a", "card", "b", "c"]
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "card", "b"])
        XCTAssertEqual(controller.selectedSpans().map(\.id), ["a", "card", "b"])
        XCTAssertNil(controller.selectedSpans()[1].text)
    }

    func test_clear_zeroesEveryTarget_andHasSelectionFalse() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        controller.clear()
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertNil(a.current); XCTAssertNil(b.current); XCTAssertNil(c.current)
    }

    func test_unregisteredTarget_isSkipped() {
        controller.unregister(b)
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertNil(b.current)
        XCTAssertEqual(controller.selectedSpans()[1], SelectedSpan(id: "b", text: nil))
    }

    func test_anchorNotInOrder_isIgnored() {
        controller.beginCrossMessage(anchorID: "zzz", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertFalse(controller.hasSelection)
    }

    func test_copyTranscript_writesProviderText_andSkipsEmpty() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { Transcript(text: "[x] Me: hi", messageCount: 1) }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        controller.copyTranscript()
        XCTAssertEqual(written, ["[x] Me: hi"])

        controller.transcriptProvider = { Transcript(text: "", messageCount: 0) }
        controller.copyTranscript()
        XCTAssertEqual(written, ["[x] Me: hi"], "an empty transcript must not clear the pasteboard")
    }

    func test_copyTranscript_withoutSelection_isNoop() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { Transcript(text: "x", messageCount: 1) }
        controller.copyTranscript()
        XCTAssertEqual(written, [])
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MessageSelectionControllerTests 2>&1 | tail -5`
Expected: build FAILS with `cannot find type 'CrossSelectionTarget'` / `'MessageSelectionController'`.

- [ ] **Step 3: Implement the controller**

```swift
// MatronShared/Sources/DesignSystem/MessageSelectionController.swift
#if os(macOS)
import AppKit
import Observation

/// One message body (or caption) that can take part in a cross-message
/// selection. `MessageCopyTextView` is the production conformer; tests use
/// fakes. Everything is in WINDOW coordinates so the controller never needs
/// to know about scroll views or SwiftUI hosting.
@MainActor
public protocol CrossSelectionTarget: AnyObject {
    var selectionItemID: String? { get }
    var storageLength: Int { get }
    /// Frame in window coordinates (AppKit, y grows upward).
    var frameInWindow: NSRect { get }
    /// Insertion index for a window point, clamped by the conformer to
    /// `0…storageLength` (AppKit's `characterIndexForInsertion` already does).
    func characterIndex(atWindowPoint point: NSPoint) -> Int
    /// `nil` removes the highlight; a range applies it (zero length = none visible).
    func setCrossSelection(_ range: NSRange?)
    /// Markdown for the current range; `""` when there is none or it is empty.
    func crossSelectionMarkdown() -> String
}

/// A message's contribution to the selection, in row order.
public struct SelectedSpan: Equatable {
    public let id: String
    /// `nil` — the message has no text view (image without caption, a card).
    /// `""` — it has one, but the selected part is empty (pointer in the gap
    /// just above it).
    public let text: String?

    public init(id: String, text: String?) {
        self.id = id
        self.text = text
    }
}

/// What the timeline host builds from `selectedSpans()`: the pasteboard
/// text and how many messages contributed a line (for "Copy N Messages").
public struct Transcript {
    public let text: String
    public let messageCount: Int

    public init(text: String, messageCount: Int) {
        self.text = text
        self.messageCount = messageCount
    }
}

/// The cross-message selection of ONE timeline (a `MacChatView` or a
/// `MacSubChatPane` each own one). Holds the anchor and head as
/// `(item id, character index)`, the row order the timeline hands in, and
/// weak references to the live message text views so it can push per-view
/// highlight ranges as a drag extends.
///
/// Observation: only `hasSelection` is observed (context-menu builders and
/// ⌘C validation read it). Everything the drag touches per mouse event is
/// `@ObservationIgnored`, so extending the selection never invalidates a
/// SwiftUI row — the eager timeline's per-row gates are the scroll-perf
/// fence and must not be tripped by pointer movement.
@MainActor
@Observable
public final class MessageSelectionController {

    /// Message item ids in row order; assigned by the timeline list whenever
    /// its rows change. Plain storage: written from `onChange`, never read
    /// from a SwiftUI body.
    @ObservationIgnored public var orderedIDs: [String] = []

    public private(set) var hasSelection = false

    @ObservationIgnored public var transcriptProvider: (() -> Transcript)?
    @ObservationIgnored public var pasteboardWriter: (String) -> Void = { Pasteboard.copy($0) }
    /// Resolves the target directly under a window point (nil → use the
    /// nearest-row fallback). Default walks the hit-test view up its
    /// superviews looking for a conformer.
    @ObservationIgnored public var hitTester: (NSPoint, NSWindow) -> CrossSelectionTarget? = { point, window in
        var view = window.contentView?.hitTest(point)
        while let current = view {
            if let target = current as? CrossSelectionTarget { return target }
            view = current.superview
        }
        return nil
    }

    private struct End: Equatable {
        let id: String
        let charIndex: Int
    }

    @ObservationIgnored private var anchor: End?
    @ObservationIgnored private var head: End?
    @ObservationIgnored private var targets: [String: WeakTarget] = [:]
    /// Ids that currently carry a non-nil range, so a shrink can clear only those.
    @ObservationIgnored private var highlighted: Set<String> = []
    @ObservationIgnored private var clearMonitor: Any?

    private final class WeakTarget {
        weak var target: CrossSelectionTarget?
        init(_ target: CrossSelectionTarget) { self.target = target }
    }

    public init() {}

    // MARK: Registry

    public func register(_ target: CrossSelectionTarget) {
        guard let id = target.selectionItemID else { return }
        targets[id] = WeakTarget(target)
    }

    public func unregister(_ target: CrossSelectionTarget) {
        guard let id = target.selectionItemID, targets[id]?.target === target else { return }
        targets[id] = nil
    }

    private func target(for id: String) -> CrossSelectionTarget? {
        targets[id]?.target
    }

    // MARK: Selection lifecycle

    public func beginCrossMessage(anchorID: String, charIndex: Int) {
        clear()
        guard orderedIDs.contains(anchorID) else { return }
        anchor = End(id: anchorID, charIndex: charIndex)
        head = anchor
        hasSelection = true
    }

    public func extend(toWindowPoint point: NSPoint, window: NSWindow?) {
        guard anchor != nil else { return }
        guard let target = resolveTarget(at: point, window: window),
              let id = target.selectionItemID,
              orderedIDs.contains(id) else { return }
        head = End(id: id, charIndex: target.characterIndex(atWindowPoint: point))
        applySpans()
    }

    public func finish() {
        guard anchor != nil else { return }
        applySpans()
        installClearMonitor()
    }

    public func clear() {
        for id in highlighted { target(for: id)?.setCrossSelection(nil) }
        highlighted = []
        anchor = nil
        head = nil
        removeClearMonitor()
        if hasSelection { hasSelection = false }
    }

    // MARK: Reading the selection

    /// Ids between anchor and head inclusive, in row order.
    public var selectedIDs: [String] {
        guard let anchor, let head,
              let a = orderedIDs.firstIndex(of: anchor.id),
              let h = orderedIDs.firstIndex(of: head.id) else { return [] }
        return Array(orderedIDs[min(a, h)...max(a, h)])
    }

    public func selectedSpans() -> [SelectedSpan] {
        selectedIDs.map { id in
            SelectedSpan(id: id, text: target(for: id)?.crossSelectionMarkdown())
        }
    }

    public func copyTranscript() {
        guard hasSelection, let transcript = transcriptProvider?(), !transcript.text.isEmpty else { return }
        pasteboardWriter(transcript.text)
    }

    // MARK: Internals

    /// Direct hit first; otherwise the registered target vertically nearest
    /// the point (distance to its frame's y-extent, 0 when inside), ties
    /// broken by row order.
    private func resolveTarget(at point: NSPoint, window: NSWindow?) -> CrossSelectionTarget? {
        if let window, let direct = hitTester(point, window), direct.selectionItemID != nil {
            return direct
        }
        var best: (CrossSelectionTarget, CGFloat)?
        for id in orderedIDs {
            guard let candidate = target(for: id) else { continue }
            let frame = candidate.frameInWindow
            let distance: CGFloat
            if point.y > frame.maxY { distance = point.y - frame.maxY }
            else if point.y < frame.minY { distance = frame.minY - point.y }
            else { distance = 0 }
            if best == nil || distance < best!.1 { best = (candidate, distance) }
        }
        return best?.0
    }

    /// Recomputes every per-view range from anchor/head and pushes it.
    /// Dragging DOWN (anchor row above head row): anchor `press…end`,
    /// middles full, head `start…pointer`. Dragging UP mirrors it. Same row:
    /// the ordinary min…max range.
    private func applySpans() {
        guard let anchor, let head,
              let a = orderedIDs.firstIndex(of: anchor.id),
              let h = orderedIDs.firstIndex(of: head.id) else { return }
        var next: [String: NSRange] = [:]
        if a == h {
            let lo = min(anchor.charIndex, head.charIndex)
            let hi = max(anchor.charIndex, head.charIndex)
            next[anchor.id] = NSRange(location: lo, length: hi - lo)
        } else {
            let down = a < h
            for id in orderedIDs[min(a, h)...max(a, h)] {
                guard let target = target(for: id) else { continue }
                let length = target.storageLength
                let range: NSRange
                if id == anchor.id {
                    let i = min(anchor.charIndex, length)
                    range = down ? NSRange(location: i, length: length - i) : NSRange(location: 0, length: i)
                } else if id == head.id {
                    let i = min(head.charIndex, length)
                    range = down ? NSRange(location: 0, length: i) : NSRange(location: i, length: length - i)
                } else {
                    range = NSRange(location: 0, length: length)
                }
                next[id] = range
            }
        }
        for id in highlighted where next[id] == nil {
            target(for: id)?.setCrossSelection(nil)
        }
        for (id, range) in next {
            target(for: id)?.setCrossSelection(range)
        }
        highlighted = Set(next.keys.filter { target(for: $0) != nil })
    }

    private func installClearMonitor() {
        removeClearMonitor()
        clearMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Any left press anywhere ends the selection. Right-clicks keep
            // it so "Copy N Messages" can act on it.
            self?.clear()
            return event
        }
    }

    private func removeClearMonitor() {
        if let clearMonitor {
            NSEvent.removeMonitor(clearMonitor)
            self.clearMonitor = nil
        }
    }
}
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MessageSelectionControllerTests 2>&1 | tail -5`
Expected: `Executed 14 tests, with 0 failures`.

If `test_pointerInGapAboveHead_givesZeroLengthHeadSpan` fails on the span text for `a`, check that `FakeTarget.markdown` is only consulted when `current.length > 0` (a full 60-char range for A gives `chars 0..<60`).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/MessageSelectionController.swift MatronShared/Tests/DesignSystemSnapshotTests/MessageSelectionControllerTests.swift
git commit -m "feat(design-system): MessageSelectionController — cross-message span math + registry (Mac)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: MessageCopyTextView joins the selection (target conformance, highlight, copy/validate/menu)

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/SelectableMessageText.swift` (the `MessageCopyTextView` class, currently lines ~40–80, and the representable's `makeNSView`/`updateNSView`)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift`

**Interfaces:**
- Consumes: `CrossSelectionTarget`, `MessageSelectionController`, `Transcript` (Task 2); `MarkdownReconstruction.markdown(from:in:)` (existing, internal).
- Produces on `MessageCopyTextView`:
  ```swift
  var selectionItemID: String?                      // set by the representable
  var selectionController: MessageSelectionController?   // set by the representable; re-registers on change
  // CrossSelectionTarget conformance (storageLength, frameInWindow, characterIndex(atWindowPoint:), setCrossSelection(_:), crossSelectionMarkdown())
  var crossSelectionRange: NSRange?                 // read by tests
  static func menuTitle(forMessageCount count: Int) -> String   // "Copy 1 Message" / "Copy 3 Messages"
  @objc func copyCrossSelection(_ sender: Any?)
  ```
  and `SelectableMessageText.init(_ source: String, itemID: String? = nil)`.

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift
#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// `MessageCopyTextView`'s side of the cross-message selection: target
/// conformance, highlight application, and the three copy entry points.
/// The tracking loop itself is exercised manually (see manual-tests.md) —
/// AppKit press paths cannot be driven deterministically headless.
@MainActor
final class MessageCopyTextViewSelectionTests: XCTestCase {

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private var window: NSWindow!
    private var controller: MessageSelectionController!
    private var textView: MessageCopyTextView!

    override func setUp() {
        super.setUp()
        controller = MessageSelectionController()
        controller.orderedIDs = ["m1", "m2"]
        textView = MessageCopyTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.markdownSource = "plain **bold** text"
        textView.textStorage?.setAttributedString(MarkdownAttributed.attributedString(for: "plain **bold** text"))
        textView.selectionItemID = "m1"
        textView.selectionController = controller
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = textView
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: Registration

    func test_registersOnWindowAttach_unregistersOnDetach() {
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 10, y: 10), window: nil)
        XCTAssertNotNil(textView.crossSelectionRange, "attached view must be registered and receive a range")
        controller.clear()
        window.contentView = nil
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 10, y: 10), window: nil)
        XCTAssertNil(textView.crossSelectionRange, "a detached view must no longer be registered")
    }

    // MARK: Highlight

    func test_setCrossSelection_appliesAndRemovesBackgroundRenderingAttribute() throws {
        let layoutManager = try XCTUnwrap(textView.textLayoutManager, "message bodies use TextKit 2")
        textView.setCrossSelection(NSRange(location: 0, length: 5))
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 0, length: 5))
        XCTAssertNotNil(backgroundRenderingColor(in: layoutManager, at: 2))
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 10))
        textView.setCrossSelection(nil)
        XCTAssertNil(textView.crossSelectionRange)
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 2))
    }

    func test_setCrossSelection_clampsToStorageLength() {
        let length = textView.textStorage!.length
        textView.setCrossSelection(NSRange(location: 3, length: length + 50))
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 3, length: length - 3))
    }

    // MARK: Markdown for the span

    func test_crossSelectionMarkdown_wholeStorage_isVerbatimSource() {
        textView.setCrossSelection(NSRange(location: 0, length: textView.textStorage!.length))
        XCTAssertEqual(textView.crossSelectionMarkdown(), "plain **bold** text")
    }

    func test_crossSelectionMarkdown_partial_reconstructs() {
        let boldRange = (textView.textStorage!.string as NSString).range(of: "bold")
        textView.setCrossSelection(boldRange)
        XCTAssertEqual(textView.crossSelectionMarkdown(), "**bold**")
    }

    func test_crossSelectionMarkdown_empty_isEmptyString() {
        textView.setCrossSelection(NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.crossSelectionMarkdown(), "")
        textView.setCrossSelection(nil)
        XCTAssertEqual(textView.crossSelectionMarkdown(), "")
    }

    // MARK: Copy routing

    func test_copy_routesToTranscript_whenControllerHasSelection() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { Transcript(text: "[t] Me: hi", messageCount: 2) }
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        textView.copy(nil)
        XCTAssertEqual(written, ["[t] Me: hi"])
    }

    func test_copy_fallsBackToMarkdownCopy_withoutCrossSelection() {
        NSPasteboard.general.clearContents()
        textView.setSelectedRange(NSRange(location: 0, length: textView.textStorage!.length))
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "plain **bold** text")
    }

    func test_validateCopy_trueWhileSelected_evenWithEmptyTextSelection() {
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(textView.validateUserInterfaceItem(item))
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        XCTAssertTrue(textView.validateUserInterfaceItem(item))
    }

    // MARK: Context menu

    func test_menuTitle_pluralises() {
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 1), "Copy 1 Message")
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 3), "Copy 3 Messages")
    }

    func test_menu_prependsCopyMessages_onlyWhileSelected() {
        controller.transcriptProvider = { Transcript(text: "x", messageCount: 3) }
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let before = textView.menu(for: event)
        XCTAssertFalse((before?.items ?? []).contains { $0.title == "Copy 3 Messages" })

        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        let menu = try! XCTUnwrap(textView.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Copy 3 Messages")
        XCTAssertEqual(menu.items.first?.action, #selector(MessageCopyTextView.copyCrossSelection(_:)))
        XCTAssertTrue(menu.items.count >= 2 && menu.items[1].isSeparatorItem)
    }

    // MARK: Helpers

    private func backgroundRenderingColor(in layoutManager: NSTextLayoutManager, at offset: Int) -> NSColor? {
        let content = layoutManager.textContentManager!
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        return layoutManager.renderingAttributes(at: location)[.backgroundColor] as? NSColor
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MessageCopyTextViewSelectionTests 2>&1 | tail -5`
Expected: build FAILS with `value of type 'MessageCopyTextView' has no member 'selectionItemID'`.

- [ ] **Step 3: Implement the conformance, highlight and routing**

Replace the whole `MessageCopyTextView` class in `SelectableMessageText.swift` with:

```swift
/// The message-body text view: `MouseTrackingRescueTextView`'s tracking-loop
/// protections plus markdown-preserving copy, plus the view's side of the
/// cross-message selection (`CrossSelectionTarget`). `copy(_:)` is the
/// single seam — ⌘C, the Edit menu, and the context menu all route through
/// it for a non-editable text view.
final class MessageCopyTextView: MouseTrackingRescueTextView, CrossSelectionTarget {
    /// Raw markdown source of the rendered message. A selection covering the
    /// whole storage copies this verbatim (perfect fidelity, matching the
    /// message context menu's Copy); partial selections reconstruct via
    /// `MarkdownReconstruction`.
    var markdownSource: String = ""

    /// The timeline item this body belongs to. `nil` (previews, tests, the
    /// composer palette) keeps the view out of any cross-message selection.
    var selectionItemID: String? {
        didSet { reregister(previousController: selectionController) }
    }

    /// The owning timeline's controller. Registration follows the window:
    /// attached views are candidates, detached ones are dropped.
    var selectionController: MessageSelectionController? {
        didSet { reregister(previousController: oldValue) }
    }

    /// The span of THIS message inside the cross-message selection, or nil.
    /// Drawn through TextKit rendering attributes (TK2) / temporary
    /// attributes (TK1) rather than `selectedRange`, so every span in the
    /// selection paints in the same colour — `selectedRange` would draw
    /// unemphasized grey in every view that is not first responder, and
    /// only one can be.
    private(set) var crossSelectionRange: NSRange?

    // MARK: Registration

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reregister(previousController: selectionController)
    }

    private func reregister(previousController: MessageSelectionController?) {
        previousController?.unregister(self)
        if window != nil, selectionItemID != nil {
            selectionController?.register(self)
        } else {
            // Leaving the window (or losing our id) also drops any highlight.
            if crossSelectionRange != nil { setCrossSelection(nil) }
        }
    }

    // MARK: CrossSelectionTarget

    var storageLength: Int { textStorage?.length ?? 0 }

    var frameInWindow: NSRect {
        convert(bounds, to: nil)
    }

    func characterIndex(atWindowPoint point: NSPoint) -> Int {
        characterIndexForInsertion(at: convert(point, from: nil))
    }

    func setCrossSelection(_ range: NSRange?) {
        let length = storageLength
        let clamped: NSRange? = range.map { r in
            let location = min(max(0, r.location), length)
            let end = min(max(location, r.location + r.length), length)
            return NSRange(location: location, length: end - location)
        }
        crossSelectionRange = clamped
        applyHighlight(clamped)
    }

    func crossSelectionMarkdown() -> String {
        guard let storage = textStorage, let range = crossSelectionRange, range.length > 0 else { return "" }
        let clamped = NSRange(location: min(range.location, storage.length),
                              length: min(range.length, storage.length - min(range.location, storage.length)))
        guard clamped.length > 0 else { return "" }
        if clamped == NSRange(location: 0, length: storage.length), !markdownSource.isEmpty {
            return markdownSource
        }
        return MarkdownReconstruction.markdown(from: storage, in: clamped)
    }

    private func applyHighlight(_ range: NSRange?) {
        let full = NSRange(location: 0, length: storageLength)
        if let layoutManager = textLayoutManager, let content = layoutManager.textContentManager {
            // TextKit 2: rendering attributes are draw-only — never enter the
            // storage, never affect `MarkdownReconstruction`.
            layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
            if let range, range.length > 0, let textRange = Self.textRange(range, in: content) {
                layoutManager.addRenderingAttribute(
                    .backgroundColor, value: NSColor.selectedTextBackgroundColor, for: textRange)
            }
        } else if let layoutManager = layoutManager {
            // TextKit 1 (tabled messages, see `useTextKit1IfTabled`).
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            if let range, range.length > 0 {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: range)
            }
        }
        needsDisplay = true
    }

    private static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: Copy entry points

    static func menuTitle(forMessageCount count: Int) -> String {
        "Copy \(count) Message\(count == 1 ? "" : "s")"
    }

    @objc func copyCrossSelection(_ sender: Any?) {
        selectionController?.copyTranscript()
    }

    override func copy(_ sender: Any?) {
        if let selectionController, selectionController.hasSelection {
            selectionController.copyTranscript()
            return
        }
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

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // The anchor's own text selection is empty during a cross-message
        // selection, which would grey out Edit ▸ Copy.
        if item.action == #selector(NSText.copy(_:)), selectionController?.hasSelection == true {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let selectionController, selectionController.hasSelection,
              let count = selectionController.transcriptProvider?().messageCount, count > 0 else { return menu }
        let item = NSMenuItem(
            title: Self.menuTitle(forMessageCount: count),
            action: #selector(copyCrossSelection(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }
}
```

Then in the representable, thread the id and controller through. Change the public view and representable:

```swift
public struct SelectableMessageText: View {
    private let source: String
    private let itemID: String?
    private let rendered: MarkdownAttributed.Rendered
    /// The owning timeline's cross-message selection, when hosted in one.
    /// Optional environment: previews, tests and non-timeline hosts have
    /// none, and the body then behaves exactly as before.
    @Environment(MessageSelectionController.self) private var selectionController: MessageSelectionController?

    /// - Parameters:
    ///   - source: raw markdown message body. (…existing doc…)
    ///   - itemID: the timeline item this body belongs to; enables the
    ///     cross-message selection. `nil` opts out.
    public init(_ source: String, itemID: String? = nil) {
        self.source = source
        self.itemID = itemID
        self.rendered = MarkdownAttributed.rendered(for: source)
    }

    public var body: some View {
        SelectableTextViewRepresentable(
            source: source, rendered: rendered,
            itemID: itemID, selectionController: selectionController)
    }
}
```

In `SelectableTextViewRepresentable` add the two stored properties `let itemID: String?` and `let selectionController: MessageSelectionController?`; in `makeNSView` after `textView.markdownSource = source` add:

```swift
        textView.selectionItemID = itemID
        textView.selectionController = selectionController
```

and in `updateNSView` after the `markdownSource` line add:

```swift
        if let view = textView as? MessageCopyTextView {
            if view.selectionItemID != itemID { view.selectionItemID = itemID }
            if view.selectionController !== selectionController { view.selectionController = selectionController }
        }
```

Also in `updateNSView`, the storage replacement branch (`setAttributedString`) must re-apply the highlight — TextKit drops rendering attributes with the storage. Add right after `context.coordinator.lastApplied = rendered.attributed`:

```swift
            // Streaming replaced the storage: re-clamp and repaint the
            // cross-message span (rendering attributes die with the storage).
            if let view = textView as? MessageCopyTextView, let range = view.crossSelectionRange {
                view.setCrossSelection(range)
            }
```

- [ ] **Step 4: Run the new tests, then the existing copy/link tests**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'MessageCopyTextViewSelectionTests|MarkdownCopyTests|LinkClickTrackingTests|MessageSelectionControllerTests' 2>&1 | tail -6`
Expected: all pass, `0 failures`.

Known wrinkles:
- If `renderingAttributes(at:)` is unavailable on the deployment target, read back via `layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attrs, _ in … }` inside the test helper instead. The production code (`addRenderingAttribute`) is macOS 12+.
- `NSText.copy(_:)` selector: if the compiler rejects `#selector(NSText.copy(_:))`, use `#selector(NSTextView.copy(_:))`; both resolve to `copy:`.
- If `validateUserInterfaceItem` is not overridable on `NSTextView` under this SDK, declare the override as `override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/SelectableMessageText.swift MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift
git commit -m "feat(design-system): message bodies join the cross-message selection — highlight, copy routing, menu item

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The takeover tracking loop (drag across messages)

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/SelectableMessageText.swift` (`MessageCopyTextView`)
- Modify: `MatronShared/Sources/DesignSystem/MouseTrackingRescueTextView.swift` (`resolveLinkPressIfNeeded` gains an `expected:` flag)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift` (append)

**Interfaces:**
- Consumes: `MessageSelectionController.beginCrossMessage/extend/finish/clear` (Task 2); `armLinkPress(for:)`, `resolveLinkPressIfNeeded`, `leftButtonIsDown` (existing seams on the base class).
- Produces on `MessageCopyTextView`:
  ```swift
  static let escapeSlop: CGFloat = 4
  static let pressPollInterval: TimeInterval = 0.25
  static func shouldEscalate(pointY: CGFloat, bounds: NSRect, slop: CGFloat) -> Bool
  static func takesOverPress(_ event: NSEvent) -> Bool
  ```

- [ ] **Step 1: Write the failing tests** (append inside the test class from Task 3, before `// MARK: Helpers`)

```swift
    // MARK: Takeover decisions

    func test_shouldEscalate_onlyOutsideVerticalBandWithSlop() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 60)
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: 30, bounds: bounds, slop: 4))
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: -4, bounds: bounds, slop: 4), "inside slop above")
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: 64, bounds: bounds, slop: 4), "inside slop below")
        XCTAssertTrue(MessageCopyTextView.shouldEscalate(pointY: -4.5, bounds: bounds, slop: 4))
        XCTAssertTrue(MessageCopyTextView.shouldEscalate(pointY: 64.5, bounds: bounds, slop: 4))
    }

    func test_takesOverPress_plainSingleClickOnly() {
        func press(clicks: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 1)!
        }
        XCTAssertTrue(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: [])))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 2, flags: [])), "double-click = word selection stays AppKit's")
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .shift)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .command)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .option)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .control)), "ctrl-click is a context menu")
        XCTAssertTrue(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .capsLock)), "lock keys are not modifiers here")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MessageCopyTextViewSelectionTests 2>&1 | tail -5`
Expected: build FAILS with `type 'MessageCopyTextView' has no member 'shouldEscalate'`.

- [ ] **Step 3: Add the `expected:` flag to the link-press resolver**

In `MouseTrackingRescueTextView.swift`, change the signature and log:

```swift
    /// Called when a press that began on a link is over. If it stayed a
    /// click (button up, pointer within slop, no selection created) and
    /// nobody dispatched the link, the click was swallowed — dispatch it.
    /// Internal for tests — see `armLinkPress`.
    /// - Parameter expected: `true` when the caller ran its OWN tracking
    ///   loop (`MessageCopyTextView`'s takeover path), so AppKit never had
    ///   the chance to dispatch and this is the normal route, not a
    ///   swallowed click — the fault-hunting log line is skipped.
    func resolveLinkPressIfNeeded(expected: Bool = false) {
        guard let press = linkPress else { return }
        linkPress = nil
        guard !linkClickDispatched else { return }
        let here = currentScreenLocation()
        let moved = hypot(here.x - press.screenPoint.x, here.y - press.screenPoint.y)
        guard moved <= Self.linkClickSlop, selectedRange().length == 0 else { return }
        if !expected {
            let storageChanged = textStorage?.string.hashValue != press.storageHash
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000)
            let url = press.link as? URL
            Self.logger.notice("link click swallowed by AppKit — dispatching fallback (scheme \(url?.scheme ?? "?", privacy: .public), host \(url?.host ?? "?", privacy: .public), \(elapsedMs)ms, storageChanged \(storageChanged), moved \(String(format: "%.1f", moved), privacy: .public)pt)")
        }
        // Clamp: a mid-press storage replacement can shrink the text below
        // the pressed index. The LINK value is what matters downstream.
        let safeIndex = min(press.charIndex, max(0, (textStorage?.length ?? 1) - 1))
        clicked(onLink: press.link, at: safeIndex)
    }
```

(The two existing call sites in that file keep calling `resolveLinkPressIfNeeded()` — the default preserves their behaviour.)

- [ ] **Step 4: Implement the takeover loop in `MessageCopyTextView`**

Add to the class (a new `// MARK: Press takeover` section, above `// MARK: Copy entry points`):

```swift
    // MARK: Press takeover

    /// Vertical slack, in points, before a drag leaving the body counts as
    /// leaving the message (guards against jitter on the first/last line).
    static let escapeSlop: CGFloat = 4
    /// How long the loop waits for the next event before re-checking the
    /// physical button — the lost-`mouseUp` guard for this path (see
    /// `MouseTrackingRescueTextView` for why a press can outlive its up).
    static let pressPollInterval: TimeInterval = 0.25

    /// `true` when the pointer's y (view coordinates) is outside the body's
    /// vertical band including `slop`. Horizontal overshoot never escalates
    /// — dragging past a line's end must still select to the line end.
    static func shouldEscalate(pointY: CGFloat, bounds: NSRect, slop: CGFloat) -> Bool {
        pointY < bounds.minY - slop || pointY > bounds.maxY + slop
    }

    /// Plain single left-clicks only. Multi-clicks (word/paragraph
    /// selection) and shift/⌘/⌥/ctrl presses keep AppKit's own handling.
    static func takesOverPress(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1 else { return false }
        return event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller = selectionController, selectionItemID != nil,
              isSelectable, !isEditable, Self.takesOverPress(event) else {
            super.mouseDown(with: event)
            return
        }
        // Any press ends the previous cross-message selection.
        controller.clear()
        armLinkPress(for: event)
        window?.makeFirstResponder(self)

        let anchorIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        setSelectedRange(NSRange(location: anchorIndex, length: 0))

        var escalated = false
        var lastDrag: NSEvent?
        loop: while true {
            guard let window, superview != nil else { break }
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: Self.pressPollInterval),
                inMode: .eventTracking, dequeue: true)
            guard let next else {
                // Timed out: is the press still real?
                if !leftButtonIsDown() { break loop }
                // Pointer parked past an edge — keep autoscrolling and
                // extending while the button is held.
                if escalated, let lastDrag {
                    autoscroll(with: lastDrag)
                    controller.extend(toWindowPoint: lastDrag.locationInWindow, window: window)
                }
                continue
            }
            if next.type == .leftMouseUp { break loop }
            lastDrag = next
            let point = convert(next.locationInWindow, from: nil)
            if Self.shouldEscalate(pointY: point.y, bounds: bounds, slop: Self.escapeSlop) {
                if !escalated {
                    escalated = true
                    // Hand the within-message selection over to the controller.
                    setSelectedRange(NSRange(location: anchorIndex, length: 0))
                    controller.beginCrossMessage(anchorID: selectionItemID!, charIndex: anchorIndex)
                }
                controller.extend(toWindowPoint: next.locationInWindow, window: window)
                autoscroll(with: next)
            } else {
                if escalated {
                    // Back inside the anchor: ordinary text selection again.
                    escalated = false
                    controller.clear()
                }
                let index = characterIndexForInsertion(at: point)
                let range = NSRange(location: min(anchorIndex, index), length: abs(index - anchorIndex))
                setSelectedRange(range, affinity: index < anchorIndex ? .upstream : .downstream, stillSelecting: true)
            }
        }

        if escalated {
            controller.finish()
        } else {
            let range = selectedRange()
            setSelectedRange(range, affinity: .downstream, stillSelecting: false)
            // We ran the loop, so AppKit never saw the click — a clean press
            // on a link is dispatched here as the normal route.
            resolveLinkPressIfNeeded(expected: true)
        }
    }
```

Notes for the implementer:
- `selectionItemID!` is safe: guarded non-nil at the top and only settable from the main thread.
- `superview != nil` handles a mid-press remount (the view was pulled out of the hierarchy) — the loop exits on the next tick.
- Do not call `super.mouseDown` on this path: that would enter AppKit's nested loop and swallow every event this loop needs.
- The existing `mouseUp` override in the base class never fires on this path (the loop dequeues the up), which is why link resolution is done explicitly at the end.

- [ ] **Step 5: Run the tests**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'MessageCopyTextViewSelectionTests|LinkClickTrackingTests|MarkdownCopyTests' 2>&1 | tail -6`
Expected: all pass, `0 failures`. `LinkClickTrackingTests` drive `MouseTrackingRescueTextView` (not the subclass) so they are unaffected by the takeover; they must still pass because of the `expected:` default.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/SelectableMessageText.swift MatronShared/Sources/DesignSystem/MouseTrackingRescueTextView.swift MatronShared/Tests/DesignSystemSnapshotTests/MessageCopyTextViewSelectionTests.swift
git commit -m "feat(design-system): message-body press takeover — drag escalates to a cross-message selection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Timeline item view passes item ids

**Files:**
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift` (three `SelectableMessageText(` call sites: body ~line 108, image caption ~153, file caption ~194)

**Interfaces:**
- Consumes: `SelectableMessageText.init(_:itemID:)` (Task 3).

- [ ] **Step 1: Change the three call sites**

```swift
                SelectableMessageText(body, itemID: item.id)
```
```swift
                        SelectableMessageText(caption, itemID: item.id)
```
```swift
                        SelectableMessageText(caption, itemID: item.id)
```

- [ ] **Step 2: Build the Mac app**

Run: `xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E "error|warning: unused|BUILD" | head`
Expected: no `error:` lines (a `-quiet` build prints nothing on success).

- [ ] **Step 3: Run the Mac item-view tests**

Run: `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MatronMacTests/MacTimelineItemViewTests 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed N tests, with 0 failures` (N > 0 — a missing "Executed" line means the run failed before testing; read the full log).

- [ ] **Step 4: Commit**

```bash
git add MatronMac/Features/Chat/MacTimelineItemView.swift
git commit -m "feat(mac): message bodies and captions carry their item id for cross-message selection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: MacChatView wiring — controller, row order, transcript provider, context menu

**Files:**
- Modify: `MatronMac/Features/Chat/MacChatView.swift`
  - `MacChatView` state (near `@State private var showMediaBrowser`, ~line 276)
  - `MacChatView.body` (~331) for `.environment` + provider install + clear
  - `MacTimelineListContent` (~996) for `orderedIDs`
  - `MacTimelineRowView` `.contextMenu` (~1189) for "Copy N Messages"
  - `MacSubChatPane` (~1253) for its own controller

**Interfaces:**
- Consumes: `MessageSelectionController` (`selectedSpans()`, `transcriptProvider`, `copyTranscript()`, `hasSelection`, `orderedIDs`, `clear()`), `SelectedSpan`, `Transcript` (Task 2); `TranscriptEntry`, `TranscriptFormatter` (Task 1); `MacTimelineItemView.displayName(for:)`; `MessageCopyTextView.menuTitle(forMessageCount:)` is internal to the package — the row menu title is built with the same wording inline (see step 3).
- Produces: `MacChatView.transcript(from:spans:) -> Transcript` (static, so tests can drive it without a view).

- [ ] **Step 1: Write the failing test** (Mac test bundle; `MacChatViewTests.swift` already exists — append a new test class to the END of that file so no new file needs `xcodegen generate`)

```swift
// Append to MatronMacTests/MacChatViewTests.swift
import MatronDesignSystem

/// The bridge from controller spans to transcript text — pure, so it is
/// pinned here without a window or a drag.
final class MacChatViewTranscriptTests: XCTestCase {

    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    private let t = Date(timeIntervalSince1970: 1_788_705_180) // 2026-09-05 14:33 UTC

    private func item(_ id: String, _ kind: TimelineItem.Kind, own: Bool) -> TimelineItem {
        TimelineItem(id: id, sender: own ? "user:dan" : "agent:claude", timestamp: t, kind: kind, isOwn: own)
    }

    func test_textSpans_partialFirstAndLast_namesAndOrder() {
        let items = [
            item("1", .text(body: "first message body", formattedHTML: nil), own: true),
            item("2", .text(body: "middle", formattedHTML: nil), own: false),
            item("3", .text(body: "last message body", formattedHTML: nil), own: true),
        ]
        let spans = [
            SelectedSpan(id: "1", text: "message body"),
            SelectedSpan(id: "2", text: "middle"),
            SelectedSpan(id: "3", text: "last"),
        ]
        let out = MacChatView.transcript(from: items, spans: spans, locale: gb, timeZone: utc)
        XCTAssertEqual(out.messageCount, 3)
        XCTAssertEqual(out.text, """
        [05/09/2026, 14:33] Me: message body
        [05/09/2026, 14:33] claude: middle
        [05/09/2026, 14:33] Me: last
        """)
    }

    func test_emptySpan_andNonTextKinds_areSkipped() {
        let items = [
            item("1", .text(body: "a", formattedHTML: nil), own: true),
            item("tool", .toolCall(eventID: "e", ToolCallEvent(name: "Bash", input: [:], output: nil, status: .done)), own: false),
            item("2", .text(body: "b", formattedHTML: nil), own: false),
        ]
        let spans = [
            SelectedSpan(id: "1", text: "a"),
            SelectedSpan(id: "tool", text: nil),
            SelectedSpan(id: "2", text: ""),
        ]
        let out = MacChatView.transcript(from: items, spans: spans, locale: gb, timeZone: utc)
        XCTAssertEqual(out.messageCount, 1)
        XCTAssertEqual(out.text, "[05/09/2026, 14:33] Me: a")
    }

    func test_imageAndFile_markersWithAndWithoutCaption() {
        let items = [
            item("img", .image(url: nil, caption: "sunset", sizeBytes: nil, expired: false), own: false),
            item("img2", .image(url: nil, caption: nil, sizeBytes: nil, expired: false), own: false),
            item("f", .file(url: nil, filename: "notes.pdf", caption: nil, sizeBytes: nil, expired: false), own: true),
        ]
        let spans = [
            SelectedSpan(id: "img", text: "sunset"),
            SelectedSpan(id: "img2", text: nil),
            SelectedSpan(id: "f", text: nil),
        ]
        let out = MacChatView.transcript(from: items, spans: spans, locale: gb, timeZone: utc)
        XCTAssertEqual(out.messageCount, 3)
        XCTAssertEqual(out.text, """
        [05/09/2026, 14:33] claude: [Photo] sunset
        [05/09/2026, 14:33] claude: [Photo]
        [05/09/2026, 14:33] Me: [File: notes.pdf]
        """)
    }

    func test_captionedImage_withEmptySelectedCaption_isSkipped() {
        let items = [item("img", .image(url: nil, caption: "sunset", sizeBytes: nil, expired: false), own: false)]
        let out = MacChatView.transcript(from: items, spans: [SelectedSpan(id: "img", text: "")], locale: gb, timeZone: utc)
        XCTAssertEqual(out.messageCount, 0)
        XCTAssertEqual(out.text, "")
    }

    func test_spanWithUnknownID_isIgnored() {
        let out = MacChatView.transcript(from: [], spans: [SelectedSpan(id: "ghost", text: "x")], locale: gb, timeZone: utc)
        XCTAssertEqual(out.messageCount, 0)
    }
}
```

Check the `ToolCallEvent` initializer before running: `grep -n "public init" MatronShared/Sources/Events/ToolCallEvent.swift`. If its signature differs, build the value with the real memberwise init — only `kind` being `.toolCall` matters to the test. Also confirm `MacChatViewTests.swift` already imports `MatronChat`, `MatronEvents` and `MatronModels`; add whichever `import` is missing at the top of the file.

- [ ] **Step 2: Run the test to verify it fails**

Run: `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MatronMacTests/MacChatViewTranscriptTests 2>&1 | grep -E "error:|Executed" | head -5`
Expected: compile error `type 'MacChatView' has no member 'transcript'`.

- [ ] **Step 3: Implement the wiring**

(a) **Imports.** Ensure `MacChatView.swift` imports `MatronChat` (for `TranscriptFormatter`) — check the top of the file; `MatronDesignSystem` is already imported.

(b) **The pure bridge.** Add as a `static` on `MacChatView` (next to `sideBySideMinWidth`):

```swift
    /// Controller spans → transcript. Pure: the copy handler feeds it the
    /// current `windowedRows` items and `selectedSpans()`. Skips ids with
    /// no item, non-copyable kinds, and spans whose selected text is empty
    /// (a text view exists but nothing of it is selected — the pointer sat
    /// in the gap above the last message). Images/files with NO caption
    /// view (`text == nil`) still copy as their marker.
    static func transcript(
        from items: [TimelineItem], spans: [SelectedSpan],
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> Transcript {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [TranscriptEntry] = []
        for span in spans {
            guard let item = byID[span.id] else { continue }
            let selected = span.text ?? ""
            let text: String
            switch item.kind {
            case .text:
                guard !selected.isEmpty else { continue }
                text = selected
            case .image(_, let caption, _, _):
                // A captioned image whose caption view is registered but
                // has nothing selected contributes nothing; an uncaptioned
                // one (no view) copies its marker.
                if span.text != nil, selected.isEmpty, !(caption ?? "").isEmpty { continue }
                text = selected.isEmpty ? "[Photo]" : "[Photo] \(selected)"
            case .file(_, let filename, let caption, _, _):
                if span.text != nil, selected.isEmpty, !(caption ?? "").isEmpty { continue }
                text = selected.isEmpty ? "[File: \(filename)]" : "[File: \(filename)] \(selected)"
            default:
                continue
            }
            let name = item.isOwn ? "Me" : MacTimelineItemView.displayName(for: item.sender)
            entries.append(TranscriptEntry(timestamp: item.timestamp, name: name, text: text))
        }
        return Transcript(
            text: TranscriptFormatter.format(entries, locale: locale, timeZone: timeZone),
            messageCount: entries.count)
    }
```

(c) **Owning the controller in `MacChatView`.** Add state next to `showMediaBrowser`:

```swift
    /// This chat's cross-message selection (drag from one message body into
    /// another, then ⌘C). One per timeline: the sub-chat pane owns its own.
    /// Created with the view, so a room switch (`.id(id)` rebuild) starts
    /// clean; `onDisappear` clears it so its click monitor never outlives
    /// the timeline.
    @State private var messageSelection = MessageSelectionController()
```

In `body`, on the `GeometryReader { … }` (the outermost view, BEFORE the existing `.task`), add:

```swift
        .environment(messageSelection)
        .onAppear {
            // Installed here, not in init: the provider needs the live VM.
            let viewModel = viewModel
            messageSelection.transcriptProvider = { [messageSelection] in
                let items = viewModel.windowedRows.compactMap { row -> TimelineItem? in
                    if case .message(let item) = row { return item }
                    return nil
                }
                return Self.transcript(from: items, spans: messageSelection.selectedSpans())
            }
        }
```

and in the existing outer `.onDisappear { … }` (the one that calls `viewModel.stop(ifGeneration:)`), add as the first line:

```swift
            messageSelection.clear()
```

(d) **Row order in `MacTimelineListContent`.** Add an environment property:

```swift
    @Environment(MessageSelectionController.self) private var messageSelection: MessageSelectionController?
```

and on the `VStack(spacing: 8) { … }` in its body, after `.scrollTargetLayout()`:

```swift
        // Row order for the cross-message selection. `onChange` rather than
        // an assignment in `body`: no side effects during evaluation, and
        // `windowedRows` is `Equatable` so this fires only on real changes.
        .onChange(of: viewModel.windowedRows, initial: true) { _, rows in
            messageSelection?.orderedIDs = rows.compactMap { row in
                if case .message(let item) = row { return item.id }
                return nil
            }
        }
```

(e) **Row context menu in `MacTimelineRowView`.** Add the same environment property to `MacTimelineRowView`:

```swift
    @Environment(MessageSelectionController.self) private var messageSelection: MessageSelectionController?
```

(`==` is hand-written and ignores it.) Replace the existing `.contextMenu { … }` on the `MacTimelineItemView(...)` with:

```swift
                // Copy only (Dan, 2026-08-03: no Share / View
                // source, same as the iOS long-press menu). An
                // empty builder result (non-text rows) presents
                // no menu at all. With a cross-message selection
                // present, "Copy N Messages" leads — the body's own
                // AppKit menu offers the same item over the text.
                .contextMenu {
                    if let messageSelection, messageSelection.hasSelection,
                       let count = messageSelection.transcriptProvider?().messageCount, count > 0 {
                        Button {
                            messageSelection.copyTranscript()
                        } label: {
                            Label("Copy \(count) Message\(count == 1 ? "" : "s")", systemImage: "doc.on.doc")
                        }
                        Divider()
                    }
                    if case .text(let body, _) = item.kind {
                        Button {
                            Pasteboard.copy(body)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
```

(f) **`MacSubChatPane`.** Add the same `@State private var messageSelection = MessageSelectionController()` property, put `.environment(messageSelection)` and the same `.onAppear { … transcriptProvider … }` block on the pane's outer `VStack(spacing: 0) { … }` (it uses the pane's `viewModel`, which is the child's VM), and add `messageSelection.clear()` as the first line of the pane's existing `.onDisappear`.

- [ ] **Step 4: Build and run the Mac tests**

Run: `xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E "error" | head`
Expected: no output.

Run: `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MatronMacTests 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: a final `Executed N tests, with 0 failures` line with N ≥ the previous count + 5.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Chat/MacChatView.swift MatronMacTests/MacChatViewTests.swift
git commit -m "feat(mac): cross-message selection wired into the timeline — transcript copy via ⌘C and Copy N Messages

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Manual verification, docs, full test run

**Files:**
- Modify: `manual-tests.md` (append a section)
- Modify: `docs/superpowers/specs/2026-09-05-cross-message-selection-copy-design.md` (two amendments)

- [ ] **Step 1: Build a Release-free Debug run and try it by hand**

Run the app from Xcode (or `open` the built `MatronMac.app` from DerivedData) against a chat with several messages. Work through every line of the checklist in step 3 and fix anything that fails before moving on. Expected findings worth knowing in advance:
- If the highlight is invisible on TextKit 2, the rendering attribute is being dropped on layout invalidation: re-apply it from `MessageCopyTextView.layout()` when `crossSelectionRange != nil` (call `applyHighlight(crossSelectionRange)` after `super.layout()`).
- If ⌘C after a drag copies nothing, the first responder moved: log `window.firstResponder` in `copy` and check `makeFirstResponder(self)` succeeded (a `NSHostingView` can refuse during layout — retry after the loop in `finish()` by asking the anchor view to become first responder again).
- If autoscroll does nothing at the bottom edge, `autoscroll(with:)` is being called with an event whose location is inside the clip view; pass the raw drag event unchanged (do not convert it).

- [ ] **Step 2: Amend the spec** (keep it truthful to what shipped)

In `§1 Selection controller`, replace the registry sentence with: "Registry of live message text views keyed by item id (an item has either a body or a caption view, never both), populated by `MessageCopyTextView` on `viewDidMoveToWindow`…". In `§4 Highlight`, replace the `drawBackground(in:)` paragraph with: "Implementation: TextKit 2 rendering attributes (`NSTextLayoutManager.addRenderingAttribute(.backgroundColor…)`) and TextKit 1 temporary attributes for tabled messages, in `NSColor.selectedTextBackgroundColor`. The anchor's own `selectedRange` is emptied on escalation so AppKit never paints its focused/unfocused variants underneath." In `§8 Testing`, replace the Snapshot paragraph with: "Attribute readback (`MessageCopyTextViewSelectionTests`): applying and clearing a span adds/removes the background rendering attribute — the uniform-colour guarantee is then a property of using one attribute value everywhere, checked visually in the manual pass."

- [ ] **Step 3: Append the manual checklist**

```markdown
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
```

- [ ] **Step 4: Full package test run + Mac build**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test 2>&1 | grep -E "Executed|error:|failed" | tail -3`
Expected: `Executed N tests, with 0 failures`.

Run: `cd .. && xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep error | head`
Expected: no output.

Also confirm the iOS app still builds (the shared package changed): `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep error | head` — expected no output.

- [ ] **Step 5: Commit**

```bash
git add manual-tests.md docs/superpowers/specs/2026-09-05-cross-message-selection-copy-design.md
git commit -m "docs: manual checklist + spec amendments for cross-message selection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage.** §1 controller → Task 2. §2 press/drag (takeover rules, poll timeout, escalate/un-escalate, autoscroll, link resolution) → Task 4. §3 pointer→message (direct hit then nearest, clamped index) → Task 2 (`resolveTarget`) + Task 3 (`characterIndex(atWindowPoint:)`). §4 highlight → Task 3 (rendering/temporary attributes; spec amended in Task 7). §5 copy (three entry points, transcript rules, naming, format) → Tasks 1, 3, 6. §6 wiring → Tasks 5, 6. §7 edge cases: streaming re-clamp → Task 3 `updateNSView`; mid-press remount → Task 4 `superview != nil`; off-window drag → Task 2 nearest fallback; link + drag → existing slop rule; sub-chat pane isolation → Task 6(f); zero-length head span → Task 6 `transcript` skips empty. §8 tests → each task; snapshot replaced by attribute readback (Task 7 amendment).

**Placeholders.** None: every code step carries its code; the "known wrinkles" lists give the concrete alternative API for each.

**Type consistency.** `SelectedSpan(id:text:)`, `Transcript(text:messageCount:)`, `transcriptProvider: (() -> Transcript)?`, `copyTranscript()`, `hasSelection`, `orderedIDs`, `beginCrossMessage(anchorID:charIndex:)`, `extend(toWindowPoint:window:)`, `finish()`, `clear()`, `selectedSpans()` are used identically in Tasks 2, 3, 4 and 6. `MacChatView.transcript(from:spans:locale:timeZone:)` is defined in Task 6 and only used there. `resolveLinkPressIfNeeded(expected:)` is defined in Task 4 and called with `expected: true` in Task 4 only.
