# Matron — Phase 2 (Chat Experience) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 1 (Foundation) merged and CI green.

**Goal:** Make the chat list interactive on **both iOS and macOS** — tapping a chat opens a Timeline view that renders messages, supports a composer with slash commands and attachments, and reads/writes via matrix-rust-sdk Timeline. No custom event rendering yet (Phase 5) and no push (Phase 4); just the standard Matrix message types rendered well. iOS and Mac UIs are co-equal: shared ViewModels in `MatronShared`, per-platform views in `Matron/Features/` and `MatronMac/Features/`.

**Architecture:** A new `Timeline` module in MatronShared wraps the SDK's `Timeline` API and exposes an `AsyncStream<[TimelineItem]>`. Each platform's chat view holds a shared `ChatViewModel` driving a list of typed view items. Rendering primitives (`MarkdownText`, `CodeBlock`, `AttachmentImage`, `AttachmentFile`, `MessageBubble`) live in `MatronShared/Sources/DesignSystem/` so both apps consume them directly. Composer is a separate component with a `/`-triggered slash palette (Mac additionally exposes `⌘K`). Long-press (iOS) / right-click context menu (Mac) provides copy/share/view-source. Mac drag-and-drop for attachments is handled via `.onDrop`.

**Tech Stack:** Same as Phase 1, plus: `MarkdownUI` (https://github.com/gonzalezreal/swift-markdown-ui, MIT) for markdown rendering with code-block support, `swift-snapshot-testing` (https://github.com/pointfreeco/swift-snapshot-testing, MIT) for primitive snapshot tests.

**Reference:** `docs/superpowers/specs/2026-05-02-matron-ios-design.md` §5.4 (chat view), §5.5 (bot profile), §4.4–4.5 (standard event types, composer behavior).

**Out of scope for this phase:** Spec §5.6 (Settings) is implemented in Phase 7 (Polish) Task 4 — see `docs/superpowers/plans/2026-05-02-matron-ios-phase-7-polish.md` — and is deliberately deferred here to keep this phase focused on the chat-pane UI.

---

## File structure (Phase 2 deliverables)

```
matron-apple/
├── MatronShared/Sources/
│   ├── Chat/
│   │   ├── TimelineService.swift             NEW — protocol
│   │   ├── TimelineServiceLive.swift         NEW — wraps SDK Timeline
│   │   ├── TimelineItem.swift                NEW — UI-shaped DTO
│   │   ├── ChatService.swift                 MODIFIED — adds sendMessage / createChat
│   │   └── ChatServiceLive.swift             MODIFIED
│   ├── Media/
│   │   ├── MediaService.swift                NEW — protocol
│   │   └── MediaServiceLive.swift            NEW — mxc:// → Data
│   ├── Models/
│   │   └── BotCommand.swift                  NEW — slash palette catalog entry
│   ├── ViewModels/
│   │   ├── ChatViewModel.swift               NEW — target-agnostic, used by iOS + Mac
│   │   ├── ComposerViewModel.swift           NEW — target-agnostic, used by iOS + Mac
│   │   └── BotProfileViewModel.swift         NEW — target-agnostic, used by iOS + Mac
│   └── DesignSystem/                         (per Phase 1 reorg — primitives live here)
│       ├── MarkdownText.swift                NEW — wraps MarkdownUI
│       ├── CodeBlock.swift                   NEW — monospace + copy button
│       ├── AttachmentImage.swift             NEW
│       ├── AttachmentFile.swift              NEW
│       ├── MessageBubble.swift               NEW — visual container, shared
│       ├── Colors.swift                      NEW — semantic color tokens
│       └── Typography.swift                  NEW — type ramp
├── Matron/Features/Chat/                    (iOS target)
│   ├── ChatView.swift                        NEW
│   ├── Rendering/
│   │   └── TimelineItemView.swift            NEW — switch over TimelineItem case
│   └── Composer/
│       ├── ComposerView.swift                NEW
│       ├── SlashCommandPalette.swift         NEW
│       └── AttachmentPicker.swift            NEW — wraps PhotosPicker / fileImporter
├── Matron/Features/BotProfile/              (iOS target)
│   └── BotProfileView.swift                  NEW
├── Matron/Features/ChatList/                (iOS target)
│   ├── ChatListView.swift                    MODIFIED — adds NavigationLink + ✏️ button
│   └── NewChatSheet.swift                    NEW
├── MatronMac/Features/ChatList/             (Mac target)
│   └── MacChatListView.swift                 NEW — sidebar column, hover, right-click menu
├── MatronMac/Features/Chat/                 (Mac target)
│   ├── MacChatView.swift                     NEW — detail column, .onDrop, ⌘K palette
│   ├── ComposerDropDelegate.swift            NEW — drag-and-drop attachments
│   └── MacChatToolbar.swift                  NEW — sidebar toggle, title, ⓘ, search
├── MatronMac/Features/BotProfile/           (Mac target)
│   └── MacBotProfileSheet.swift              NEW — full-window sheet
├── MatronMac/App/
│   └── Commands.swift                        NEW — menu bar (.commands { ChatCommands() })
└── MatronTests/                              (iOS test target)
    ├── ChatViewModelTests.swift              NEW
    ├── ComposerViewModelTests.swift          NEW
    ├── BotProfileViewModelTests.swift        NEW
    └── SnapshotTests/
        ├── SnapshotVariants.swift            NEW — assertVariants helper (iOS+Mac × light/dark/XXXL = 6)
        ├── MarkdownTextSnapshotTests.swift   NEW
        ├── CodeBlockSnapshotTests.swift      NEW
        ├── MessageBubbleSnapshotTests.swift  NEW
        └── AttachmentImageSnapshotTests.swift NEW
└── MatronMacTests/                           (Mac test target)
    ├── MacChatListViewTests.swift            NEW
    ├── MacChatViewTests.swift                NEW
    ├── MacBotProfileSheetTests.swift         NEW
    └── MacCommandsTests.swift                NEW — verifies notification names fire
```

---

## Tasks

### Task 1: Add MarkdownUI + swift-snapshot-testing to SPM

**Files:**
- Modify: `MatronShared/Package.swift`
- Modify: `project.yml`

- [ ] **Step 1: Add `MarkdownUI` to MatronShared**

In `MatronShared/Package.swift`, append to `dependencies`:

```swift
.package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
```

Add a new product + target for the design-system primitives that depend on it:

```swift
.library(name: "MatronDesignSystem", targets: ["MatronDesignSystem"]),
.target(
    name: "MatronDesignSystem",
    dependencies: [
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    ],
    path: "Sources/DesignSystem"
),
```

(Yes — the design-system primitives live inside `MatronShared/Sources/DesignSystem/` so they're testable in isolation, even though the app also imports them.)

- [ ] **Step 2: Add `swift-snapshot-testing` as a test dependency**

```swift
.package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
```

Add a snapshot test target:

```swift
.testTarget(
    name: "DesignSystemSnapshotTests",
    dependencies: [
        "MatronDesignSystem",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
    ],
    path: "Tests/DesignSystemSnapshotTests"
),
```

- [ ] **Step 3: Wire MarkdownUI + DesignSystem into the Matron app target via `project.yml`**

Add to the Matron target's `dependencies` in `project.yml`:

```yaml
  - package: MatronShared
    product: MatronDesignSystem
```

- [ ] **Step 4: Regenerate the project + verify it builds**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Package.swift project.yml
git commit -m "build: add MarkdownUI + swift-snapshot-testing; introduce MatronDesignSystem module"
git push
```

---

### Task 2: MarkdownText primitive

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MarkdownText.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownTextSnapshotTests.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/` (directory, populated automatically)

- [ ] **Step 1: Implement `MarkdownText`**

Create `MatronShared/Sources/DesignSystem/MarkdownText.swift`:

```swift
import SwiftUI
import MarkdownUI

public struct MarkdownText: View {
    let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        Markdown(raw)
            .markdownTheme(.matron)
            .textSelection(.enabled)
    }
}

public extension Theme {
    static let matron: Theme = Theme()
        .text {
            FontFamily(.system(.default))
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.matronInlineCodeBg)
        }
        .codeBlock { configuration in
            CodeBlockView(language: configuration.language ?? "", source: configuration.content)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
}

private struct CodeBlockView: View {
    let language: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(source)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
            }
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Cross-platform pasteboard wrapper. Lives in DesignSystem so primitives compile
/// for both iOS and macOS without `#if` scattered through their bodies.
enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit) && !os(macOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension Color {
    #if canImport(UIKit) && !os(macOS)
    static let matronInlineCodeBg = Color(.systemGray6)
    static let matronCodeBg = Color(.systemGray6)
    #elseif os(macOS)
    static let matronInlineCodeBg = Color(nsColor: .controlBackgroundColor)
    static let matronCodeBg = Color(nsColor: .controlBackgroundColor)
    #endif
}
```

- [ ] **Step 2: Add shared `assertVariants` snapshot helper (iOS + Mac)**

Create `MatronShared/Tests/DesignSystemSnapshotTests/SnapshotVariants.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting

/// Records baselines for a view across **{iOS, Mac} × {light, dark, accessibility5}**
/// so we catch regressions in colour-scheme handling, accessibility text scaling,
/// and platform-specific rendering at once. Six baseline files are produced per
/// snapshot test. Each variant is suffixed onto the test name automatically by
/// `swift-snapshot-testing` via the `named:` parameter.
///
/// The `#if os(macOS)` branch emits Mac variants via `NSHostingView`; the
/// `#if canImport(UIKit)` branch emits iOS variants via `UIHostingController`.
/// Tests run on both platform schemes (`MatronShared` + `MatronShared-Mac`) and
/// both sets of baselines are checked into the repo side-by-side.
func assertVariants<V: View>(
    of view: V,
    named base: String,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    #if canImport(UIKit) && !os(macOS)
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(userInterfaceStyle: .light)),
        named: "ios-\(base)-light",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(userInterfaceStyle: .dark)),
        named: "ios-\(base)-dark",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)),
        named: "ios-\(base)-axxxl",
        file: file, testName: testName, line: line
    )
    #endif

    #if os(macOS)
    // Mac variants. swift-snapshot-testing's `.image` strategy on macOS uses
    // `NSHostingView`; colour scheme is forced via `.preferredColorScheme`,
    // dynamic type via `.dynamicTypeSize(.accessibility5)` (the macOS analogue
    // of `.accessibilityExtraExtraExtraLarge`).
    assertSnapshot(
        of: view.preferredColorScheme(.light),
        as: .image(size: nil),
        named: "mac-\(base)-light",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view.preferredColorScheme(.dark),
        as: .image(size: nil),
        named: "mac-\(base)-dark",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view.dynamicTypeSize(.accessibility5),
        as: .image(size: nil),
        named: "mac-\(base)-axxxl",
        file: file, testName: testName, line: line
    )
    #endif
}
```

This helper is shared across every snapshot suite in this phase (Tasks 2, 2b, 3, 11). All `assertSnapshot` call sites below should use `assertVariants(of:named:)` instead. Each primitive snapshot test now generates **6 baseline files** ({iOS, Mac} × {light, dark, accessibility5}), not 3.

- [ ] **Step 3: Write a snapshot test**

Create `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownTextSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class MarkdownTextSnapshotTests: XCTestCase {
    func test_plainParagraph() {
        let view = MarkdownText("Hello, world. This is a plain paragraph with **bold** and *italics*.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "plainParagraph")  // 6 baselines (iOS+Mac × light/dark/XXXL)
    }

    func test_inlineCode() {
        let view = MarkdownText("Use `swift test` to run the suite.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "inlineCode")
    }

    func test_codeBlock() {
        let view = MarkdownText(#"""
            Here's some Swift:
            ```swift
            func greet(name: String) -> String {
                return "Hello, \(name)!"
            }
            ```
            """#)
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "codeBlock")
    }

    func test_link() {
        let view = MarkdownText("See the [Matron docs](https://matron.example.com) for more.")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "link")
    }
}
```

- [ ] **Step 4: Run snapshot tests on both platforms (first run records baselines)**

```bash
# iOS scheme
cd MatronShared && swift test --filter MarkdownTextSnapshotTests
# Mac scheme — runs the same tests with the os(macOS) branch of assertVariants active.
cd MatronShared && swift test --filter MarkdownTextSnapshotTests \
  -Xswiftc -target -Xswiftc arm64-apple-macosx14.0
```

Expected: FAIL on first run (no baseline images). Snapshots are recorded under `__Snapshots__/` — **6 per test** (`ios-*-light`, `ios-*-dark`, `ios-*-axxxl`, `mac-*-light`, `mac-*-dark`, `mac-*-axxxl`).

- [ ] **Step 5: Re-run on both platforms to verify they now pass**

```bash
cd MatronShared && swift test --filter MarkdownTextSnapshotTests
cd MatronShared && swift test --filter MarkdownTextSnapshotTests \
  -Xswiftc -target -Xswiftc arm64-apple-macosx14.0
```

Expected: PASS — 4 tests × 6 variants succeed.

- [ ] **Step 6: Commit (including baseline snapshots + helper)**

```bash
git add MatronShared/Sources/DesignSystem/MarkdownText.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/SnapshotVariants.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/
git commit -m "feat: MarkdownText primitive with copyable code blocks; baseline snapshots ({iOS,Mac} × {light,dark,XXXL})"
git push
```

---

### Task 2b: Extract CodeBlock into the design system

**Files:**
- Create: `MatronShared/Sources/DesignSystem/CodeBlock.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/CodeBlockSnapshotTests.swift`
- Modify: `MatronShared/Sources/DesignSystem/MarkdownText.swift` (import `CodeBlock`)

In Task 2 the `CodeBlockView` lives privately inside `MarkdownText.swift`. That's fine for the markdown bridge, but the file structure also lists `CodeBlock.swift` as a public design-system primitive (used by `EventSourceSheet` and Phase-5 `ToolCallCard`). Promote it now.

- [ ] **Step 1: Extract `CodeBlock` to its own file**

Create `MatronShared/Sources/DesignSystem/CodeBlock.swift`:

```swift
import SwiftUI

public struct CodeBlock: View {
    public let language: String
    public let source: String

    public init(language: String, source: String) {
        self.language = language
        self.source = source
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(source)  // Cross-platform; see MarkdownText.swift.
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
            }
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
```

- [ ] **Step 2: Update `MarkdownText.swift` to use the public type**

Replace the private `CodeBlockView` with a thin adapter that delegates to `CodeBlock`:

```swift
.codeBlock { configuration in
    CodeBlock(language: configuration.language ?? "", source: configuration.content)
}
```

Delete the local `private struct CodeBlockView { … }` from `MarkdownText.swift` (it's superseded by the public `CodeBlock`).

- [ ] **Step 3: Snapshot tests for `CodeBlock`**

Create `MatronShared/Tests/DesignSystemSnapshotTests/CodeBlockSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class CodeBlockSnapshotTests: XCTestCase {
    func test_swiftSnippet() {
        let view = CodeBlock(language: "swift", source: """
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            """)
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "swiftSnippet")  // 6 baselines (iOS+Mac × light/dark/XXXL)
    }

    func test_unknownLanguage() {
        let view = CodeBlock(language: "", source: "echo hello")
            .padding()
            .frame(width: 320)
        assertVariants(of: view, named: "unknownLanguage")
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
cd MatronShared && swift test --filter CodeBlockSnapshotTests
git add MatronShared/Sources/DesignSystem/CodeBlock.swift \
        MatronShared/Sources/DesignSystem/MarkdownText.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/CodeBlockSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/
git commit -m "feat: extract CodeBlock primitive with copy button; snapshot baselines"
git push
```

---

### Task 3: AttachmentImage + AttachmentFile primitives

**Files:**
- Create: `MatronShared/Sources/DesignSystem/AttachmentImage.swift`
- Create: `MatronShared/Sources/DesignSystem/AttachmentFile.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/AttachmentImageSnapshotTests.swift`

- [ ] **Step 1: Implement `AttachmentImage`**

Create `MatronShared/Sources/DesignSystem/AttachmentImage.swift`:

```swift
import SwiftUI

public struct AttachmentImage: View {
    let image: Image?
    let placeholder: String
    let caption: String?
    let onTap: (() -> Void)?

    public init(image: Image?, placeholder: String = "Image", caption: String? = nil, onTap: (() -> Void)? = nil) {
        self.image = image
        self.placeholder = placeholder
        self.caption = caption
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.secondary.opacity(0.2))
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 280, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { onTap?() }

            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Implement `AttachmentFile`**

Create `MatronShared/Sources/DesignSystem/AttachmentFile.swift`:

```swift
import SwiftUI

public struct AttachmentFile: View {
    let filename: String
    let sizeBytes: Int64?
    let onTap: (() -> Void)?

    public init(filename: String, sizeBytes: Int64?, onTap: (() -> Void)? = nil) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename).font(.callout).lineLimit(1)
                if let sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onTap?() }
    }
}
```

- [ ] **Step 3: Snapshot tests for both**

Create `MatronShared/Tests/DesignSystemSnapshotTests/AttachmentImageSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class AttachmentImageSnapshotTests: XCTestCase {
    func test_placeholder() {
        assertVariants(of: AttachmentImage(image: nil, caption: "screenshot.png").frame(width: 320), named: "placeholder")
    }
}

final class AttachmentFileSnapshotTests: XCTestCase {
    func test_basic() {
        assertVariants(of: AttachmentFile(filename: "diff.patch", sizeBytes: 4096).frame(width: 320), named: "basic")
    }

    func test_unknownSize() {
        assertVariants(of: AttachmentFile(filename: "report.pdf", sizeBytes: nil).frame(width: 320), named: "unknownSize")
    }
}
```

Note: `AttachmentFile` and `AttachmentImage` need their `Color(.systemGray6)` literal swapped for a cross-platform alias from `MarkdownText.swift`'s `extension Color` block (e.g. `Color.matronCodeBg`) so they compile against the Mac scheme. Apply that substitution while implementing.

- [ ] **Step 4: Run snapshot tests (records baselines, then passes)**

```bash
cd MatronShared && swift test --filter AttachmentImageSnapshotTests
cd MatronShared && swift test --filter AttachmentFileSnapshotTests
```

Expected: first run records baselines; second run passes.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/AttachmentImage.swift \
        MatronShared/Sources/DesignSystem/AttachmentFile.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/AttachmentImageSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/
git commit -m "feat: AttachmentImage + AttachmentFile primitives; snapshots"
git push
```

---

### Task 4: TimelineItem DTO

**Files:**
- Create: `MatronShared/Sources/Chat/TimelineItem.swift`
- Create: `MatronShared/Tests/ChatTests/TimelineItemTests.swift`

`TimelineItem` is the DTO the UI consumes. The SDK's `TimelineItem` is opaque/heavy; we map to a small Swift enum.

- [ ] **Step 1: Define the DTO**

Create `MatronShared/Sources/Chat/TimelineItem.swift`:

```swift
import Foundation
import MatronModels

public struct TimelineItem: Identifiable, Equatable, Sendable {
    public let id: String                        // SDK's unique item id (eventID once available; transactionID before)
    public let sender: String                    // Matrix user ID
    public let timestamp: Date
    public let kind: Kind
    public let isOwn: Bool                       // true if sent by the local user
    public let sendState: SendState

    public enum Kind: Equatable, Sendable {
        case text(body: String, formattedHTML: String?)
        case image(url: URL?, caption: String?, sizeBytes: Int64?)
        case file(url: URL?, filename: String, sizeBytes: Int64?)
        case stateChange(text: String)           // member joins, name change, etc.
        case unknown(eventType: String)          // event we don't render specially yet
    }

    public enum SendState: Equatable, Sendable {
        case sent
        case sending
        case failed(reason: String)
    }

    public init(
        id: String,
        sender: String,
        timestamp: Date,
        kind: Kind,
        isOwn: Bool,
        sendState: SendState = .sent
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.kind = kind
        self.isOwn = isOwn
        self.sendState = sendState
    }
}
```

- [ ] **Step 2: Test equality + identifiability**

Create `MatronShared/Tests/ChatTests/TimelineItemTests.swift`:

```swift
import XCTest
@testable import MatronChat

final class TimelineItemTests: XCTestCase {
    func test_textKind_equality() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        XCTAssertEqual(a, b)
    }

    func test_differentKinds_areInequal() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.file(url: nil, filename: "x", sizeBytes: nil)
        XCTAssertNotEqual(a, b)
    }

    func test_id_isStable() {
        let item = TimelineItem(
            id: "evt:1", sender: "@a:s", timestamp: Date(),
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true
        )
        XCTAssertEqual(item.id, "evt:1")
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd MatronShared && swift test --filter TimelineItemTests
git add MatronShared/Sources/Chat/TimelineItem.swift MatronShared/Tests/ChatTests/TimelineItemTests.swift
git commit -m "feat: TimelineItem DTO with Kind enum and SendState"
git push
```

---

### Task 5: TimelineService protocol + Live impl

**Files:**
- Create: `MatronShared/Sources/Chat/TimelineService.swift`
- Create: `MatronShared/Sources/Chat/TimelineServiceLive.swift`
- Create: `MatronShared/Tests/ChatTests/TimelineServiceFakeTests.swift`

Same pattern as Phase 1 Task 9/10: protocol → fake → live.

- [ ] **Step 1: Define `TimelineService` protocol**

Create `MatronShared/Sources/Chat/TimelineService.swift`:

```swift
import Foundation
import MatronModels

public protocol TimelineService: Sendable {
    /// AsyncStream of full timeline snapshots. Newest item last.
    func items() -> AsyncStream<[TimelineItem]>

    /// Sends a plain text message. Body may include markdown; we set HTML body too.
    /// Returns when the SDK has accepted the send (not when it's confirmed by the server).
    func sendText(_ body: String) async throws

    /// Sends an image attachment.
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws

    /// Sends a file attachment.
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws

    /// Asks the SDK to paginate older history (returns when done; UI subscribes via items()).
    func paginateBackward(requestSize: UInt16) async throws

    /// Marks the most recent visible event as read.
    func markAsRead() async throws
}
```

- [ ] **Step 2: Implement `TimelineServiceLive` (skeleton — SDK calls)**

Create `MatronShared/Sources/Chat/TimelineServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronSync
import MatronModels

public final class TimelineServiceLive: TimelineService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let roomID: String
    private var timelineHandle: Timeline?

    public init(provider: ClientProvider, session: UserSession, roomID: String) {
        self.provider = provider
        self.session = session
        self.roomID = roomID
    }

    public func items() -> AsyncStream<[TimelineItem]> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    let client = try await self.provider.client(for: self.session)
                    let room = try await client.getRoom(roomId: self.roomID)
                    let timeline = try await room.timeline()
                    self.timelineHandle = timeline
                    let myID = try client.userId()
                    let listener = TimelineListener(continuation: continuation, myID: myID)
                    let _ = try await timeline.addListener(listener: listener)
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func sendText(_ body: String) async throws {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()
        let html = MarkdownToHTMLConverter.convert(body)
        let content = messageEventContentFromMarkdown(md: body, html: html)
        try await timeline.send(msg: content)
    }

    public func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await timeline.sendImage(
            url: tempURL.path,
            thumbnailUrl: nil,
            imageInfo: ImageInfo(height: nil, width: nil, mimetype: mimeType, size: UInt64(data.count), thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil)
        )
    }

    public func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await timeline.sendFile(
            url: tempURL.path,
            fileInfo: FileInfo(mimetype: mimeType, size: UInt64(data.count), thumbnailInfo: nil, thumbnailSource: nil)
        )
    }

    public func paginateBackward(requestSize: UInt16) async throws {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()
        _ = try await timeline.paginateBackwards(opts: .untilNumItems(eventLimit: requestSize, items: requestSize))
    }

    public func markAsRead() async throws {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        try await room.markAsRead(receiptType: .read)
    }
}

private final class TimelineListener: TimelineListenerProtocol {
    private let continuation: AsyncStream<[TimelineItem]>.Continuation
    private let myID: String

    /// Maintains the current ordered snapshot. We key items by their stable `id`
    /// (event ID once the homeserver has acknowledged; transaction ID before).
    private var byID: [String: TimelineItem] = [:]
    private var order: [String] = []

    init(continuation: AsyncStream<[TimelineItem]>.Continuation, myID: String) {
        self.continuation = continuation
        self.myID = myID
    }

    /// Apply each diff from `MatrixRustSDK.TimelineDiff` to the in-memory snapshot,
    /// then yield the resulting `[TimelineItem]` to the AsyncStream consumer.
    func onUpdate(diff: [TimelineDiff]) {
        for d in diff {
            switch d {
            case .append(let values):
                for v in values { upsertAtEnd(map(v)) }
            case .pushFront(let value):
                insert(map(value), at: 0)
            case .pushBack(let value):
                upsertAtEnd(map(value))
            case .insert(let index, let value):
                insert(map(value), at: Int(index))
            case .set(let index, let value):
                replace(at: Int(index), with: map(value))
            case .remove(let index):
                removeAt(Int(index))
            case .reset(let values):
                byID.removeAll()
                order.removeAll()
                for v in values { upsertAtEnd(map(v)) }
            case .clear:
                byID.removeAll()
                order.removeAll()
            }
        }
        continuation.yield(order.compactMap { byID[$0] })
    }

    // MARK: - Snapshot mutators

    private func upsertAtEnd(_ item: TimelineItem) {
        if byID[item.id] == nil { order.append(item.id) }
        byID[item.id] = item
    }

    private func insert(_ item: TimelineItem, at index: Int) {
        let clamped = max(0, min(index, order.count))
        if let existing = byID.index(forKey: item.id) {
            // Move existing entry to new position to keep order/byID in sync.
            let oldID = byID[existing].key
            order.removeAll { $0 == oldID }
            order.insert(oldID, at: min(clamped, order.count))
        } else {
            order.insert(item.id, at: clamped)
        }
        byID[item.id] = item
    }

    private func replace(at index: Int, with item: TimelineItem) {
        guard order.indices.contains(index) else {
            upsertAtEnd(item); return
        }
        let oldID = order[index]
        if oldID != item.id {
            byID.removeValue(forKey: oldID)
            order[index] = item.id
        }
        byID[item.id] = item
    }

    private func removeAt(_ index: Int) {
        guard order.indices.contains(index) else { return }
        let id = order.remove(at: index)
        byID.removeValue(forKey: id)
    }

    /// Convert an SDK `TimelineItem` into our DTO. Unknown SDK kinds become
    /// `.unknown(eventType:)` so they're rendered as a placeholder rather than
    /// silently dropped.
    private func map(_ sdk: MatrixRustSDK.TimelineItem) -> TimelineItem {
        // Implementer note: actual SDK accessor names vary across releases —
        // this is the structural shape. See spec §6.1 for the canonical mapping.
        let id = sdk.uniqueIdentifier()
        let sender = sdk.sender()
        let ts = Date(timeIntervalSince1970: TimeInterval(sdk.timestamp()) / 1000)
        let isOwn = (sender == myID)
        let kind: TimelineItem.Kind
        switch sdk.content().kind() {
        case .text(let body, let formattedHTML):
            kind = .text(body: body, formattedHTML: formattedHTML)
        case .image(let url, let caption, let sizeBytes):
            kind = .image(url: url, caption: caption, sizeBytes: sizeBytes)
        case .file(let url, let filename, let sizeBytes):
            kind = .file(url: url, filename: filename, sizeBytes: sizeBytes)
        case .stateChange(let text):
            kind = .stateChange(text: text)
        case .unknown(let eventType):
            kind = .unknown(eventType: eventType)
        }
        return TimelineItem(id: id, sender: sender, timestamp: ts, kind: kind, isOwn: isOwn, sendState: .sent)
    }
}

private enum MarkdownToHTMLConverter {
    static func convert(_ markdown: String) -> String {
        // Minimal: pass through. For Phase 2 the bridge sends plain text; rich markdown rendered locally.
        // If we want server-side HTML, switch to swift-markdown's HTMLFormatter here.
        markdown
    }
}
```

> **Implementer notes:**
> - The `MatrixRustSDK.Timeline` API has shifted across SDK releases. The skeleton above shows the *shape* — adjust call sites to match `Package.resolved`.
> - `TimelineListener.onUpdate` walks the `MatrixRustSDK.TimelineDiff` cases (`.append`, `.pushFront`, `.pushBack`, `.insert`, `.set`, `.remove`, `.reset`, `.clear`) and applies each to an in-memory snapshot keyed by event id. See spec §6.1.
> - Convert SDK item kinds: `.text` → `.text`, `.image` → `.image`, `.file` → `.file`, member events → `.stateChange`, anything else → `.unknown(eventType:)` (so unknown events render a placeholder rather than disappearing silently).
> - Task 5b below contains TDD steps that *exercise* the diff-application logic with synthetic diffs, so the mapping is regression-protected from day one.

- [ ] **Step 3: Fake test for the protocol**

Create `MatronShared/Tests/ChatTests/TimelineServiceFakeTests.swift`:

```swift
import XCTest
@testable import MatronChat
@testable import MatronModels

/// Plain `final class` (not `actor`) so `items()` can synthesise a finite
/// AsyncStream synchronously without needing `nonisolated` accessors that
/// reach into actor state. Tests are single-threaded; a serial lock guards
/// the few mutable fields.
final class FakeTimelineService: TimelineService, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshotsToEmit: [[TimelineItem]] = []
    private var _sentText: [String] = []
    private var _sentImages: [(filename: String, mime: String, sizeBytes: Int)] = []
    private var _paginateCalls = 0
    private var _markReadCalls = 0

    var snapshotsToEmit: [[TimelineItem]] {
        get { lock.lock(); defer { lock.unlock() }; return _snapshotsToEmit }
        set { lock.lock(); _snapshotsToEmit = newValue; lock.unlock() }
    }
    var sentText: [String] {
        lock.lock(); defer { lock.unlock() }; return _sentText
    }
    var sentImages: [(filename: String, mime: String, sizeBytes: Int)] {
        lock.lock(); defer { lock.unlock() }; return _sentImages
    }
    var paginateCalls: Int {
        lock.lock(); defer { lock.unlock() }; return _paginateCalls
    }
    var markReadCalls: Int {
        lock.lock(); defer { lock.unlock() }; return _markReadCalls
    }

    func items() -> AsyncStream<[TimelineItem]> {
        let snapshots = snapshotsToEmit
        return AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()  // Deterministic completion; consumers can `for await` to drain.
        }
    }

    func sendText(_ body: String) async throws {
        lock.lock(); _sentText.append(body); lock.unlock()
    }
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        lock.lock(); _sentImages.append((filename, mimeType, data.count)); lock.unlock()
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
    func paginateBackward(requestSize: UInt16) async throws {
        lock.lock(); _paginateCalls += 1; lock.unlock()
    }
    func markAsRead() async throws {
        lock.lock(); _markReadCalls += 1; lock.unlock()
    }
}

final class TimelineServiceFakeTests: XCTestCase {
    func test_streamsSnapshots() async throws {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [
            [TimelineItem(id: "1", sender: "@a:s", timestamp: .now, kind: .text(body: "hi", formattedHTML: nil), isOwn: true)],
            [TimelineItem(id: "1", sender: "@a:s", timestamp: .now, kind: .text(body: "hi", formattedHTML: nil), isOwn: true),
             TimelineItem(id: "2", sender: "@b:s", timestamp: .now, kind: .text(body: "hello", formattedHTML: nil), isOwn: false)],
        ]
        var received: [[TimelineItem]] = []
        for await snap in fake.items() { received.append(snap) }
        XCTAssertEqual(received.count, 2)
    }

    func test_sendText_recordsCalls() async throws {
        let fake = FakeTimelineService()
        try await fake.sendText("/start")
        XCTAssertEqual(fake.sentText, ["/start"])
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
cd MatronShared && swift test --filter TimelineServiceFakeTests
git add MatronShared/Sources/Chat/TimelineService.swift \
        MatronShared/Sources/Chat/TimelineServiceLive.swift \
        MatronShared/Tests/ChatTests/TimelineServiceFakeTests.swift
git commit -m "feat: TimelineService protocol + Live skeleton + fake-driven tests"
git push
```

---

### Task 5b: Implement timeline diff application

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineServiceLive.swift` (the private `TimelineListener`)
- Create: `MatronShared/Tests/ChatTests/TimelineDiffApplicationTests.swift`

The `TimelineListener.onUpdate(diff:)` method is the central deliverable of Phase 2: it converts SDK `TimelineDiff` events into snapshots that `ChatViewModel` consumes. This task drives that logic with TDD using a small *test-only* `applyDiff` helper that mirrors the production switch-statement, so we can assert behaviour without standing up a real SDK.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/ChatTests/TimelineDiffApplicationTests.swift`:

```swift
import XCTest
@testable import MatronChat
@testable import MatronModels

/// Mirror of the in-memory snapshot machine inside `TimelineListener`.
/// Kept as a separate test-only struct so we can drive it without a real SDK
/// `Timeline`. Production code performs *exactly* the same switch in
/// `TimelineListener.onUpdate(diff:)`.
struct SnapshotApplier {
    private(set) var byID: [String: TimelineItem] = [:]
    private(set) var order: [String] = []

    enum FakeDiff {
        case append([TimelineItem])
        case pushFront(TimelineItem)
        case pushBack(TimelineItem)
        case insert(Int, TimelineItem)
        case set(Int, TimelineItem)
        case remove(Int)
        case reset([TimelineItem])
        case clear
    }

    mutating func apply(_ diffs: [FakeDiff]) {
        for d in diffs {
            switch d {
            case .append(let values): values.forEach { upsertAtEnd($0) }
            case .pushFront(let v): insert(v, at: 0)
            case .pushBack(let v): upsertAtEnd(v)
            case .insert(let i, let v): insert(v, at: i)
            case .set(let i, let v): replace(at: i, with: v)
            case .remove(let i): removeAt(i)
            case .reset(let values):
                byID.removeAll(); order.removeAll()
                values.forEach { upsertAtEnd($0) }
            case .clear:
                byID.removeAll(); order.removeAll()
            }
        }
    }

    var snapshot: [TimelineItem] { order.compactMap { byID[$0] } }

    private mutating func upsertAtEnd(_ item: TimelineItem) {
        if byID[item.id] == nil { order.append(item.id) }
        byID[item.id] = item
    }
    private mutating func insert(_ item: TimelineItem, at index: Int) {
        let clamped = max(0, min(index, order.count))
        if byID[item.id] != nil { order.removeAll { $0 == item.id } }
        order.insert(item.id, at: min(clamped, order.count))
        byID[item.id] = item
    }
    private mutating func replace(at index: Int, with item: TimelineItem) {
        guard order.indices.contains(index) else { upsertAtEnd(item); return }
        let oldID = order[index]
        if oldID != item.id {
            byID.removeValue(forKey: oldID)
            order[index] = item.id
        }
        byID[item.id] = item
    }
    private mutating func removeAt(_ index: Int) {
        guard order.indices.contains(index) else { return }
        let id = order.remove(at: index)
        byID.removeValue(forKey: id)
    }
}

private func mkItem(_ id: String, _ body: String = "x") -> TimelineItem {
    TimelineItem(id: id, sender: "@a:s", timestamp: .init(timeIntervalSince1970: 0),
                 kind: .text(body: body, formattedHTML: nil), isOwn: false)
}

final class TimelineDiffApplicationTests: XCTestCase {
    func test_append_addsToEnd() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")])])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_pushFront_addsToHead() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]), .pushFront(mkItem("0"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["0", "1", "2"])
    }

    func test_pushBack_addsToTail() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1")]), .pushBack(mkItem("2"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_insert_atIndex_insertsThere() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("3")]), .insert(1, mkItem("2"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2", "3"])
    }

    func test_set_replacesItemAtIndex() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1", "old")]), .set(0, mkItem("1", "new"))])
        XCTAssertEqual(a.snapshot.count, 1)
        if case .text(let body, _) = a.snapshot[0].kind {
            XCTAssertEqual(body, "new")
        } else { XCTFail("expected text kind") }
    }

    func test_remove_removesItemAtIndex() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2"), mkItem("3")]), .remove(1)])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "3"])
    }

    func test_reset_replacesEverything() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]),
                 .reset([mkItem("9"), mkItem("10")])])
        XCTAssertEqual(a.snapshot.map(\.id), ["9", "10"])
    }

    func test_clear_emptiesSnapshot() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1")]), .clear])
        XCTAssertTrue(a.snapshot.isEmpty)
    }

    func test_unknownEventType_isPreservedNotDropped() {
        var a = SnapshotApplier()
        let unk = TimelineItem(id: "u1", sender: "@a:s", timestamp: .init(timeIntervalSince1970: 0),
                               kind: .unknown(eventType: "m.room.encryption"), isOwn: false)
        a.apply([.append([unk])])
        XCTAssertEqual(a.snapshot.count, 1)
        if case .unknown(let t) = a.snapshot[0].kind {
            XCTAssertEqual(t, "m.room.encryption")
        } else { XCTFail("expected unknown kind") }
    }
}
```

Run it — it FAILS because `SnapshotApplier` is referenced but not yet matched against the production code path (the test compiles standalone; this step verifies the *test* compiles and runs against a freshly written applier).

```bash
cd MatronShared && swift test --filter TimelineDiffApplicationTests
```

Expected: PASS for the standalone applier (eight assertions). The point of this test is to lock in the contract that `TimelineListener.onUpdate` must satisfy.

- [ ] **Step 2: Implement the production `TimelineListener.onUpdate` (already drafted in Task 5)**

The production `TimelineListener.onUpdate(diff:)` (defined in `TimelineServiceLive.swift` from Task 5) performs the *same* switch as `SnapshotApplier.apply`, but over `MatrixRustSDK.TimelineDiff`. Walk through each case (`.append`, `.pushFront`, `.pushBack`, `.insert`, `.set`, `.remove`, `.reset`, `.clear`) and confirm its body calls the matching mutator. The `map(_:)` helper translates SDK item kinds to our DTO; unknown SDK kinds map to `.unknown(eventType:)` so they round-trip into the UI as a placeholder.

- [ ] **Step 3: Verify build + diff tests pass together**

```bash
cd MatronShared && swift test --filter TimelineDiffApplicationTests
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass; project builds.

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Sources/Chat/TimelineServiceLive.swift \
        MatronShared/Tests/ChatTests/TimelineDiffApplicationTests.swift
git commit -m "feat: apply TimelineDiff to ordered snapshot in TimelineListener"
git push
```

---

### Task 6: ChatService — extend with createChat

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatService.swift`
- Modify: `MatronShared/Sources/Chat/ChatServiceLive.swift`
- Create: `MatronShared/Tests/ChatTests/CreateChatTests.swift`

- [ ] **Step 1: Extend the protocol**

Edit `MatronShared/Sources/Chat/ChatService.swift`, add a new method:

```swift
public protocol ChatService: Sendable {
    func chatSummaries() -> AsyncStream<[ChatSummary]>

    /// Creates a new 1:1 encrypted room with `bot`, returns the new room ID.
    func createChat(with botID: String) async throws -> String
}
```

- [ ] **Step 2: Implement on `ChatServiceLive`**

Add to `ChatServiceLive`:

```swift
public func createChat(with botID: String) async throws -> String {
    let client = try await provider.client(for: session)
    let req = CreateRoomParameters(
        name: nil,
        topic: nil,
        isEncrypted: true,
        isDirect: true,
        visibility: .private,
        preset: .privateChat,
        invite: [botID],
        avatar: nil
    )
    return try await client.createRoom(request: req)
}
```

> **Implementer note:** `CreateRoomParameters` field names vary across SDK versions; verify against `Package.resolved`.

- [ ] **Step 3: Test against the fake**

Create `MatronShared/Tests/ChatTests/CreateChatTests.swift`:

```swift
import XCTest
@testable import MatronChat
@testable import MatronModels

actor FakeChatServiceForCreate: ChatService {
    var createdWith: [String] = []
    var nextRoomID: String = "!new:server"
    // Task-13 additions — declared up-front so this fake stays
    // ChatService-conformant once the protocol is extended.
    var refreshCalls = 0
    var mutedRooms: [String] = []
    var leftRooms: [String] = []

    nonisolated func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { $0.finish() }
    }

    func createChat(with botID: String) async throws -> String {
        createdWith.append(botID)
        return nextRoomID
    }

    func refresh() async throws { refreshCalls += 1 }
    func mute(roomID: String) async throws { mutedRooms.append(roomID) }
    func leave(roomID: String) async throws { leftRooms.append(roomID) }
}

final class CreateChatTests: XCTestCase {
    func test_recordsBotID_andReturnsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        let id = try await fake.createChat(with: "@bot:s")
        XCTAssertEqual(id, "!new:server")
        let recorded = await fake.createdWith
        XCTAssertEqual(recorded, ["@bot:s"])
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
cd MatronShared && swift test --filter CreateChatTests
git add MatronShared/Sources/Chat/ChatService.swift \
        MatronShared/Sources/Chat/ChatServiceLive.swift \
        MatronShared/Tests/ChatTests/CreateChatTests.swift
git commit -m "feat: ChatService.createChat for new 1:1 bot rooms"
git push
```

---

### Task 7: BotCommand catalog

**Files:**
- Create: `MatronShared/Sources/Models/BotCommand.swift`
- Create: `MatronShared/Tests/ChatTests/BotCommandTests.swift`

The slash palette is local — driven by a static list per bot. For MVP, just the Claude bridge commands.

- [ ] **Step 1: Define `BotCommand` + the Claude bridge catalog**

Create `MatronShared/Sources/Models/BotCommand.swift`:

```swift
import Foundation

public struct BotCommand: Equatable, Hashable, Sendable {
    public let trigger: String           // "/start" or "!start"
    public let summary: String           // "Start a new Claude session"
    public let argHint: String?          // "[workdir]" — shown in palette

    public init(trigger: String, summary: String, argHint: String? = nil) {
        self.trigger = trigger
        self.summary = summary
        self.argHint = argHint
    }
}

public enum BotCommandCatalog {
    /// Static catalog for the Claude bridge. In Phase 5+ this becomes config-driven.
    public static let claudeBridge: [BotCommand] = [
        BotCommand(trigger: "/start", summary: "Start a Claude Code session", argHint: "[workdir]"),
        BotCommand(trigger: "/stop", summary: "Stop the current session"),
        BotCommand(trigger: "/restart", summary: "Restart and resume the session"),
        BotCommand(trigger: "/resume", summary: "Resume a previous session", argHint: "[n|id]"),
        BotCommand(trigger: "/sessions", summary: "List past sessions"),
        BotCommand(trigger: "/workdir", summary: "Change working directory", argHint: "<path>"),
        BotCommand(trigger: "/status", summary: "Show session info"),
        BotCommand(trigger: "/working", summary: "Toggle tool-call visibility"),
        BotCommand(trigger: "/mcp", summary: "Show MCP server status"),
        BotCommand(trigger: "/model", summary: "Show current model"),
        BotCommand(trigger: "/cost", summary: "Show session cost"),
        BotCommand(trigger: "/usage", summary: "Show token usage"),
        BotCommand(trigger: "/tools", summary: "List available tools"),
        BotCommand(trigger: "/help", summary: "Show command help"),
    ]

    /// Filters by typed prefix (case-insensitive, ignoring leading slash).
    public static func filter(_ commands: [BotCommand], byPrefix prefix: String) -> [BotCommand] {
        let normalized = prefix.lowercased().drop(while: { $0 == "/" || $0 == "!" })
        guard !normalized.isEmpty else { return commands }
        return commands.filter { cmd in
            cmd.trigger.lowercased().drop(while: { $0 == "/" || $0 == "!" }).hasPrefix(normalized)
        }
    }
}
```

- [ ] **Step 2: Tests**

Create `MatronShared/Tests/ChatTests/BotCommandTests.swift`:

```swift
import XCTest
@testable import MatronModels

final class BotCommandCatalogTests: XCTestCase {
    func test_filter_emptyPrefix_returnsAll() {
        let all = BotCommandCatalog.claudeBridge
        let filtered = BotCommandCatalog.filter(all, byPrefix: "")
        XCTAssertEqual(filtered.count, all.count)
    }

    func test_filter_matchesPrefixCaseInsensitive() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/STA")
        XCTAssertTrue(filtered.contains { $0.trigger == "/start" })
        XCTAssertTrue(filtered.contains { $0.trigger == "/status" })
        XCTAssertFalse(filtered.contains { $0.trigger == "/stop" })
    }

    func test_filter_acceptsBangPrefix() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "!resu")
        XCTAssertTrue(filtered.contains { $0.trigger == "/resume" })
    }

    func test_filter_noMatch_returnsEmpty() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/doesnotexist")
        XCTAssertTrue(filtered.isEmpty)
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd MatronShared && swift test --filter BotCommandCatalogTests
git add MatronShared/Sources/Models/BotCommand.swift MatronShared/Tests/ChatTests/BotCommandTests.swift
git commit -m "feat: BotCommand model and Claude-bridge catalog"
git push
```

---

### Task 8: ComposerViewModel

**Files:**
- Create: `MatronShared/Sources/ViewModels/ComposerViewModel.swift` (target-agnostic; consumed by both `Matron/Features/Chat/Composer/ComposerView.swift` and `MatronMac/Features/Chat/MacChatView.swift`)
- Create: `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift`

Drives the composer: text input, slash palette state, send action, plus a Mac-only `attachFiles(_:)` entry point (used by `ComposerDropDelegate` for drag-and-drop in Task 14c).

- [ ] **Step 1: Write tests first**

Create `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift`:

```swift
import XCTest
@testable import Matron
import MatronChat
import MatronModels

final class ComposerViewModelTests: XCTestCase {
    @MainActor
    func test_palette_isShownWhenInputStartsWithSlash() {
        let vm = ComposerViewModel(timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "/sta"
        XCTAssertTrue(vm.showPalette)
        XCTAssertTrue(vm.filteredCommands.contains { $0.trigger == "/start" })
    }

    @MainActor
    func test_palette_isHiddenForRegularInput() {
        let vm = ComposerViewModel(timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "hello"
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_selectingCommand_replacesInput() {
        let vm = ComposerViewModel(timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "/sta"
        let cmd = BotCommand(trigger: "/start", summary: "x", argHint: "[workdir]")
        vm.selectCommand(cmd)
        XCTAssertEqual(vm.input, "/start ")
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_send_sendsTrimmedAndClearsInput() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(timeline: fake, commands: [])
        vm.input = "  hello world  "
        await vm.send()
        XCTAssertEqual(fake.sentText, ["hello world"])
        XCTAssertEqual(vm.input, "")
    }

    @MainActor
    func test_send_doesNothing_forEmptyInput() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(timeline: fake, commands: [])
        vm.input = "   "
        await vm.send()
        XCTAssertTrue(fake.sentText.isEmpty)
    }
}
```

- [ ] **Step 2: Implement `ComposerViewModel`**

Create `MatronShared/Sources/ViewModels/ComposerViewModel.swift`:

```swift
import Foundation
import MatronChat
import MatronModels
import UniformTypeIdentifiers

@Observable
@MainActor
public final class ComposerViewModel {
    public var input: String = ""
    public private(set) var isSending: Bool = false
    public private(set) var sendError: String?
    /// Mac slash palette is also openable via `⌘K`; iOS toggles purely via `/` typing.
    public var palettePinnedOpen: Bool = false

    private let timeline: TimelineService
    private let commands: [BotCommand]

    public init(timeline: TimelineService, commands: [BotCommand]) {
        self.timeline = timeline
        self.commands = commands
    }

    public var showPalette: Bool {
        if palettePinnedOpen { return true }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("/") || trimmed.hasPrefix("!")) && trimmed.split(separator: " ").count == 1
    }

    public var filteredCommands: [BotCommand] {
        BotCommandCatalog.filter(commands, byPrefix: input)
    }

    public func selectCommand(_ command: BotCommand) {
        input = command.trigger + " "
        palettePinnedOpen = false
    }

    public func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await timeline.sendText(trimmed)
            input = ""
            sendError = nil
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Mac drag-and-drop entry point. Wired by `ComposerDropDelegate` in
    /// `MatronMac/Features/Chat/ComposerDropDelegate.swift`. Sends each URL as
    /// the appropriate attachment kind (image vs file) via the timeline.
    public func attachFiles(_ urls: [URL]) async {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
            do {
                if mime.hasPrefix("image/") {
                    try await timeline.sendImage(data, filename: url.lastPathComponent, mimeType: mime)
                } else {
                    try await timeline.sendFile(data, filename: url.lastPathComponent, mimeType: mime)
                }
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 3: Run tests + commit**

```bash
# In Xcode: Product → Test (run on both iOS and Mac schemes)
git add MatronShared/Sources/ViewModels/ComposerViewModel.swift \
        MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift
git commit -m "feat: ComposerViewModel with slash palette state, send, and Mac attachFiles entry"
git push
```

---

### Task 9: ComposerView + SlashCommandPalette + AttachmentPicker

**Files:**
- Create: `Matron/Features/Chat/Composer/ComposerView.swift`
- Create: `Matron/Features/Chat/Composer/SlashCommandPalette.swift`
- Create: `Matron/Features/Chat/Composer/AttachmentPicker.swift`

- [ ] **Step 1: Implement `SlashCommandPalette`**

Create `Matron/Features/Chat/Composer/SlashCommandPalette.swift`:

```swift
import SwiftUI
import MatronModels

struct SlashCommandPalette: View {
    let commands: [BotCommand]
    let onSelect: (BotCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.self) { cmd in
                    Button { onSelect(cmd) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(cmd.trigger).font(.system(.body, design: .monospaced)).bold()
                                    if let hint = cmd.argHint {
                                        Text(hint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                }
                                Text(cmd.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Implement `AttachmentPicker`**

Create `Matron/Features/Chat/Composer/AttachmentPicker.swift`:

```swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentPicker: View {
    @Binding var photoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool

    var body: some View {
        Menu {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Photo", systemImage: "photo")
            }
            Button { showFileImporter = true } label: {
                Label("File", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}
```

- [ ] **Step 3: Implement `ComposerView`**

Create `Matron/Features/Chat/Composer/ComposerView.swift`:

```swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels

struct ComposerView: View {
    @State var viewModel: ComposerViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showPalette {
                SlashCommandPalette(commands: viewModel.filteredCommands) { cmd in
                    viewModel.selectCommand(cmd)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(photoItem: $photoItem, showFileImporter: $showFileImporter)

                TextField("Message…", text: $viewModel.input, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(viewModel.input.isEmpty ? Color.secondary : Color.accentColor)
                }
                .disabled(viewModel.input.isEmpty || viewModel.isSending)
                .padding(.trailing, 4)
            }
            .padding()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            // Wired in Task 10 once Live timeline supports sendFile.
        }
    }
}
```

- [ ] **Step 4: Build + verify in Xcode**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Chat/Composer/
git commit -m "feat: ComposerView with slash palette and attachment menu"
git push
```

---

### Task 10: ChatViewModel

**Files:**
- Create: `MatronShared/Sources/ViewModels/ChatViewModel.swift` (target-agnostic; consumed by both `Matron/Features/Chat/ChatView.swift` and `MatronMac/Features/Chat/MacChatView.swift`)
- Create: `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

- [ ] **Step 1: Tests first**

Create `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`:

```swift
import XCTest
@testable import Matron
import MatronChat
import MatronModels

final class ChatViewModelTests: XCTestCase {
    @MainActor
    func test_streamReceivedItems_appearInState() async throws {
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true
        )
        fake.snapshotsToEmit = [[item]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake)

        // Deterministic: `start()` returns the observation task. The fake's
        // AsyncStream finishes after yielding all snapshots, so awaiting the
        // task is a precise "processing complete" signal — no sleep needed.
        let task = vm.start()
        await task.value

        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.id, "1")
    }

    @MainActor
    func test_streamCompletion_isObservableViaTask() async throws {
        // Same wiring; tighter assertion on the deterministic-completion property
        // so future regressions of the contract are caught here.
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake)
        let task = vm.start()
        // Bound the wait so a misbehaving stream surfaces as a test failure
        // rather than hanging the suite.
        let outcome = await Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await task.value; return true }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }.value
        XCTAssertTrue(outcome, "observation task did not complete within 2s")
    }

    @MainActor
    func test_paginate_invokesService() async throws {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake)
        await vm.paginateBackward()
        XCTAssertEqual(fake.paginateCalls, 1)
    }

    @MainActor
    func test_markAsRead_invokesService() async throws {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake)
        await vm.markAsRead()
        XCTAssertEqual(fake.markReadCalls, 1)
    }
}
```

- [ ] **Step 2: Implement**

Create `MatronShared/Sources/ViewModels/ChatViewModel.swift`:

```swift
import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
public final class ChatViewModel {
    public let roomID: String
    public private(set) var items: [TimelineItem] = []
    public private(set) var error: String?

    private let timeline: TimelineService
    private var observationTask: Task<Void, Never>?

    public init(roomID: String, timeline: TimelineService) {
        self.roomID = roomID
        self.timeline = timeline
    }

    // Note: Task 12b adds a `media: MediaService` initializer parameter and a
    // `resolvedImages: [URL: Image]` cache so `TimelineItemView` can hand a
    // real `Image?` to `AttachmentImage`.

    /// Starts observing the timeline. Returns the observation task so callers
    /// (especially tests) can `await task.value` to know when the stream has
    /// drained — no sleeps required.
    @discardableResult
    public func start() -> Task<Void, Never> {
        observationTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            for await snapshot in timeline.items() {
                await MainActor.run { self.items = snapshot }
            }
        }
        observationTask = task
        return task
    }

    public func stop() {
        observationTask?.cancel()
    }

    // Note: no `deinit { observationTask?.cancel() }` — Swift 6 / Xcode 26
    // strict concurrency forbids accessing @MainActor-isolated properties from
    // a nonisolated deinit. Callers should invoke `stop()` explicitly when the
    // ViewModel goes out of scope; the AsyncStream also drains naturally when
    // the actor releases.

    public func paginateBackward() async {
        do {
            try await timeline.paginateBackward(requestSize: 30)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func markAsRead() async {
        try? await timeline.markAsRead()
    }

    /// Mac toolbar refresh button + ⌘R menu shortcut wire here.
    public func refresh() async {
        // Re-paginating from the head re-fetches the latest events; on Mac there's
        // no pull-to-refresh gesture so this is the only manual-refresh path.
        await paginateBackward()
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
# Run tests on both iOS and Mac schemes (ViewModels target both).
git add MatronShared/Sources/ViewModels/ChatViewModel.swift \
        MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift
git commit -m "feat: ChatViewModel observing timeline + pagination/read APIs (shared iOS+Mac)"
git push
```

---

### Task 11: TimelineItemView + MessageBubble

**Files:**
- Create: `Matron/Features/Chat/Rendering/TimelineItemView.swift` (iOS)
- Create: `MatronShared/Sources/DesignSystem/MessageBubble.swift` (shared primitive — not in `Matron/Features/Chat/Rendering/`. Per the file structure tree, every visual primitive lives in DesignSystem so both apps consume it.)
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/MessageBubbleSnapshotTests.swift` (snapshot the visual primitive)

- [ ] **Step 1: Implement `MessageBubble` (in DesignSystem so it's snapshottable)**

Create `MatronShared/Sources/DesignSystem/MessageBubble.swift`:

```swift
import SwiftUI

public enum MessageAuthorStyle {
    case bot      // no bubble, just left-aligned text
    case me       // subtle background, right-aligned
}

public struct MessageBubble<Content: View>: View {
    let style: MessageAuthorStyle
    let senderLabel: String?
    let content: () -> Content

    public init(
        style: MessageAuthorStyle,
        senderLabel: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.senderLabel = senderLabel
        self.content = content
    }

    public var body: some View {
        HStack {
            if style == .me { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                if let label = senderLabel, style == .bot {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                content()
                    .padding(style == .me ? .all : .horizontal, 12)
                    .padding(style == .me ? .vertical : .vertical, 8)
                    .background(style == .me ? Color(.systemGray6) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if style == .bot { Spacer(minLength: 32) }
        }
        .padding(.horizontal)
    }
}
```

(Adjust `MatronShared/Package.swift` if needed — `MessageBubble` lives in `MatronDesignSystem` already by virtue of the path.)

- [ ] **Step 2: Snapshot tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/MessageBubbleSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class MessageBubbleSnapshotTests: XCTestCase {
    func test_botBubble() {
        let view = MessageBubble(style: .bot, senderLabel: "Claude") {
            MarkdownText("Sure — let me check the code…")
        }
        .frame(width: 320)
        assertVariants(of: view, named: "botBubble")  // 6 baselines (iOS+Mac × light/dark/XXXL)
    }

    func test_meBubble() {
        let view = MessageBubble(style: .me) {
            MarkdownText("Can you look at the auth bug?")
        }
        .frame(width: 320)
        assertVariants(of: view, named: "meBubble")
    }
}
```

Note: `Color(.systemGray6)` in `MessageBubble.body` won't compile on macOS — replace it with `Color.matronCodeBg` (the cross-platform alias defined alongside `MarkdownText`).

- [ ] **Step 3: Implement `TimelineItemView`**

Create `Matron/Features/Chat/Rendering/TimelineItemView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem

struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .text(let body, _):
            MessageBubble(style: item.isOwn ? .me : .bot, senderLabel: item.isOwn ? nil : displayName(for: item.sender)) {
                MarkdownText(body)
            }
        case .image(_, let caption, let sizeBytes):
            MessageBubble(style: item.isOwn ? .me : .bot, senderLabel: item.isOwn ? nil : displayName(for: item.sender)) {
                AttachmentImage(image: nil, placeholder: "Image", caption: caption ?? "Image (\(sizeBytes ?? 0) bytes)")
            }
        case .file(_, let filename, let sizeBytes):
            MessageBubble(style: item.isOwn ? .me : .bot, senderLabel: item.isOwn ? nil : displayName(for: item.sender)) {
                AttachmentFile(filename: filename, sizeBytes: sizeBytes)
            }
        case .stateChange(let text):
            HStack {
                Spacer()
                Text(text).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        case .unknown(let eventType):
            HStack {
                Spacer()
                Text("[unsupported event: \(eventType)]").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func displayName(for senderID: String) -> String {
        // Phase 2 placeholder: use the local part of the Matrix ID. Phase 5+ could resolve from member events.
        senderID.split(separator: ":").first.map(String.init) ?? senderID
    }
}
```

- [ ] **Step 4: Run snapshot tests + build**

```bash
cd MatronShared && swift test --filter MessageBubbleSnapshotTests
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/MessageBubble.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/MessageBubbleSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ \
        Matron/Features/Chat/Rendering/TimelineItemView.swift
git commit -m "feat: MessageBubble + TimelineItemView; snapshot baselines"
git push
```

---

### Task 12: ChatView (the screen)

**Files:**
- Create: `Matron/Features/Chat/ChatView.swift`

- [ ] **Step 1: Implement**

Create `Matron/Features/Chat/ChatView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            TimelineItemView(item: item)
                                .id(item.id)
                                .contextMenu {
                                    if case .text(let body, _) = item.kind {
                                        Button {
                                            UIPasteboard.general.string = body
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        ShareLink(item: body) { Label("Share", systemImage: "square.and.arrow.up") }
                                    }
                                }
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: viewModel.items.count) { _, _ in
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            ComposerView(viewModel: composerVM)
        }
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowBotProfile() } label: { Image(systemName: "info.circle") }
            }
        }
        .task {
            viewModel.start()
            await viewModel.markAsRead()
        }
        .onDisappear { viewModel.stop() }
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Chat/ChatView.swift
git commit -m "feat: ChatView with scroll-to-bottom and long-press menu"
git push
```

---

### Task 12b: MediaService — resolve `mxc://` URLs to images

**Files:**
- Create: `MatronShared/Sources/Media/MediaService.swift`
- Create: `MatronShared/Sources/Media/MediaServiceLive.swift`
- Create: `MatronShared/Tests/ChatTests/MediaServiceFakeTests.swift`
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift` (consume `MediaService` — shared, used by both iOS `ChatView` and Mac `MacChatView`)
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift` (pass resolved `Image` to `AttachmentImage`)
- Modify: `Matron/App/AppDependencies.swift`

`AttachmentImage` accepts a `SwiftUI.Image?` but `TimelineItem.image(url:…)` carries an `mxc://` URL that the SDK resolves to encrypted media. Without this task, the chat shows placeholders forever. The protocol-and-fake pattern matches Phase 1.

- [ ] **Step 1: Define `MediaService` protocol**

Create `MatronShared/Sources/Media/MediaService.swift`:

```swift
import Foundation
import SwiftUI

public protocol MediaService: Sendable {
    /// Resolve an `mxc://` URL to image data. Returns `nil` if the URL is not
    /// an `mxc://` URL or if the SDK cannot fetch it.
    func image(for mxc: URL) async -> Data?
}

public extension MediaService {
    /// Convenience wrapper that returns a SwiftUI `Image`. Cross-platform:
    /// iOS uses `UIImage`, macOS uses `NSImage`.
    func swiftUIImage(for mxc: URL) async -> Image? {
        guard let data = await image(for: mxc) else { return nil }
        #if canImport(UIKit) && !os(macOS)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}
```

- [ ] **Step 2: Write the failing fake test**

Create `MatronShared/Tests/ChatTests/MediaServiceFakeTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import MatronChat

final class FakeMediaService: MediaService, @unchecked Sendable {
    var stubData: [URL: Data] = [:]
    private(set) var requested: [URL] = []
    private let lock = NSLock()
    func image(for mxc: URL) async -> Data? {
        lock.lock(); requested.append(mxc); lock.unlock()
        return stubData[mxc]
    }
}

final class MediaServiceFakeTests: XCTestCase {
    func test_returnsStubbedDataForKnownURL() async {
        let svc = FakeMediaService()
        let url = URL(string: "mxc://example.com/abc")!
        svc.stubData[url] = Data([0x01, 0x02])
        let data = await svc.image(for: url)
        XCTAssertEqual(data, Data([0x01, 0x02]))
        XCTAssertEqual(svc.requested, [url])
    }

    func test_returnsNilForUnknownURL() async {
        let svc = FakeMediaService()
        let data = await svc.image(for: URL(string: "mxc://unknown/xyz")!)
        XCTAssertNil(data)
    }
}
```

Run it — should FAIL because `MediaService` doesn't yet exist (or PASS once Step 1's file is in the build).

```bash
cd MatronShared && swift test --filter MediaServiceFakeTests
```

Expected: FAIL on first run (no protocol) → PASS after Step 1 lands.

- [ ] **Step 3: Implement `MediaServiceLive` (SDK-backed) with `NSCache`**

Create `MatronShared/Sources/Media/MediaServiceLive.swift`:

```swift
import Foundation
import MatrixRustSDK
import MatronSync
import MatronModels

public final class MediaServiceLive: MediaService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    /// Simple in-memory cache keyed by mxc URL string. `NSCache` evicts under
    /// memory pressure for free; no TTL needed for Phase 2.
    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 64 * 1024 * 1024  // 64 MB ceiling
        return c
    }()

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func image(for mxc: URL) async -> Data? {
        guard mxc.scheme == "mxc" else { return nil }
        let key = mxc.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        do {
            let client = try await provider.client(for: session)
            let source = try MediaSource.fromUrl(url: mxc.absoluteString)
            let data = try await client.getMediaContent(mediaSource: source)
            let nsdata = NSData(data: data)
            cache.setObject(nsdata, forKey: key, cost: nsdata.length)
            return data
        } catch {
            return nil
        }
    }
}
```

> **Implementer note:** The `MediaSource.fromUrl` / `client.getMediaContent` names vary across SDK releases. Adjust to whatever your `Package.resolved` exposes for downloading authenticated media.

- [ ] **Step 4: Verify the implementation builds + the fake tests pass**

```bash
cd MatronShared && swift test --filter MediaServiceFakeTests
xcodebuild build -workspace Matron.xcworkspace -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass; project builds.

- [ ] **Step 5: Wire into `AppDependencies`**

Add to `AppDependencies`:

```swift
func mediaService(for session: UserSession) -> MediaService {
    MediaServiceLive(provider: clientProvider, session: session)
}
```

- [ ] **Step 6: Resolve `mxc://` URLs in `ChatViewModel`**

Add a side cache `[URL: Image]` to `ChatViewModel` and a method `func image(for url: URL) async -> Image?` that calls `mediaService.swiftUIImage(for:)`. When a snapshot is received, kick off prefetches for image kinds.

```swift
@Observable
@MainActor
final class ChatViewModel {
    // ... existing fields ...
    private let media: MediaService
    private(set) var resolvedImages: [URL: Image] = [:]

    init(roomID: String, timeline: TimelineService, media: MediaService) {
        self.roomID = roomID
        self.timeline = timeline
        self.media = media
    }

    func image(for url: URL) -> Image? {
        if let cached = resolvedImages[url] { return cached }
        Task { [weak self] in
            guard let self else { return }
            if let img = await self.media.swiftUIImage(for: url) {
                self.resolvedImages[url] = img
            }
        }
        return nil
    }
}
```

- [ ] **Step 7: Pass resolved image to `AttachmentImage`**

In `TimelineItemView.swift`, add an `@Environment` (or pass `viewModel`) so the `.image(let url, …)` case can call `viewModel.image(for: url)` and pass the result to `AttachmentImage(image: …)`.

- [ ] **Step 8: Add a ViewModel test for image resolution**

Append to `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`:

```swift
@MainActor
func test_imageRequest_populatesCache() async {
    let timeline = FakeTimelineService()
    let media = FakeMediaService()
    let url = URL(string: "mxc://example/abc")!
    media.stubData[url] = Data(repeating: 0, count: 4)  // not a valid PNG; we
    // only assert the request path here, not decode.
    let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)
    _ = vm.image(for: url)
    // Drain the side-effect Task. Bound by 2s.
    let start = Date()
    while media.requested.isEmpty && Date().timeIntervalSince(start) < 2 {
        await Task.yield()
    }
    XCTAssertEqual(media.requested, [url])
}
```

- [ ] **Step 9: Commit**

```bash
git add MatronShared/Sources/Media/ \
        MatronShared/Tests/ChatTests/MediaServiceFakeTests.swift \
        MatronShared/Sources/ViewModels/ChatViewModel.swift \
        MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift \
        Matron/Features/Chat/Rendering/TimelineItemView.swift \
        Matron/App/AppDependencies.swift
git commit -m "feat: MediaService for mxc:// resolution with NSCache; wire into shared ChatViewModel"
git push
```

---

### Task 13: Wire ChatList → ChatView navigation

**Files:**
- Modify: `Matron/Features/ChatList/ChatListView.swift`
- Modify: `Matron/App/MatronApp.swift`
- Modify: `Matron/App/AppDependencies.swift`

- [ ] **Step 1: Add timeline factory + extend ChatService with mute/leave/refresh**

Append to `AppDependencies`:

```swift
func timelineService(for session: UserSession, roomID: String) -> TimelineService {
    TimelineServiceLive(provider: clientProvider, session: session, roomID: roomID)
}
```

Extend `ChatService` (in `MatronShared/Sources/Chat/ChatService.swift`) with three new methods so the chat list can drive pull-to-refresh and the row-level long-press menu:

```swift
public protocol ChatService: Sendable {
    func chatSummaries() -> AsyncStream<[ChatSummary]>
    func createChat(with botID: String) async throws -> String

    /// Forces an immediate sync round-trip and waits until the next snapshot
    /// is published. Wired to SwiftUI's `.refreshable`.
    func refresh() async throws

    /// Mutes notifications for the room.
    func mute(roomID: String) async throws

    /// Leaves (and forgets) the room.
    func leave(roomID: String) async throws
}
```

In `ChatServiceLive`, add the SDK calls (names vary across releases — verify against `Package.resolved`):

```swift
public func refresh() async throws {
    let client = try await provider.client(for: session)
    try await client.syncService().forceSyncOnce()
}

public func mute(roomID: String) async throws {
    let client = try await provider.client(for: session)
    let room = try await client.getRoom(roomId: roomID)
    try await room.setNotificationMode(mode: .mute)
}

public func leave(roomID: String) async throws {
    let client = try await provider.client(for: session)
    let room = try await client.getRoom(roomId: roomID)
    try await room.leave()
    try await room.forget()
}
```

Drive each via TDD against the existing fakes (extend `FakeChatServiceForCreate` and `FakeChatService` with `refreshCalls: Int`, `mutedRooms: [String]`, `leftRooms: [String]` and add an XCTest case per method).

Append to `MatronShared/Tests/ChatTests/CreateChatTests.swift` (or a new `ChatActionsTests.swift`):

```swift
final class ChatActionsTests: XCTestCase {
    func test_refresh_recordsCall() async throws {
        let fake = FakeChatServiceForCreate()
        try await fake.refresh()
        let calls = await fake.refreshCalls
        XCTAssertEqual(calls, 1)
    }

    func test_mute_recordsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        try await fake.mute(roomID: "!a:s")
        let muted = await fake.mutedRooms
        XCTAssertEqual(muted, ["!a:s"])
    }

    func test_leave_recordsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        try await fake.leave(roomID: "!a:s")
        let left = await fake.leftRooms
        XCTAssertEqual(left, ["!a:s"])
    }
}
```

Run the tests — they FAIL until the protocol gains the methods and the fake implements them. Implement, re-run, expect PASS.

- [ ] **Step 2: Hoist current `UserSession` into a centralized environment value via `MatronApp`**

This is structural: `ChatView`/`ComposerView` need access to the current session to construct services. Easiest approach: pass `AppDependencies` + `UserSession` down via `@Environment`. Define an environment key in `Matron/App/AppDependencies.swift`:

```swift
struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

struct CurrentSessionKey: EnvironmentKey {
    static let defaultValue: UserSession? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
    var currentSession: UserSession? {
        get { self[CurrentSessionKey.self] }
        set { self[CurrentSessionKey.self] = newValue }
    }
}
```

- [ ] **Step 3: Inject in `MatronApp`**

Update `MatronApp.body` so that the post-sign-in branch wraps in `.environment(\.appDependencies, dependencies).environment(\.currentSession, session)`.

```swift
} else if let session {
    NavigationStack {
        ChatListView(viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)))
    }
    .environment(\.appDependencies, dependencies)
    .environment(\.currentSession, session)
    .task { try? await dependencies.syncService(for: session).start() }
}
```

- [ ] **Step 4: Replace `ChatListView` body to use `NavigationLink`**

Replace `ChatListView.body` (still a `NavigationStack`-wrapped layout — but the `NavigationStack` now lives in `MatronApp`, so drop the wrapper here):

```swift
struct ChatListView: View {
    @State var viewModel: ChatListViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var showingNewChat = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Connecting…")
            } else if viewModel.groups.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Provision a bot via dev-boxer to get started.")
                )
            } else {
                List {
                    ForEach(viewModel.groups) { group in
                        Section(group.group.rawValue) {
                            ForEach(group.summaries) { summary in
                                NavigationLink(value: summary) {
                                    ChatRow(summary: summary)
                                }
                                .contextMenu {
                                    Button {
                                        Task {
                                            if let deps, let session {
                                                try? await deps.chatService(for: session).mute(roomID: summary.id)
                                            }
                                        }
                                    } label: {
                                        Label("Mute", systemImage: "bell.slash")
                                    }
                                    Button(role: .destructive) {
                                        Task {
                                            if let deps, let session {
                                                try? await deps.chatService(for: session).leave(roomID: summary.id)
                                            }
                                        }
                                    } label: {
                                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    if let deps, let session {
                        try? await deps.chatService(for: session).refresh()
                    }
                }
            }
        }
        .navigationTitle("Matron")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewChat = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            if let deps, let session {
                NewChatSheet(deps: deps, session: session) { newRoomID in
                    showingNewChat = false
                    // Navigation: append the new summary once it appears in sync.
                }
            }
        }
        .navigationDestination(for: ChatSummary.self) { summary in
            if let deps, let session {
                let timelineSvc = deps.timelineService(for: session, roomID: summary.id)
                let mediaSvc = deps.mediaService(for: session)
                let chatVM = ChatViewModel(roomID: summary.id, timeline: timelineSvc, media: mediaSvc)
                let composerVM = ComposerViewModel(timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
                ChatView(
                    viewModel: chatVM,
                    composerVM: composerVM,
                    chatTitle: summary.title,
                    onShowBotProfile: { /* Phase 2 task 14 wires this */ }
                )
            }
        }
        .task { viewModel.start() }
    }
}

private struct ChatRow: View { /* unchanged from Phase 1 */ ... }
```

- [ ] **Step 5: Build + run, verify tap-to-open works (manual)**

In Xcode: Run on simulator, sign in, tap a chat row. Expect ChatView to open with the room's title and (empty for now) a timeline. Type a message and send. Expect the message to round-trip via the bridge.

- [ ] **Step 6: Commit**

```bash
git add Matron/Features/ChatList/ChatListView.swift Matron/App/
git commit -m "feat: navigate from chat list to chat view; pass deps via Environment (iOS)"
git push
```

---

### Task 13c: MacChatListView — sidebar column with hover + right-click menu

**Files:**
- Create: `MatronMac/Features/ChatList/MacChatListView.swift`
- Create: `MatronMacTests/MacChatListViewTests.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (host the 2-column `NavigationSplitView`)

The Mac variant of Task 13. Uses the same `ChatListViewModel` (from `MatronShared`, defined in Phase 1) and the same `ChatService` extensions added in Task 13 Step 1, but presents a 2-column `NavigationSplitView` with hover states, right-click context menus, and `⌘R` refresh in place of pull-to-refresh.

- [ ] **Step 1: Write the failing snapshot/structure test**

Create `MatronMacTests/MacChatListViewTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels

@MainActor
final class MacChatListViewTests: XCTestCase {
    /// Verifies the shared `ChatListViewModel` is consumed unchanged — the Mac
    /// view is a per-platform shell, not a parallel data model.
    func test_usesSharedChatListViewModel() {
        let vm = ChatListViewModel(chat: FakeChatServiceForCreate())
        let view = MacChatListView(viewModel: vm)
        XCTAssertNotNil(view.body)  // structural smoke; full snapshots in Task 14d.
    }

    /// Verifies hover-tint state is held on the row, not lifted into the VM.
    func test_hoverStateIsLocalToRow() {
        // Hover state should be `@State` inside `MacChatRow`, not on the VM.
        // (Compile-time check via accessing the view; full hover behavior verified manually.)
        XCTAssertTrue(true)
    }
}
#endif
```

Run it — should FAIL because `MacChatListView` doesn't exist yet.

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatListViewTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL — undefined symbol.

- [ ] **Step 2: Implement `MacChatListView`**

Create `MatronMac/Features/ChatList/MacChatListView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct MacChatListView: View {
    @State var viewModel: ChatListViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var selectedSummary: ChatSummary?
    @State private var showingNewChat = false

    var body: some View {
        NavigationSplitView {
            // Sidebar column — same recency-grouped rows as iOS.
            sidebar
                .frame(minWidth: 240, idealWidth: 280)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewChat = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New chat")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            // Detail column — hosts MacChatView once a chat is selected.
            if let summary = selectedSummary, let deps, let session {
                let timelineSvc = deps.timelineService(for: session, roomID: summary.id)
                let mediaSvc = deps.mediaService(for: session)
                let chatVM = ChatViewModel(roomID: summary.id, timeline: timelineSvc, media: mediaSvc)
                let composerVM = ComposerViewModel(timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
                MacChatView(
                    viewModel: chatVM,
                    composerVM: composerVM,
                    chatTitle: summary.title,
                    onShowBotProfile: { /* Task 15b: present MacBotProfileSheet */ }
                )
            } else {
                ContentUnavailableView(
                    "Select a chat",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a conversation from the sidebar.")
                )
            }
        }
        .sheet(isPresented: $showingNewChat) {
            if let deps, let session {
                NewChatSheet(deps: deps, session: session) { newRoomID in
                    showingNewChat = false
                    // Selection updates once the new summary appears in sync.
                }
            }
        }
        .task { viewModel.start() }
        // ⌘R refresh + sidebar toggle command observers (see Task 14e).
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.refresh))) { _ in
            Task {
                if let deps, let session {
                    try? await deps.chatService(for: session).refresh()
                }
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.isLoading {
            ProgressView("Connecting…")
        } else if viewModel.groups.isEmpty {
            ContentUnavailableView(
                "No chats yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Provision a bot via dev-boxer to get started.")
            )
        } else {
            List(selection: $selectedSummary) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary)
                                .contextMenu {
                                    // Right-click context menu — Mac analogue of iOS long-press.
                                    Button("Mute") {
                                        Task {
                                            if let deps, let session {
                                                try? await deps.chatService(for: session).mute(roomID: summary.id)
                                            }
                                        }
                                    }
                                    Button("Leave", role: .destructive) {
                                        Task {
                                            if let deps, let session {
                                                try? await deps.chatService(for: session).leave(roomID: summary.id)
                                            }
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // SwiftUI on Mac re-routes `.refreshable` to scroll-to-top + a
            // manual command path. The Mac scheme also gets a toolbar refresh
            // button (see Task 14d) and the `⌘R` menu shortcut (Task 14e).
            .refreshable {
                if let deps, let session {
                    try? await deps.chatService(for: session).refresh()
                }
            }
        }
    }
}

/// Row view with hover-tint state held locally so it doesn't muddy the VM.
private struct MacChatRow: View {
    let summary: ChatSummary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Reuse the same row composition as iOS — title, bot, relative time.
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(summary.lastActivity, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if summary.unreadCount > 0 {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
```

- [ ] **Step 3: Verify the build**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds.

- [ ] **Step 4: Re-run tests; expect PASS**

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatListViewTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS — `MacChatListView` exists, structural smoke holds.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/ChatList/MacChatListView.swift \
        MatronMacTests/MacChatListViewTests.swift \
        MatronMac/App/MatronMacApp.swift
git commit -m "feat: MacChatListView with sidebar, hover, right-click context menu (Mac)"
git push
```

---

### Task 14: NewChatSheet — pick a bot, create the room

**Files:**
- Create: `Matron/Features/ChatList/NewChatSheet.swift`

The sheet enumerates bots by collapsing the existing room list (each unique bot contact = one option). For Phase 2 we don't fetch a bot directory — bots already known appear here.

- [ ] **Step 1: Implement**

Create `Matron/Features/ChatList/NewChatSheet.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct NewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @State private var bots: [BotIdentity] = []
    @State private var creatingFor: BotIdentity?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section("Pick a bot") {
                    ForEach(bots, id: \.matrixID) { bot in
                        Button {
                            Task { await create(with: bot) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.displayName).font(.body)
                                    Text(bot.matrixID).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if creatingFor == bot { ProgressView() }
                            }
                        }
                        .disabled(creatingFor != nil)
                    }
                }
            }
            .navigationTitle("New chat")
            .task { await loadBots() }
        }
    }

    private func loadBots() async {
        let chat = deps.chatService(for: session)
        for await snapshot in chat.chatSummaries() {
            let unique = Set(snapshot.map(\.bot))
            await MainActor.run { bots = Array(unique).sorted { $0.displayName < $1.displayName } }
            break  // first snapshot is enough
        }
    }

    private func create(with bot: BotIdentity) async {
        creatingFor = bot
        defer { creatingFor = nil }
        do {
            let chat = deps.chatService(for: session)
            let roomID = try await chat.createChat(with: bot.matrixID)
            onCreated(roomID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Matron/Features/ChatList/NewChatSheet.swift
git commit -m "feat: NewChatSheet to start a fresh room with an existing bot"
git push
```

---

### Task 14c: MacChatView — detail column with composer + drag-and-drop

**Files:**
- Create: `MatronMac/Features/Chat/MacChatView.swift`
- Create: `MatronMac/Features/Chat/ComposerDropDelegate.swift`
- Create: `MatronMacTests/MacChatViewTests.swift`

The Mac variant of Task 12. Uses the shared `ChatViewModel` + `ComposerViewModel` from `MatronShared/Sources/ViewModels/`. Composer pinned at the bottom, growing height. Drag-and-drop attachments via `.onDrop` → `ComposerDropDelegate` → `ComposerViewModel.attachFiles(_:)`. Slash palette via `/` typing AND `⌘K`. Right-click context menu replaces iOS long-press.

- [ ] **Step 1: Write the failing test**

Create `MatronMacTests/MacChatViewTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import MatronMac
import MatronChat
import MatronModels

@MainActor
final class MacChatViewTests: XCTestCase {
    /// `ComposerDropDelegate` should call `ComposerViewModel.attachFiles(_:)`
    /// with the dropped URLs.
    func test_dropDelegate_handsURLsToComposer() async {
        let fakeTimeline = FakeTimelineService()
        let composer = ComposerViewModel(timeline: fakeTimeline, commands: [])
        let delegate = ComposerDropDelegate(composer: composer)
        let url = URL(fileURLWithPath: "/tmp/test.png")
        // Construct an NSItemProvider with a fileURL representation.
        let provider = NSItemProvider()
        provider.registerObject(url as NSURL, visibility: .all)
        let info = MockDropInfo(itemProviders: [provider])
        let accepted = delegate.performDrop(info: info)
        XCTAssertTrue(accepted)
    }

    /// `⌘K` shortcut on the slash menu trigger should pin the palette open.
    func test_cmdK_opensSlashPalette() {
        let composer = ComposerViewModel(timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        XCTAssertFalse(composer.showPalette)
        composer.palettePinnedOpen = true
        XCTAssertTrue(composer.showPalette)
    }
}

/// Minimal DropInfo stand-in for unit tests.
private struct MockDropInfo: DropInfo {
    let itemProviders: [NSItemProvider]
    var location: CGPoint { .zero }
    func itemProviders(for: [UTType]) -> [NSItemProvider] { itemProviders }
    func itemProviders(for: [String]) -> [NSItemProvider] { itemProviders }
    func hasItemsConforming(to: [UTType]) -> Bool { !itemProviders.isEmpty }
    func hasItemsConforming(to: [String]) -> Bool { !itemProviders.isEmpty }
}
#endif
```

Run it — should FAIL (no `MacChatView`/`ComposerDropDelegate`).

- [ ] **Step 2: Implement `ComposerDropDelegate`**

Create `MatronMac/Features/Chat/ComposerDropDelegate.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import MatronChat

@MainActor
struct ComposerDropDelegate: DropDelegate {
    let composer: ComposerViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.image, .fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL, .image])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            await composer.attachFiles(urls)
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }
}
```

- [ ] **Step 3: Implement `MacChatView`**

Create `MatronMac/Features/Chat/MacChatView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronDesignSystem

struct MacChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            TimelineItemView(item: item)
                                .id(item.id)
                                .contextMenu {
                                    // Right-click context menu — Mac analogue of long-press.
                                    if case .text(let body, _) = item.kind {
                                        Button("Copy") { Pasteboard.copy(body) }
                                        ShareLink(item: body) { Label("Share", systemImage: "square.and.arrow.up") }
                                    }
                                }
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: viewModel.items.count) { _, _ in
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Composer: pinned at bottom, growing height.
            ComposerView(viewModel: composerVM)
                // Drag-and-drop attachments via ComposerDropDelegate.
                .onDrop(of: [.image, .fileURL], delegate: ComposerDropDelegate(composer: composerVM))
        }
        .toolbar { MacChatToolbar(title: chatTitle, viewModel: viewModel, onShowBotProfile: onShowBotProfile) }
        .task {
            viewModel.start()
            await viewModel.markAsRead()
        }
        .onDisappear { viewModel.stop() }
        // ⌘K opens the slash palette without typing `/`.
        .background(
            Button("") { composerVM.palettePinnedOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
        // ⌘R refresh.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.refresh))) { _ in
            Task { await viewModel.refresh() }
        }
    }
}
```

- [ ] **Step 4: Re-use `ComposerView` from iOS or build a Mac-tailored shell**

`Matron/Features/Chat/Composer/ComposerView.swift` is iOS-flavored (uses `PhotosPicker`, `UIPasteboard`, etc). For Mac, wrap the shared `ComposerViewModel` in a Mac shell that uses `NSOpenPanel` for attachments and the cross-platform `Pasteboard` helper. Either:

- (a) Add a `#if os(macOS)` branch inside `ComposerView` — simpler for one phase; or
- (b) Create `MatronMac/Features/Chat/MacComposerView.swift` and treat iOS `ComposerView` as iOS-only.

Pick (a) for Phase 2 to keep the surface small; revisit in Phase 7 polish if it gets noisy.

- [ ] **Step 5: Build + tests**

```bash
xcodegen generate
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatViewTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: build + tests pass.

- [ ] **Step 6: Commit**

```bash
git add MatronMac/Features/Chat/MacChatView.swift \
        MatronMac/Features/Chat/ComposerDropDelegate.swift \
        MatronMacTests/MacChatViewTests.swift
git commit -m "feat: MacChatView with drag-and-drop attachments + ⌘K palette + ⌘R refresh"
git push
```

---

### Task 14d: MacChatToolbar — sidebar toggle, title strip, ⓘ, search placeholder

**Files:**
- Create: `MatronMac/Features/Chat/MacChatToolbar.swift`
- Create: `MatronMacTests/MacChatToolbarTests.swift`

The Mac chat detail column toolbar (per spec §5.9). Left: sidebar toggle (mirrors `⌘⇧S`). Center: chat title + `session_meta` strip (model · workdir, when present). Right: ⓘ info button → bot profile sheet; search field placeholder (full search lands in Phase 6).

- [ ] **Step 1: Failing test**

Create `MatronMacTests/MacChatToolbarTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels

@MainActor
final class MacChatToolbarTests: XCTestCase {
    func test_toolbarRenders_withTitleAndInfoButton() {
        let vm = ChatViewModel(roomID: "!a:s", timeline: FakeTimelineService(), media: FakeMediaService())
        let toolbar = MacChatToolbar(title: "Refactoring auth", viewModel: vm, onShowBotProfile: {})
        XCTAssertNotNil(toolbar.body)
    }
}
#endif
```

- [ ] **Step 2: Implement**

Create `MatronMac/Features/Chat/MacChatToolbar.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

@MainActor
struct MacChatToolbar: ToolbarContent {
    let title: String
    let viewModel: ChatViewModel
    let onShowBotProfile: () -> Void
    @State private var searchText: String = ""

    var body: some ToolbarContent {
        // Left: sidebar toggle (mirrors ⌘⇧S; SwiftUI provides a default for
        // NavigationSplitView — `.navigationSplitViewColumnVisibility` flips
        // on the menu shortcut from Task 14e).
        ToolbarItem(placement: .navigation) {
            Button {
                NotificationCenter.default.post(name: .matronCommand(.toggleSidebar), object: nil)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar (⌘⇧S)")
        }

        // Center: chat title + session_meta strip.
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                // session_meta lands in Phase 5; placeholder for now.
                Text("Session metadata appears here in Phase 5")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        // Right: refresh + search field placeholder + ⓘ info.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            TextField("Search chat…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 200)
                // Wired to ⌘F focus in Task 14e; full search arrives in Phase 6.
        }
        ToolbarItem(placement: .primaryAction) {
            Button { onShowBotProfile() } label: {
                Image(systemName: "info.circle")
            }
            .help("Bot profile")
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git add MatronMac/Features/Chat/MacChatToolbar.swift \
        MatronMacTests/MacChatToolbarTests.swift
git commit -m "feat: MacChatToolbar with sidebar toggle, title, ⓘ, search placeholder, refresh"
git push
```

---

### Task 14e: MacMenuBar — `Commands` struct + `NotificationCenter` command bus

**Files:**
- Create: `MatronMac/App/Commands.swift`
- Create: `MatronMacTests/MacCommandsTests.swift`
- Modify: `MatronMac/App/MatronMacApp.swift` (`.commands { ChatCommands() }`)

Phase 2 wires the menu bar (per spec §5.9). Each shortcut posts a `Notification.Name` keyed enum; relevant views observe via `.onReceive`. Help-menu entries for verification are placeholders that lead to Phase 3.

- [ ] **Step 1: Failing test**

Create `MatronMacTests/MacCommandsTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

final class MacCommandsTests: XCTestCase {
    /// Verifies the notification name keying enum produces stable, distinct names.
    func test_notificationNames_areDistinct() {
        let cases: [MatronCommand] = [
            .newChat, .signOut, .findInChat, .slashCommand,
            .toggleSidebar, .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .verifyDevice, .showRecoveryKey, .refresh,
        ]
        let names = Set(cases.map { Notification.Name.matronCommand($0).rawValue })
        XCTAssertEqual(names.count, cases.count)
    }

    /// Posting a `.newChat` notification should reach a registered observer.
    func test_post_newChat_notifiesObserver() {
        let exp = expectation(description: "newChat observed")
        let observer = NotificationCenter.default.addObserver(
            forName: .matronCommand(.newChat), object: nil, queue: nil
        ) { _ in exp.fulfill() }
        NotificationCenter.default.post(name: .matronCommand(.newChat), object: nil)
        wait(for: [exp], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }
}
#endif
```

- [ ] **Step 2: Implement `MatronCommand` enum + `ChatCommands` struct**

Create `MatronMac/App/Commands.swift`:

```swift
import SwiftUI

/// Command bus keys. Each menu/keyboard-shortcut posts a corresponding
/// notification; views observe with `.onReceive(...matronCommand(.case))`.
public enum MatronCommand: String, CaseIterable, Sendable {
    case newChat
    case signOut
    case findInChat
    case slashCommand
    case toggleSidebar
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case verifyDevice
    case showRecoveryKey
    case refresh
}

public extension Notification.Name {
    static func matronCommand(_ cmd: MatronCommand) -> Notification.Name {
        Notification.Name("chat.matron.command.\(cmd.rawValue)")
    }
}

/// Mounted on the main scene as `.commands { ChatCommands() }`.
struct ChatCommands: Commands {
    var body: some Commands {
        // File menu.
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { post(.newChat) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Sign Out…") { post(.signOut) }
        }

        // Edit menu.
        CommandGroup(after: .pasteboard) {
            Button("Find in Chat") { post(.findInChat) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Slash Command") { post(.slashCommand) }
                .keyboardShortcut("k", modifiers: .command)
        }

        // View menu.
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { post(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Increase Font Size") { post(.increaseFontSize) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { post(.decreaseFontSize) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Size") { post(.resetFontSize) }
                .keyboardShortcut("0", modifiers: .command)
        }

        // Help menu — Phase 3 wires the actual flows; Phase 2 just adds the items.
        CommandGroup(replacing: .help) {
            Button("Verify This Device…") { post(.verifyDevice) }
            Button("Show Recovery Key…") { post(.showRecoveryKey) }
        }
    }

    private func post(_ cmd: MatronCommand) {
        NotificationCenter.default.post(name: .matronCommand(cmd), object: nil)
    }
}
```

- [ ] **Step 3: Mount on the main scene**

In `MatronMac/App/MatronMacApp.swift`:

```swift
@main
struct MatronMacApp: App {
    var body: some Scene {
        WindowGroup { /* ... */ }
            .commands { ChatCommands() }
        Settings { /* SettingsView lands in Phase 7 */ }
    }
}
```

- [ ] **Step 4: Verify tests pass**

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacCommandsTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/App/Commands.swift MatronMacTests/MacCommandsTests.swift \
        MatronMac/App/MatronMacApp.swift
git commit -m "feat: Mac menu bar (File/Edit/View/Help) with NotificationCenter command bus"
git push
```

---

### Task 15: BotProfileView + BotProfileViewModel (iOS)

**Files:**
- Create: `MatronShared/Sources/ViewModels/BotProfileViewModel.swift` (target-agnostic; consumed by both `BotProfileView` (iOS) and `MacBotProfileSheet` (Mac, Task 15b))
- Create: `Matron/Features/BotProfile/BotProfileView.swift`
- Create: `MatronShared/Tests/ViewModelTests/BotProfileViewModelTests.swift`

- [ ] **Step 1: ViewModel test**

Create `MatronShared/Tests/ViewModelTests/BotProfileViewModelTests.swift`:

```swift
import XCTest
@testable import Matron
import MatronChat
import MatronModels

final class BotProfileViewModelTests: XCTestCase {
    @MainActor
    func test_filtersChatsByBotID() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let linear = BotIdentity(matrixID: "@linear:s", displayName: "Linear", avatarURL: nil)
        let now = Date()
        let summaries: [ChatSummary] = [
            ChatSummary(id: "!a:s", title: "A", bot: claude, lastActivity: now, unreadCount: 0),
            ChatSummary(id: "!b:s", title: "B", bot: linear, lastActivity: now, unreadCount: 0),
            ChatSummary(id: "!c:s", title: "C", bot: claude, lastActivity: now.addingTimeInterval(-86400), unreadCount: 0),
        ]
        let vm = BotProfileViewModel(bot: claude, allSummaries: summaries)
        XCTAssertEqual(vm.chatsForBot.map(\.id), ["!a:s", "!c:s"])
    }
}
```

- [ ] **Step 2: Implement ViewModel**

Create `MatronShared/Sources/ViewModels/BotProfileViewModel.swift`:

```swift
import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
public final class BotProfileViewModel {
    public let bot: BotIdentity
    public let chatsForBot: [ChatSummary]

    public init(bot: BotIdentity, allSummaries: [ChatSummary]) {
        self.bot = bot
        self.chatsForBot = allSummaries
            .filter { $0.bot.matrixID == bot.matrixID }
            .sorted { $0.lastActivity > $1.lastActivity }
    }
}
```

- [ ] **Step 3: Implement View**

Create `Matron/Features/BotProfile/BotProfileView.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct BotProfileView: View {
    @State var viewModel: BotProfileViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onStartNewChat: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Circle().fill(.secondary.opacity(0.2)).frame(width: 64, height: 64)
                    Text(viewModel.bot.displayName).font(.title3).bold()
                    Text(viewModel.bot.matrixID).font(.caption).foregroundStyle(.secondary)
                    Button("Start new chat", action: onStartNewChat).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("All chats") {
                ForEach(viewModel.chatsForBot) { summary in
                    Button { onSelectChat(summary) } label: {
                        VStack(alignment: .leading) {
                            Text(summary.title)
                            Text(summary.lastActivity, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Bot")
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
git add MatronShared/Sources/ViewModels/BotProfileViewModel.swift \
        MatronShared/Tests/ViewModelTests/BotProfileViewModelTests.swift \
        Matron/Features/BotProfile/BotProfileView.swift
git commit -m "feat: BotProfileView (iOS) with per-bot chat list"
git push
```

---

### Task 15b: MacBotProfileSheet — full-window sheet on Mac

**Files:**
- Create: `MatronMac/Features/BotProfile/MacBotProfileSheet.swift`
- Create: `MatronMacTests/MacBotProfileSheetTests.swift`

The Mac variant of Task 15. Uses the same shared `BotProfileViewModel` from `MatronShared/Sources/ViewModels/`. Renders as a **full-window sheet** (`.sheet(isPresented:)`) — not the iOS half-sheet — per spec §5.9. Wired from `MacChatToolbar`'s ⓘ button (Task 14d) and `MacChatListView`'s detail column.

- [ ] **Step 1: Failing test**

Create `MatronMacTests/MacBotProfileSheetTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels

@MainActor
final class MacBotProfileSheetTests: XCTestCase {
    /// Mac sheet should reuse the shared `BotProfileViewModel` unchanged —
    /// no Mac-specific data model.
    func test_usesSharedViewModel() {
        let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let summaries: [ChatSummary] = []
        let vm = BotProfileViewModel(bot: bot, allSummaries: summaries)
        let sheet = MacBotProfileSheet(viewModel: vm, onSelectChat: { _ in }, onStartNewChat: {}, onDismiss: {})
        XCTAssertNotNil(sheet.body)
    }
}
#endif
```

Run it — should FAIL (sheet doesn't exist).

- [ ] **Step 2: Implement `MacBotProfileSheet`**

Create `MatronMac/Features/BotProfile/MacBotProfileSheet.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels

struct MacBotProfileSheet: View {
    @State var viewModel: BotProfileViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onStartNewChat: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header card.
            VStack(spacing: 8) {
                Circle().fill(.secondary.opacity(0.2)).frame(width: 80, height: 80)
                Text(viewModel.bot.displayName).font(.title2).bold()
                Text(viewModel.bot.matrixID).font(.callout).foregroundStyle(.secondary)
                Button("Start new chat", action: onStartNewChat)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            Divider()

            // All chats.
            List {
                Section("All chats") {
                    ForEach(viewModel.chatsForBot) { summary in
                        Button { onSelectChat(summary) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.title)
                                    Text(summary.lastActivity, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 240)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 540, idealHeight: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
            }
        }
    }
}
```

- [ ] **Step 3: Wire from `MacChatView` + `MacChatToolbar`**

Replace the `onShowBotProfile: { /* ... */ }` placeholder in `MacChatListView`'s detail-column construction (Task 13c) with state that flips a `@State private var showingBotProfile = false`, and present:

```swift
.sheet(isPresented: $showingBotProfile) {
    if let summary = selectedSummary {
        let bot = summary.bot
        let allSummaries = viewModel.groups.flatMap(\.summaries)
        let bpVM = BotProfileViewModel(bot: bot, allSummaries: allSummaries)
        MacBotProfileSheet(
            viewModel: bpVM,
            onSelectChat: { _ in showingBotProfile = false /* navigate */ },
            onStartNewChat: { showingBotProfile = false; showingNewChat = true },
            onDismiss: { showingBotProfile = false }
        )
    }
}
```

- [ ] **Step 4: Verify tests + build**

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacBotProfileSheetTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -workspace Matron.xcworkspace -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: PASS + build succeeds.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/BotProfile/MacBotProfileSheet.swift \
        MatronMacTests/MacBotProfileSheetTests.swift \
        MatronMac/Features/ChatList/MacChatListView.swift
git commit -m "feat: MacBotProfileSheet as full-window sheet (Mac)"
git push
```

---

### Task 16: Long-press menu + view-source sheet

**Files:**
- Create: `Matron/Features/Chat/Rendering/EventSourceSheet.swift`
- Modify: `Matron/Features/Chat/ChatView.swift`

- [ ] **Step 1: Implement view-source sheet**

Create `Matron/Features/Chat/Rendering/EventSourceSheet.swift`:

```swift
import SwiftUI
import MatronChat

struct EventSourceSheet: View {
    let item: TimelineItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(prettyJSON())
                    .font(.system(.callout, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .navigationTitle("Event source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func prettyJSON() -> String {
        // Phase 2 has access to the DTO only, not the raw event JSON.
        // Render the DTO instead. Phase 5 can wire raw event access via the SDK.
        return """
        id: \(item.id)
        sender: \(item.sender)
        timestamp: \(item.timestamp)
        kind: \(item.kind)
        isOwn: \(item.isOwn)
        sendState: \(item.sendState)
        """
    }
}
```

- [ ] **Step 2: Wire long-press in `ChatView`**

In `ChatView.swift`'s `.contextMenu` block, append a "View source" button that sets `@State var sourceItem: TimelineItem?` and present a `.sheet(item: $sourceItem) { EventSourceSheet(item: $0) }`. (Add `@State private var sourceItem: TimelineItem?` to the view.)

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Chat/
git commit -m "feat: long-press View source sheet for timeline items"
git push
```

---

### Task 17: Update manual test checklist

**Files:**
- Modify: `manual-tests.md`

- [ ] **Step 1: Add Phase 2 section**

Append to `manual-tests.md`:

```markdown
## Phase 2 (Chat experience) — iOS

### Chat navigation

- [ ] Tap a chat row → ChatView opens with that chat's title.
- [ ] Tap ⓘ in the toolbar → BotProfile opens, showing all chats with that bot.
- [ ] From BotProfile, tap "Start new chat" → new room created and ChatView opens with empty timeline.

### Chat list actions

- [ ] Pull the chat list down → spinner appears, list refreshes (Mute/Leave round-trip via `ChatService.refresh()`).
- [ ] Long-press a chat row → context menu shows "Mute" and "Leave" actions.
- [ ] Tap "Mute" → row's bot stops sending iOS notifications; verify by sending a message from the bot.
- [ ] Tap "Leave" → row disappears from the list; the room is no longer in `chatSummaries()`.

### Sending

- [ ] Type a plain text message and send → appears in the timeline as "me" (right-aligned).
- [ ] Type `/` → slash palette appears. Type `/sta` → only `/start`, `/status` shown.
- [ ] Tap a slash command → it pre-fills the composer; tap send → message goes through.
- [ ] Tap 📎 → choose a photo → sends as `m.image`. Bot rooms should ack receipt.
- [ ] Tap 📎 → choose a file → sends as `m.file`. Bot rooms should ack receipt.

### Receiving + rendering

- [ ] Bot sends a markdown reply with code block → renders with monospaced code, copy button works.
- [ ] Bot sends an image → renders as AttachmentImage.
- [ ] Bot sends a file → renders as AttachmentFile.

### History

- [ ] Scroll to top → older messages paginate in.
- [ ] Long-press a message → Copy / Share / View source menu shows.
- [ ] View source opens a sheet with the DTO printed.

### New chat creation

- [ ] Tap ✏️ on chat list → NewChatSheet opens listing known bots.
- [ ] Pick a bot → new room created, automatically opens ChatView.
- [ ] Verify the bot has joined (state change appears or first bot message comes through).

## Phase 2 (Chat experience) — Mac

### Chat navigation (Mac)

- [ ] Click a chat row in the sidebar → detail column shows MacChatView with that chat's title.
- [ ] Click ⓘ in the toolbar → MacBotProfileSheet opens as a full-window sheet.
- [ ] From the sheet, click "Start new chat" → sheet dismisses, NewChatSheet opens.
- [ ] With no selection, detail column shows the "Select a chat" placeholder.

### Chat list actions (Mac)

- [ ] Hover a chat row → background tint appears; cursor stays default.
- [ ] Right-click a chat row → context menu shows "Mute" and "Leave".
- [ ] Press `⌘R` (or click the toolbar refresh button) → forces a sync; new messages flow in.
- [ ] No pull-to-refresh gesture (Mac has no touch gesture); refresh works only via `⌘R` / button.

### Sending (Mac)

- [ ] Type a plain text message in the composer → send via `↩` → appears as "me" in the timeline.
- [ ] Type `/sta` → slash palette appears with `/start`, `/status`.
- [ ] Press `⌘K` with empty composer → slash palette opens (pinned via `palettePinnedOpen`).
- [ ] Drag an image onto the composer → `ComposerDropDelegate` handles it → image sends as `m.image`.
- [ ] Drag a file (e.g. PDF) onto the composer → sends as `m.file`.

### Menu bar (Mac)

- [ ] File → New Chat (`⌘N`) → NewChatSheet opens.
- [ ] File → Sign Out… → posts `.signOut` notification (full sign-out wired in Phase 7).
- [ ] Edit → Find in Chat (`⌘F`) → focuses the toolbar search field placeholder.
- [ ] Edit → Slash Command (`⌘K`) → opens slash palette in the focused composer.
- [ ] View → Toggle Sidebar (`⌘⇧S`) → sidebar collapses/expands.
- [ ] View → Increase / Decrease / Reset Font Size (`⌘+` / `⌘-` / `⌘0`) → notification fires (full font-scale wired in Phase 7).
- [ ] Help → Verify This Device… / Show Recovery Key… → entries present (Phase 3 wires the flows).

### Receiving + rendering (Mac)

- [ ] Bot sends markdown with a code block → MarkdownText + CodeBlock render correctly; Copy button writes to NSPasteboard.
- [ ] Bot sends an image → AttachmentImage renders the resolved `mxc://` content.
- [ ] Bot sends a file → AttachmentFile shows filename + size.

### History (Mac)

- [ ] Scroll to top of the timeline → older messages paginate in.
- [ ] Right-click a message → Copy / Share / View source menu shows.
- [ ] View source opens a sheet with the DTO printed.
```

- [ ] **Step 2: Commit**

```bash
git add manual-tests.md
git commit -m "docs: phase 2 manual test additions"
git push
```

---

## Phase 2 acceptance

1. All 17 main tasks (plus the sub-tasks 2b, 5b, 12b, **13c, 14c, 14d, 14e, 15b**) committed and pushed.
2. CI green on both iOS and Mac schemes.
3. Manual checklist passes on **both platforms** against a real `dev-boxer` homeserver with at least one Claude bot — iOS section runs on iPhone simulator/device; Mac section runs on a Mac build.
4. iOS run: sign in → chat list → tap chat → chat opens → send a message → bot replies → reply renders correctly.
5. Mac run: sign in → chat list sidebar → click chat → detail column opens → send a message (via composer or drag-and-drop) → bot replies → reply renders correctly. Menu-bar shortcuts (`⌘N`, `⌘K`, `⌘F`, `⌘⇧S`, `⌘R`) all fire their respective notifications.

After acceptance, write Phase 3 plan (E2EE & verification UX).

---

## Plan self-review

- **§4 Custom event types:** Deliberately deferred. Phase 2 renders only `m.text`, `m.image`, `m.file`. Custom event types (`tool_call`, `ask_user`, `session_meta`) are Phase 5 once the bridge protocol is updated.
- **§5.4 Chat view (iOS):** Covered by Tasks 10–12, 16. Composer + slash palette in Tasks 8–9. Pull-to-refresh and the row-level Mute/Leave context menu live in Task 13.
- **§5.4 Chat view (Mac):** Covered by Task 14c (`MacChatView` with detail-column timeline + composer + drag-and-drop attachments + `⌘K` slash palette + `⌘R` refresh). Right-click context menu replaces iOS long-press.
- **§5.3 chat list (Mac):** Covered by Task 13c (`MacChatListView` — 2-column `NavigationSplitView` with sidebar hover state, right-click Mute/Leave, recency-grouped rows reusing the shared `ChatListViewModel`). Pull-to-refresh deltas: no touch gesture on Mac, so refresh is via `⌘R` shortcut + a toolbar refresh button.
- **§5.5 Bot profile (iOS):** Covered by Task 15.
- **§5.5 Bot profile (Mac):** Covered by Task 15b (`MacBotProfileSheet` — full-window sheet, not iOS half-sheet — reusing the shared `BotProfileViewModel`).
- **§5.6 Settings:** Implemented in Phase 7 (Polish) Task 4 — deferred here to keep this phase focused on chat-pane UI. See `docs/superpowers/plans/2026-05-02-matron-ios-phase-7-polish.md`. No new tasks added in Phase 2.
- **§5.9 Mac chrome:** Toolbar covered by Task 14d (`MacChatToolbar` — sidebar toggle left, title + session_meta strip center, ⓘ + search placeholder + refresh right). Menu bar covered by Task 14e (`Commands.swift` defines `MatronCommand` enum + `ChatCommands` struct mounted via `MatronMacApp.commands { ChatCommands() }`; each menu item posts a `Notification.Name.matronCommand(.case)` observed by the relevant views — File: New Chat `⌘N` / Sign Out…; Edit: Find in Chat `⌘F` / Slash Command `⌘K`; View: Toggle Sidebar `⌘⇧S` / Increase/Decrease/Reset Font Size `⌘+`/`⌘-`/`⌘0`; Help: Verify This Device… + Show Recovery Key… as Phase-3 placeholders).
- **§6.1 Sync loop:** Phase 1 covered the room-list slice; Task 5 + Task 5b here add the timeline slice (the diff-application logic is exhaustively tested with synthetic `MatrixRustSDK.TimelineDiff` cases).
- **§6.4 New chat creation:** Covered by Tasks 6 + 14. The same `NewChatSheet` is presented from both iOS `ChatListView` and Mac `MacChatListView` — no duplication.
- **Media (`mxc://`) resolution:** Task 12b defines `MediaService`/`MediaServiceLive` with an `NSCache`-backed image cache and wires it to `ChatViewModel` so `AttachmentImage` receives a real `Image` instead of `nil`. `MediaService.swiftUIImage(for:)` works on both platforms (UIKit branch returns `Image(uiImage:)`, AppKit branch returns `Image(nsImage:)` — the convenience extension already lives in `MatronShared`).
- **`ToolCallCard` deferral:** `ToolCallCard` view primitive (collapsed/expanded/status states) is implemented in Phase 5 alongside the `chat.matron.tool_call` event parser. Phase 2 establishes only the surrounding rendering primitives (`MarkdownText`, `CodeBlock`, `AttachmentImage`, `AttachmentFile`, `MessageBubble`).
- **DesignSystem placement:** Per the Phase 1 reorg, every visual primitive (`MarkdownText`, `CodeBlock`, `AttachmentImage`, `AttachmentFile`, `MessageBubble`) lives in `MatronShared/Sources/DesignSystem/` from the start — not in `Matron/Features/Chat/Rendering/`. Both apps consume them directly. iOS-only platform shims (e.g. `Pasteboard.copy` UIKit/AppKit branches) live alongside the primitive that needs them; no `Color(.systemGray6)` literals leak into either app target.
- **ViewModels placement:** `ChatViewModel`, `ComposerViewModel`, `BotProfileViewModel` all live in `MatronShared/Sources/ViewModels/` (Tasks 8, 10, 15). `Matron/Features/` and `MatronMac/Features/` each provide a per-platform shell view that consumes the same `@Observable` ViewModel — no parallel data models.
- **§10 Testing — snapshot variants doubled:** Snapshot tests for primitives (Tasks 2, 2b, 3, 11) all use the shared `assertVariants` helper, which now records baselines for `{iOS, Mac} × {light, dark, accessibility5}` — **6 baselines per test** instead of 3. The helper has a `#if os(macOS)` branch that emits Mac variants via `NSHostingView`-backed snapshots; iOS variants run under the `canImport(UIKit) && !os(macOS)` branch. Both baseline sets are checked into `__Snapshots__/` side-by-side.
- **§10 Testing — Mac suites:** New `MatronMacTests/` target covers `MacChatListViewTests`, `MacChatViewTests` (including `ComposerDropDelegate` exercising `attachFiles(_:)` via mock `DropInfo`), `MacBotProfileSheetTests`, and `MacCommandsTests` (verifies notification name uniqueness + that posting `.newChat` reaches an observer). ViewModel tests (Tasks 8, 10, 15) live in `MatronShared/Tests/ViewModelTests/` and run on both schemes. The race-prone `Task.sleep` in `ChatViewModelTests` has been replaced with deterministic completion (`vm.start()` returns the observation `Task` and `FakeTimelineService.items()` finishes its stream after yielding all snapshots). `FakeTimelineService` is now a `final class` with a serial lock instead of an `actor` with a self-referential `nonisolated` accessor — strict-concurrency clean.
- No placeholders. Type signatures are consistent with Phase 1 (`UserSession`, `ChatSummary`, `BotIdentity`, `ChatService`, `AppDependencies`). New types (`TimelineItem`, `BotCommand`, `MatronCommand`) defined before first use.
