# Inline ask-user cards — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render bot questions (incl. the buttons-protocol queued/cancel/send prompt) inline + non-blocking in the chat timeline, replacing the blocking ask-user sheet on both platforms.

**Architecture:** A new shared `AskUserCard` (MatronDesignSystem) wraps the existing `AskUserSheetBody`; `.askUser` timeline rows render it instead of a pill. `ChatViewModel` caches one `AskUserSheetViewModel` per prompt (stable inline input state) and computes the answered-state echo. The `AskUserSheet`/`MacAskUserSheet` modals and their `pendingAsk()`-driven presentation are deleted.

**Tech Stack:** SwiftUI, `@Observable` view models, swift-snapshot-testing (DesignSystem), XCTest.

**Reference spec:** `docs/superpowers/specs/2026-06-13-inline-ask-user-cards-design.md`.

---

## File structure

```
MatronShared/Sources/DesignSystem/
  AskUserCard.swift                         NEW — inline card (pure: plain values + bindings)
MatronShared/Tests/DesignSystemSnapshotTests/
  AskUserCardSnapshotTests.swift            NEW — unanswered/answered/expired variants
MatronShared/Sources/ViewModels/
  ChatViewModel.swift                       MODIFIED — askViewModel(forPrompt:) cache + answerSummary(forPrompt:)
MatronShared/Tests/ViewModelTests/
  ChatViewModelTests.swift                  MODIFIED — cache stability + answerSummary tests
Matron/Features/Chat/Rendering/
  TimelineItemView.swift                    MODIFIED — .askUser → AskUserCard + ask closures
Matron/Features/Chat/
  ChatView.swift                            MODIFIED — remove sheet wiring; pass ask closures
  Rendering/AskUserSheet.swift              DELETE
MatronMac/Features/Chat/
  MacTimelineItemView.swift                 MODIFIED — .askUser → AskUserCard + ask closures
  MacChatView.swift                         MODIFIED — remove sheet wiring; pass ask closures
  MacAskUserSheet.swift                     DELETE
```

`ChatViewModel.pendingAsk()`, `isPromptAnswered`, `markPromptAnswered`, `makeAskUserSheetViewModel`, and `AskUserPromptContext` are **kept** (public, tested). `pendingAsk()` is simply no longer called by the views; a later cleanup can remove it.

---

## Task 1: AskUserCard (shared inline card) + snapshot tests

**Files:**
- Create: `MatronShared/Sources/DesignSystem/AskUserCard.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/AskUserCardSnapshotTests.swift`

- [ ] **Step 1: Write the failing snapshot tests**

`AskUserCard` is pure (plain values + `Binding.constant`), like `AskUserSheetBody`, so it snapshots directly via the existing `assertVariants` helper.

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class AskUserCardSnapshotTests: XCTestCase {
    private func card(
        event: AskUserEvent,
        isAnswered: Bool = false,
        answerSummary: String? = nil,
        textInput: String = "",
        selectedChoiceIDs: Set<String> = [],
        booleanAnswer: Bool? = nil,
        isExpired: Bool = false,
        error: String? = nil
    ) -> some View {
        AskUserCard(
            event: event,
            isAnswered: isAnswered,
            answerSummary: answerSummary,
            textInput: .constant(textInput),
            selectedChoiceIDs: .constant(selectedChoiceIDs),
            booleanAnswer: .constant(booleanAnswer),
            isSending: false,
            isExpired: isExpired,
            error: error,
            onSend: {}
        )
        .frame(width: 360)
        .padding()
    }

    private var buttonsEvent: AskUserEvent {
        AskUserEvent(
            prompt: "Message queued. Send now or cancel?",
            kind: .choice(options: [
                AskUserEvent.Option(id: "s", label: "Send", value: "send:0"),
                AskUserEvent.Option(id: "c", label: "Cancel", value: "cancel:0"),
            ], allowOther: false),
            expiresAt: nil,
            replyChannel: .buttonResponse
        )
    }

    func test_unanswered_buttons() {
        assertVariants(of: card(event: buttonsEvent), named: "unanswered_buttons")
    }

    func test_answered_echoesChoice() {
        assertVariants(
            of: card(event: buttonsEvent, isAnswered: true, answerSummary: "Send"),
            named: "answered"
        )
    }

    func test_expired() {
        assertVariants(
            of: card(
                event: AskUserEvent(prompt: "Proceed?", kind: .boolean,
                                    expiresAt: Date(timeIntervalSince1970: 1745000000)),
                isExpired: true
            ),
            named: "expired"
        )
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MatronShared --filter AskUserCardSnapshotTests`
Expected: FAIL to compile — `cannot find 'AskUserCard' in scope`.

- [ ] **Step 3: Implement `AskUserCard`**

```swift
import SwiftUI
import MatronEvents

/// Inline, non-blocking rendering of a bot question in the timeline — the
/// replacement for the old `AskUserSheet`/`MacAskUserSheet` modals. Bot-card
/// styling (matches `ToolCallCard`). Two states:
///
/// - **Unanswered:** embeds the shared `AskUserSheetBody` (prompt + inputs +
///   Send). `AskUserSheetBody` already disables its controls + shows the
///   expired notice when `isExpired`.
/// - **Answered:** the prompt plus "✓ You chose: <answerSummary>" (or
///   "✓ Answered" when the specific choice can't be resolved), non-interactive.
///
/// Pure: parameterised on plain values + bindings (no app/service types), so it
/// stays in MatronDesignSystem and snapshots directly.
public struct AskUserCard: View {
    public let event: AskUserEvent
    public let isAnswered: Bool
    public let answerSummary: String?
    @Binding public var textInput: String
    @Binding public var selectedChoiceIDs: Set<String>
    @Binding public var booleanAnswer: Bool?
    public let isSending: Bool
    public let isExpired: Bool
    public let error: String?
    public let onSend: () -> Void

    public init(
        event: AskUserEvent,
        isAnswered: Bool,
        answerSummary: String?,
        textInput: Binding<String>,
        selectedChoiceIDs: Binding<Set<String>>,
        booleanAnswer: Binding<Bool?>,
        isSending: Bool,
        isExpired: Bool,
        error: String? = nil,
        onSend: @escaping () -> Void
    ) {
        self.event = event
        self.isAnswered = isAnswered
        self.answerSummary = answerSummary
        self._textInput = textInput
        self._selectedChoiceIDs = selectedChoiceIDs
        self._booleanAnswer = booleanAnswer
        self.isSending = isSending
        self.isExpired = isExpired
        self.error = error
        self.onSend = onSend
    }

    public var body: some View {
        Group {
            if isAnswered {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.prompt).font(.body)
                    Label {
                        Text(answerSummary.map { "You chose: \($0)" } ?? "Answered")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                // AskUserSheetBody self-pads.
                AskUserSheetBody(
                    event: event,
                    textInput: $textInput,
                    selectedChoiceIDs: $selectedChoiceIDs,
                    booleanAnswer: $booleanAnswer,
                    isSending: isSending,
                    isExpired: isExpired,
                    error: error,
                    onSend: onSend
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter AskUserCardSnapshotTests`
Expected: PASS — "Executed 3 tests, with 0 failures" (pixel comparison skipped via env; the test verifies the card constructs + renders).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/AskUserCard.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/AskUserCardSnapshotTests.swift
git commit -m "feat: AskUserCard — inline ask-user rendering (unanswered/answered/expired)"
```

---

## Task 2: ChatViewModel — per-prompt VM cache + answer summary

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift`
- Modify: `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `ChatViewModelTests` (mirrors the existing `FakeTimelineService` + `start()`/`await task.value` pattern):

```swift
    @MainActor
    func test_askViewModel_isStablePerPrompt() async throws {
        let fake = FakeTimelineService()
        let evt = AskUserEvent(prompt: "Q", kind: .choice(options: [
            AskUserEvent.Option(id: "s", label: "Send", value: "send:0")
        ], allowOther: false), expiresAt: nil, replyChannel: .buttonResponse)
        let prompt = TimelineItem(id: "p1", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p1", evt), isOwn: false)
        fake.snapshotsToEmit = [[prompt]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start(); await task.value

        let first = vm.askViewModel(forPrompt: "p1")
        let second = vm.askViewModel(forPrompt: "p1")
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "same prompt must return the same cached VM")
        XCTAssertNil(vm.askViewModel(forPrompt: "missing"))
    }

    @MainActor
    func test_answerSummary_buttons_mapsValuesToLabels() async throws {
        let fake = FakeTimelineService()
        let evt = AskUserEvent(prompt: "Q", kind: .choice(options: [
            AskUserEvent.Option(id: "s", label: "Send", value: "send:0"),
            AskUserEvent.Option(id: "c", label: "Cancel", value: "cancel:0"),
        ], allowOther: false), expiresAt: nil, replyChannel: .buttonResponse)
        let prompt = TimelineItem(id: "p1", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p1", evt), isOwn: false)
        let answer = TimelineItem(id: "a1", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "p1", selectedValues: ["send:0"]), isOwn: true)
        fake.snapshotsToEmit = [[prompt, answer]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start(); await task.value

        XCTAssertEqual(vm.answerSummary(forPrompt: "p1"), "Send")
        XCTAssertNil(vm.answerSummary(forPrompt: "p1-unanswered"))
    }

    @MainActor
    func test_answerSummary_textReply_returnsReplyBody() async throws {
        let fake = FakeTimelineService()
        let evt = AskUserEvent(prompt: "Workdir?", kind: .text, expiresAt: nil)
        let prompt = TimelineItem(id: "p2", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p2", evt), isOwn: false)
        let reply = TimelineItem(id: "r1", sender: "@me:s", timestamp: .now,
            kind: .text(body: "src/", formattedHTML: nil), isOwn: true,
            sendState: .sent, inReplyToEventID: "p2")
        fake.snapshotsToEmit = [[prompt, reply]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start(); await task.value

        XCTAssertEqual(vm.answerSummary(forPrompt: "p2"), "src/")
    }
```

> Add `import MatronEvents` to the top of `ChatViewModelTests.swift` if not already present (the tests name `AskUserEvent`).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MatronShared --filter ChatViewModelTests`
Expected: FAIL to compile — `value of type 'ChatViewModel' has no member 'askViewModel'` / `'answerSummary'`.

- [ ] **Step 3: Implement the cache + summary**

In `ChatViewModel.swift`, add a stored cache near the other private state (e.g. just above `pendingAsk()`):

```swift
    /// Stable per-prompt `AskUserSheetViewModel` cache. The inline `AskUserCard`
    /// looks its VM up by prompt event ID every render; without caching, a fresh
    /// VM each timeline snapshot would reset the user's in-progress selection /
    /// typing. Keyed by prompt event ID, bounded by the room's open-prompt count
    /// and torn down with the view model (per-room).
    private var askViewModels: [String: AskUserSheetViewModel] = [:]
```

Then add these public methods (next to `makeAskUserSheetViewModel`):

```swift
    /// Returns the stable `AskUserSheetViewModel` for the `.askUser` prompt with
    /// `eventID`, creating + caching it on first use. `nil` if no such prompt is
    /// in the current timeline. Send-success marks the prompt answered (via the
    /// VM's `onClose`) so the inline card flips to its resolved state.
    public func askViewModel(forPrompt eventID: String) -> AskUserSheetViewModel? {
        if let existing = askViewModels[eventID] { return existing }
        guard let event = askEvent(forPrompt: eventID) else { return nil }
        let vm = makeAskUserSheetViewModel(eventID: eventID, event: event) { [weak self] in
            self?.markPromptAnswered(eventID)
        }
        askViewModels[eventID] = vm
        return vm
    }

    /// The chosen answer for `promptEventID`, for the card's resolved state, or
    /// `nil` if not yet answered. Buttons: maps the hidden `.askUserAnswer`
    /// `selectedValues` back to option labels via the prompt's options (so
    /// cross-device answers display). Text channel: the reply message body.
    public func answerSummary(forPrompt promptEventID: String) -> String? {
        for item in items {
            if case .askUserAnswer(let pid, let values) = item.kind,
               pid == promptEventID, item.isOwn {
                return mapValuesToLabels(values, promptEventID: promptEventID)
            }
        }
        for item in items where item.isOwn && item.inReplyToEventID == promptEventID {
            if case .text(let body, _) = item.kind { return body }
        }
        return nil
    }

    /// The `AskUserEvent` for a prompt event ID, scanned from the timeline.
    private func askEvent(forPrompt eventID: String) -> AskUserEvent? {
        for item in items {
            if case .askUser(let id, let evt) = item.kind, id == eventID { return evt }
        }
        return nil
    }

    private func mapValuesToLabels(_ values: [String], promptEventID: String) -> String {
        var labelByValue: [String: String] = [:]
        if let evt = askEvent(forPrompt: promptEventID) {
            switch evt.kind {
            case .choice(let options, _), .multiChoice(let options, _):
                for opt in options { labelByValue[opt.value] = opt.label }
            case .text, .boolean:
                break
            }
        }
        return values.map { labelByValue[$0] ?? $0 }.joined(separator: ", ")
    }
```

> `items`, `markPromptAnswered`, and `makeAskUserSheetViewModel` already exist on `ChatViewModel`. `AskUserSheetViewModel` is a `class` so `===` identity holds for the cache test.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path MatronShared --filter ChatViewModelTests`
Expected: PASS — all `ChatViewModelTests` including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/ChatViewModel.swift \
        MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift
git commit -m "feat: ChatViewModel per-prompt ask VM cache + answerSummary for inline cards"
```

---

## Task 3: iOS — render inline card, remove the sheet

**Files:**
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift`
- Modify: `Matron/Features/Chat/ChatView.swift`
- Delete: `Matron/Features/Chat/Rendering/AskUserSheet.swift`

- [ ] **Step 1: Add ask closures + inline card to `TimelineItemView`**

Add `import MatronViewModels` to the imports. Add three optional closures alongside the existing `onTapFile` property:

```swift
    /// Phase: inline ask-user. Resolves the stable per-prompt
    /// `AskUserSheetViewModel` (nil for previews/tests without a ChatViewModel).
    var askViewModel: ((String) -> AskUserSheetViewModel?)? = nil
    /// Whether the prompt with this event ID has been answered.
    var isPromptAnswered: ((String) -> Bool)? = nil
    /// The chosen-answer summary for an answered prompt (nil = not answered).
    var answerSummary: ((String) -> String?)? = nil
```

Replace the `.askUser` case (the centered pill) with the inline card:

```swift
        case .askUser(let eventID, let evt):
            HStack {
                askCard(eventID: eventID, event: evt)
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: "Question: \(evt.prompt)"))
```

Add a private builder + a `@Bindable` host subview at the end of the file (above the closing brace of `TimelineItemView` for the builder; the host as a sibling `private struct`):

```swift
    @ViewBuilder
    private func askCard(eventID: String, event: AskUserEvent) -> some View {
        if let askViewModel, let isPromptAnswered, let answerSummary,
           let vm = askViewModel(eventID) {
            AskUserCardHost(
                viewModel: vm,
                isAnswered: isPromptAnswered(eventID),
                answerSummary: answerSummary(eventID)
            )
        } else {
            // Previews / tests without a ChatViewModel: static, non-interactive.
            AskUserCard(
                event: event, isAnswered: false, answerSummary: nil,
                textInput: .constant(""), selectedChoiceIDs: .constant([]),
                booleanAnswer: .constant(nil),
                isSending: false, isExpired: false, error: nil, onSend: {}
            )
        }
    }
```

```swift
/// Binds a cached `AskUserSheetViewModel` to the shared `AskUserCard`. Separate
/// `@Bindable` view because property wrappers can't be declared inline in a
/// `@ViewBuilder` switch.
private struct AskUserCardHost: View {
    @Bindable var viewModel: AskUserSheetViewModel
    let isAnswered: Bool
    let answerSummary: String?

    var body: some View {
        AskUserCard(
            event: viewModel.event,
            isAnswered: isAnswered,
            answerSummary: answerSummary,
            textInput: $viewModel.textInput,
            selectedChoiceIDs: $viewModel.selectedChoiceIDs,
            booleanAnswer: $viewModel.booleanAnswer,
            isSending: viewModel.isSending,
            isExpired: viewModel.isExpired,
            error: viewModel.error,
            onSend: { Task { await viewModel.send() } }
        )
    }
}
```

> If the compiler reports `AskUserEvent` unresolved in `askCard(...)`, add `import MatronEvents` too.

- [ ] **Step 2: Wire the closures from `ChatView`; remove the sheet**

In `ChatView.swift`, extend the `TimelineItemView(...)` call (in the `.message(let item)` branch) with:

```swift
                                askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                                isPromptAnswered: { viewModel.isPromptAnswered($0) },
                                answerSummary: { viewModel.answerSummary(forPrompt: $0) }
```

Delete the `pendingAskPrompt` state declaration:

```swift
    @State private var pendingAskPrompt: AskUserPromptContext?
```

Delete the ask-user `.onChange(of: viewModel.items)` modifier (the block that reads/sets `pendingAskPrompt` — **not** the `.onChange(of: scenePhase)` one), the entire `.sheet(item: askUserSheetBinding, onDismiss:) { ... AskUserSheet ... }` modifier, and the `askUserSheetBinding` computed property + `closeAskUserSheet(_:)` method.

- [ ] **Step 3: Delete the iOS sheet wrapper**

```bash
git rm Matron/Features/Chat/Rendering/AskUserSheet.swift
```

- [ ] **Step 4: Build + run iOS tests**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. If a test references `AskUserSheet`, repoint or delete it (grep: `grep -rl AskUserSheet Matron MatronTests`).

```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Matron/ ; git commit -m "feat: render ask-user prompts inline on iOS; remove the sheet"
```

---

## Task 4: Mac — render inline card, remove the sheet

**Files:**
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift`
- Modify: `MatronMac/Features/Chat/MacChatView.swift`
- Delete: `MatronMac/Features/Chat/MacAskUserSheet.swift`

- [ ] **Step 1: Add ask closures + inline card to `MacTimelineItemView`**

Add `import MatronViewModels`. Add the same three optional closures (`askViewModel`, `isPromptAnswered`, `answerSummary`) as in Task 3 Step 1. Replace the `.askUser` pill case with the same `HStack { askCard(eventID:event:) … }` block, and add the identical `askCard(...)` `@ViewBuilder` to `MacTimelineItemView`.

Reuse the `AskUserCardHost` from Task 3 by making it non-private and shared, OR (simpler, no cross-target sharing) add an identical `private struct MacAskUserCardHost: View` to this file with the same body. Use `MacAskUserCardHost` here.

```swift
private struct MacAskUserCardHost: View {
    @Bindable var viewModel: AskUserSheetViewModel
    let isAnswered: Bool
    let answerSummary: String?

    var body: some View {
        AskUserCard(
            event: viewModel.event,
            isAnswered: isAnswered,
            answerSummary: answerSummary,
            textInput: $viewModel.textInput,
            selectedChoiceIDs: $viewModel.selectedChoiceIDs,
            booleanAnswer: $viewModel.booleanAnswer,
            isSending: viewModel.isSending,
            isExpired: viewModel.isExpired,
            error: viewModel.error,
            onSend: { Task { await viewModel.send() } }
        )
    }
}
```

(`askCard(...)` references `MacAskUserCardHost` instead of `AskUserCardHost`.)

- [ ] **Step 2: Wire closures from `MacChatView`; remove the sheet**

In `MacChatView.swift`, extend the `MacTimelineItemView(...)` call with the same three `askViewModel` / `isPromptAnswered` / `answerSummary` closures. Delete the `pendingAskPrompt` state, the ask `.onChange(of: viewModel.items)` modifier (not the `scenePhase` one), the `.sheet(item: askUserSheetBinding, onDismiss:) { ... MacAskUserSheet ... }` modifier, and the `askUserSheetBinding` + `closeAskUserSheet(_:)` members.

- [ ] **Step 3: Delete the Mac sheet wrapper**

```bash
git rm MatronMac/Features/Chat/MacAskUserSheet.swift
```

- [ ] **Step 4: Build + run Mac unit tests**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. If a Mac test references `MacAskUserSheet`, repoint/delete it (grep: `grep -rl MacAskUserSheet MatronMac MatronMacTests`).

```bash
MATRON_SKIP_SNAPSHOT_TESTS=1 TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
xcodebuild test -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```
Expected: `** TEST SUCCEEDED **`. (Scope to `MatronMacTests`: the full scheme's unsigned XCUITest runner trips Gatekeeper locally — see the project memory.)

- [ ] **Step 5: Commit**

```bash
git add MatronMac/ ; git commit -m "feat: render ask-user prompts inline on Mac; remove the sheet"
```

---

## Task 5: Full verification + manual-test doc

**Files:**
- Modify: `manual-tests.md`

- [ ] **Step 1: Full SPM suite**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: "0 failures". (Existing `AskUserSheetBody` + `AskUserSheetViewModel` tests still pass — both are reused.)

- [ ] **Step 2: Update `manual-tests.md`**

Replace the Phase 5 "Ask-user sheet — iOS" / "Ask-user sheet — Mac" checklist sections with inline-card equivalents:

```markdown
### Ask-user inline cards — iOS

- [ ] Bot asks a buttons question (e.g. queue a message → "message queued" with Cancel/Send) → an **inline card** appears in the timeline (NOT a sheet); the chat stays scrollable behind it.
- [ ] Pick an option → Send → the card flips to "✓ You chose: <label>"; no raw `value1, value2` text bubble appears.
- [ ] A second prompt arrives while the first is unanswered → both cards show inline; answering one doesn't disturb the other.
- [ ] Free-text ask_user → inline text field in the card; Send posts an `m.in_reply_to` reply; card resolves to "✓ You chose: <text>".
- [ ] Expired prompt → card controls disabled + "This question has expired."; no card pops as a modal.
- [ ] Answer a prompt on another device → this device's card flips to the resolved state within seconds (no sheet, no re-pop).

### Ask-user inline cards — Mac

- [ ] Same inline-card behaviour as iOS (no fixed-size sheet); the detail column stays interactive.
- [ ] Buttons / free-text / boolean / expired all render + resolve inline.
```

- [ ] **Step 3: Commit**

```bash
git add manual-tests.md
git commit -m "docs: phase ask-user inline-card manual tests"
```

- [ ] **Step 4: Finish the branch**

Use superpowers:finishing-a-development-branch (verify tests, present merge/PR options).

---

## Self-review

- **Spec §AskUserCard:** Task 1 (3 states; `isAnswered` echoes `answerSummary`; expired handled by `AskUserSheetBody`). ✓
- **Spec §ChatViewModel (VM cache + answerSummary):** Task 2 — `askViewModel(forPrompt:)` (stable, `===`-tested), `answerSummary(forPrompt:)` (buttons value→label + text-reply body). ✓
- **Spec §Remove sheet path:** Tasks 3 + 4 delete `AskUserSheet`/`MacAskUserSheet`, the `pendingAskPrompt` state, the ask `.onChange(of: items)`, the `.sheet`, `askUserSheetBinding`, `closeAskUserSheet` on both platforms. `pendingAsk`/`isPromptAnswered`/`markPromptAnswered`/`makeAskUserSheetViewModel` kept. ✓
- **Spec §Timeline rendering:** Tasks 3 + 4 swap the `.askUser` pill for `AskUserCard` via the `AskUserCardHost`/`MacAskUserCardHost` + closures, bot-aligned like `.toolCall`. ✓
- **Spec §Tests:** `AskUserCardSnapshotTests` (Task 1); `ChatViewModel` cache + summary tests (Task 2); existing `AskUserSheetBody`/`AskUserSheetViewModel` tests retained; deleted-wrapper test grep in Tasks 3/4. ✓
- **Type consistency:** `askViewModel(forPrompt:) -> AskUserSheetViewModel?`, `answerSummary(forPrompt:) -> String?`, `isPromptAnswered(_:) -> Bool` used identically in VM, both timeline views, and both chat views. `AskUserCard` init signature matches between the card definition, snapshot tests, both hosts, and both fallbacks.
- **Placeholders:** none — every step has concrete code or an exact command.
