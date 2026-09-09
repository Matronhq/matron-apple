# App shell: tabs, Decisions, tasks page, Mac nav — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace conversation-as-the-main-interface with an app shell: iOS bottom tabs (Coordinator, Conversations, Decisions), a cross-conversation Decisions list with a live badge on both platforms, an Instagram-style horizontal tasks page inside the iOS chat (replacing the right-edge drawer), a Slack-style big-icon navigation column on the Mac, and a per-user Coordinator conversation setting — with the floating Make task pill removed first.

**Architecture:** `ItemsPanelViewModel` gains an all-conversations mode (`convoID: nil`) plus a scope-independent `awaitingYou` list fed by a dedicated `.all` store subscription; one such instance per signed-in session lives in the shell (`AppShellView` on iOS, `MacChatListView` on Mac) and feeds both the Decisions list (`DecisionsListView`, a pure DesignSystem view) and the badge. iOS navigation state is hoisted into an `@Observable` `AppShellNavigation` (tab + three paths) so deep links and cross-tab pushes are pure, testable functions; item detail rides the existing `[String]` chat stack via `ItemRoute.pathValue`. The chat screen's content becomes a two-page horizontal paging `ScrollView` (`ChatPager`) driven by `ChatPagerModel`. On the Mac a `MacNavColumn` (72pt) is prepended inside the sidebar column so the existing `navigationSplitViewColumnWidth` plumbing and tests keep their meaning. `CoordinatorSetting` (MatronModels) stores the coordinator convo id per user in `UserDefaults`.

**Tech Stack:** Swift 5.10 language mode / SwiftUI (iOS 18, macOS 15 floors), SwiftPM package `MatronShared` (XCTest + swift-snapshot-testing), xcodegen-generated `Matron.xcodeproj` (targets `Matron`, `MatronMac`, `MatronTests`, `MatronMacTests`).

**Spec:** docs/superpowers/specs/2026-09-09-app-shell-tabs-design.md

## Global Constraints

- Never stage `Matron/App/Info.plist` (xcodegen rewrites it); check `git status` before every `git add` and add files by name only.
- Run `xcodegen generate` after adding, moving, or deleting any file under `Matron/`, `MatronMac/`, `MatronTests/`, or `MatronMacTests/` (they are directory-globbed). Files under `MatronShared/` need no project change.
- Commit with `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "<subject>" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`. Never `git add -A` or `git add .`.
- Mac tests ALWAYS: `MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests` (drop `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1` only in the snapshot-recording steps that say so).
- iOS tests: `xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/ios-sim -only-testing:MatronTests`.
- SPM tests: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` (add `--filter <ClassName>` for a single suite). Snapshot tests run with the flag OFF and are recorded twice: the first run writes the baselines and fails with "No reference was found on disk. Automatically recorded snapshot", the second run passes; then `git add` the new `__Snapshots__/<TestClass>/*.png` files (naming: `<testMethod>.mac-<name>-{light,dark,axxxl}.png`, same as `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests/`).
- A test run is green only when the output ends with `Executed N tests, with 0 failures` (read the line; do not judge by `grep | tail`). Never claim green without the output.
- No nested `NavigationStack` inside a pushed destination on iOS (iOS 26 pops the outer stack — PR #188); every new iOS push goes on the tab's own stack.
- The chat stack stays `[String]` (`chatNavigationPath` is `Binding<[String]>?`; `SubChatStripViewModel.pathReplacingCurrentChild` and `pushSpawnedRoom` need array semantics). Item detail on that stack is pushed as `ItemRoute(id:).pathValue` (`"item/<id>"`), decoded by `ItemRoute(pathValue:)` in the `String` destination.
- Module rules: `MatronModels` is Foundation-only; `MatronDesignSystem` depends on Models/Events/Search only (never ViewModels/Journal); `MatronViewModels` depends on Chat/Journal/Models.
- One PR per Rollout entry, each green on its own, branches stacked in order: `remove-make-task-pill` → `items-vm-all-mode` → `ios-shell-tabs` → `ios-tasks-pager` → `mac-nav-column` → `coordinator-tab`. Start each PR with `git checkout -b <branch>` from the previous PR's branch (PR 0 from the current `app-shell-tabs` HEAD).
- Deviations from the spec text, all deliberate: (1) iOS gets the Coordinator tab in PR 5 (the spec's PR 5 line says "iOS Coordinator tab"); PR 2 ships Conversations + Decisions. (2) The Mac Coordinator entry ships in PR 4 with placeholder detail content and gets its real content in PR 5, exactly as the spec's rollout says. (3) The Coordinator tab's root chat keeps the tab bar visible — hiding it at the root (spec §3) would leave no way to leave the tab; pushed chats/items under it hide the bar like everywhere else. (4) The tasks page's `+` stays in `ItemsListView`'s own header (it already has one); the toolbar shows the return-to-chat button and ⓘ.

---

## PR 0 — `remove-make-task-pill` (spec §5a)

### Task 1: Remove the Make task rules from `ComposerViewModel` (SPM)

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ComposerViewModel.swift` (lines 76–129 pill state/gates; init 186–202; lines 204–298 items-support subscription + notice timer; `makeTask()` + `uploadStagedAttachmentsForTask` ≈ lines 566–696; `clearComposerAfterSend` lines 712–732)
- Modify: `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift` (lines 1401–1917: `// MARK: - Make task (Task 12)`, `FakeItemsSync`, and every `testMakeTask*` / `testCanMakeTask*` / `testStartItemsSupport*` / `testStopItemsSupport*` / `testFiledTaskNotice*` test; helper `ComposerWaitTimeoutError`/`waitUntil` lines 1920–1934)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ComposerViewModel.init(roomID: String, timeline: TimelineService, commands: [BotCommand], recentFolders: RecentStartFolders = RecentStartFolders(), sessionStatus: @escaping @MainActor () -> SessionStatus? = { nil })` — the `items:` and `itemsUpload:` parameters are gone, as are `canMakeTask`, `makeTask()`, `lastFiledTaskNotice`, `itemsSupported`, `itemsSupportGeneration`, `startItemsSupport()`, `stopItemsSupport(ifGeneration:)`, `stopItemsSupport()`, `isFilingTask`.

- [ ] **Step 1: Delete the Make task tests**

  In `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift` delete everything from the line `    // MARK: - Make task (Task 12)` (line 1401) through the closing brace of `testMakeTask_forgetsDraftMemoryOnSuccess` (line 1917), leaving the class's closing `}` (line 1918). Then run `grep -n "waitUntil\|ComposerWaitTimeoutError" MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift`; if the only remaining hits are the helper's own definition (lines 1920–1934), delete those lines too.

- [ ] **Step 2: Run the suite to see the remaining tests still compile against the OLD API**

  `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ComposerViewModelTests`
  Expected: `Executed N tests, with 0 failures` (N is the pre-existing count minus the 20 deleted tests). This proves nothing outside the deleted block referenced the pill API.

- [ ] **Step 3: Remove the view-model code**

  In `MatronShared/Sources/ViewModels/ComposerViewModel.swift`:
  1. Delete lines 76–129: from `    /// The items-tracker sync engine, or \`nil\` when the tracker feature is` through the closing `}` of `private var isCommandDraft: Bool`. (`canSend`, lines 69–74, stays.)
  2. Replace the init (lines 186–202) with:
     ```swift
         public init(
             roomID: String,
             timeline: TimelineService,
             commands: [BotCommand],
             recentFolders: RecentStartFolders = RecentStartFolders(),
             sessionStatus: @escaping @MainActor () -> SessionStatus? = { nil }
         ) {
             self.roomID = roomID
             self.timeline = timeline
             self.commands = commands
             self.recentFolders = recentFolders
             self.sessionStatus = sessionStatus
         }
     ```
  3. Delete lines 204–298: from `    /// Monotonic token identifying the current tracker-support` through the closing `}` of `private func showFiledTaskNotice()`. The next surviving line is `    /// Whether the slash palette should be visible. True when the input is`.
  4. Delete `makeTask()` and `uploadStagedAttachmentsForTask(_:)`: search for `public func makeTask() async {`, delete its contiguous `///` doc block above it (starts `/// Files the composer` — verify by reading) and everything through the closing `}` of `private func uploadStagedAttachmentsForTask` (line 696 today). The next surviving doc line is `    /// Puts the user's text back after a failed send`.
  5. In `clearComposerAfterSend()` (line 722 today) delete the three lines `lastFiledTaskNotice = nil`, `noticeTask?.cancel()`, `noticeTask = nil`, and rewrite its doc comment to:
     ```swift
         /// The optimistic post-send clear: wipes the text, the tray, and the
         /// history/palette bookkeeping that goes with a fresh composer, and
         /// forgets the per-room draft. Callers snapshot whatever they still
         /// need (the pending text for `restoreInput`, the staged attachments
         /// to delete their temp copies) BEFORE calling this — it clears both.
     ```
  6. `grep -n "items\b\|itemsUpload\|noticeTask\|lastFiledTaskNotice\|itemsSupported\|canMakeTask\|makeTask" MatronShared/Sources/ViewModels/ComposerViewModel.swift` must print nothing.

- [ ] **Step 4: Run the whole SPM suite**

  `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
  Expected: builds clean and ends `Executed N tests, with 0 failures`.

- [ ] **Step 5: Commit**

  ```
  git checkout -b remove-make-task-pill
  git add MatronShared/Sources/ViewModels/ComposerViewModel.swift MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "composer: drop the Make task rules from the view model" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 2: Remove the pill from both composers and DesignSystem

**Files:**
- Delete: `MatronShared/Sources/DesignSystem/Items/MakeTaskPill.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/MakeTaskPillSnapshotTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MakeTaskPillSnapshotTests/` (three PNGs)
- Modify: `Matron/Features/Chat/Composer/ComposerView.swift` (state lines 21–26; `.task` lines 167–174; `onDisappear` line 186; overlay lines 204–250)
- Modify: `MatronMac/Features/Chat/MacComposerView.swift` (state lines 31–35; overlay branches lines 139–162 and `.animation` line 165; `.task` lines 180–187; `onDisappear` line 208)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (`ChatVMCache.viewModels` lines 606–615), `MatronMac/Features/ChatList/MacChatListView.swift` (lines 601–610)
- Test: `MatronTests/ComposerViewBindingTests.swift`, `MatronMacTests/*` (existing; must stay green)

**Interfaces:**
- Consumes: `ComposerViewModel.init` from Task 1.
- Produces: none (removal).

- [ ] **Step 1: Delete the pill and its snapshot test**

  ```
  git rm MatronShared/Sources/DesignSystem/Items/MakeTaskPill.swift MatronShared/Tests/DesignSystemSnapshotTests/MakeTaskPillSnapshotTests.swift
  git rm -r MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MakeTaskPillSnapshotTests
  ```

- [ ] **Step 2: Build the iOS app to see the expected failure**

  `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO`
  Expected: errors `cannot find 'MakeTaskPill' in scope` in `ComposerView.swift` and `extra arguments at positions #5, #6 in call` in `ChatListView.swift`.

- [ ] **Step 3: iOS composer**

  In `Matron/Features/Chat/Composer/ComposerView.swift`:
  1. Delete lines 21–26 (`/// Fix wave, item I4 …` through `@State private var itemsSupportGeneration = 0`).
  2. In the `.task { … }` at lines 162–175 delete lines 167–174 (the comment block and `itemsSupportGeneration = viewModel.startItemsSupport()`), leaving only the draft restore.
  3. In `.onDisappear` delete line 186 `viewModel.stopItemsSupport(ifGeneration: itemsSupportGeneration)`.
  4. Replace `composerBar` (lines 195–251) with:
     ```swift
         private var composerBar: some View {
             VStack(spacing: 0) {
                 // Above the input, so what's about to be sent sits next to the
                 // words being written about it.
                 AttachmentTray(attachments: viewModel.stagedAttachments) { id in
                     viewModel.removeAttachment(id: id)
                 }
                 inputRow
             }
         }
     ```
  5. In `Matron/Features/ChatList/ChatListView.swift` replace lines 606–615 with:
     ```swift
             let pair = (
                 chat: chat,
                 composer: ComposerViewModel(roomID: roomID, timeline: timelineSvc,
                                             commands: BotCommandCatalog.claudeBridge,
                                             sessionStatus: { [weak chat] in chat?.sessionStatus })
             )
     ```

- [ ] **Step 4: Mac composer**

  In `MatronMac/Features/Chat/MacComposerView.swift`:
  1. Delete lines 31–35 (`/// Fix wave, item I4 …` through `@State private var itemsSupportGeneration = 0`).
  2. Replace the overlay's `ZStack { … }` body (lines 129–163) so it only hosts the palette:
     ```swift
             ZStack {
                 if viewModel.showPalette {
                     MacSlashCommandPalette(
                         commands: viewModel.filteredCommands,
                         suggestions: viewModel.paletteSuggestions,
                         selection: viewModel.paletteSelection,
                         onSelect: { cmd in viewModel.selectCommand(cmd) },
                         onSelectSuggestion: { suggestion in viewModel.selectSuggestion(suggestion) }
                     )
                     .padding(.horizontal)
                 }
             }
             .alignmentGuide(.top) { $0[.bottom] + 4 }
             .animation(.easeInOut(duration: 0.18), value: viewModel.showPalette)
             .animation(.easeInOut(duration: 0.18), value: viewModel.sendError != nil)
     ```
     (the `.animation(…, value: viewModel.canMakeTask)` line is gone).
  3. In the `.task` at lines 175–188 delete lines 180–187 (comment + `itemsSupportGeneration = viewModel.startItemsSupport()`).
  4. In `.onDisappear` delete line 208 `viewModel.stopItemsSupport(ifGeneration: itemsSupportGeneration)`.
  5. In `MatronMac/Features/ChatList/MacChatListView.swift` replace lines 601–610 with:
     ```swift
             let pair = (
                 chat: chat,
                 composer: ComposerViewModel(roomID: roomID, timeline: timelineSvc,
                                             commands: BotCommandCatalog.claudeBridge,
                                             sessionStatus: { [weak chat] in chat?.sessionStatus })
             )
     ```
  6. `grep -rn "MakeTaskPill\|canMakeTask\|makeTask\|lastFiledTaskNotice\|itemsSupportGeneration\|ItemsSupport" Matron MatronMac MatronShared/Sources` must print nothing.

- [ ] **Step 5: Run everything**

  1. `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` → `Executed N tests, with 0 failures`.
  2. `xcodegen generate` (a source file was deleted from the SPM package only, but regenerate anyway so the project is fresh).
  3. `xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/ios-sim -only-testing:MatronTests` → `Executed N tests, with 0 failures`.
  4. `MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests` → `Executed N tests, with 0 failures`.

- [ ] **Step 6: Commit and open PR 0**

  ```
  git add Matron/Features/Chat/Composer/ComposerView.swift MatronMac/Features/Chat/MacComposerView.swift Matron/Features/ChatList/ChatListView.swift MatronMac/Features/ChatList/MacChatListView.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "composer: remove the floating Make task pill on iOS and Mac" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  Push and open the PR titled `Remove the Make task pill` against `main` (body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).

---

## PR 1 — `items-vm-all-mode` (spec §1, §2)

### Task 3: `ItemsPanelViewModel` all-conversations mode + `awaitingYou`

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift` (protocol lines 10–18; `convoID` line 96; `needsYouCount` lines 99–102; init lines 120–122; `start`/`stop` lines 149–177; `resubscribe` lines 179–207; `create` lines 253–258)
- Test: `MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift` (fake lines 6–14; new tests appended before the class's closing brace at line 224)

**Interfaces:**
- Consumes: `TrackerItem.needsUser`, `ItemsScope`.
- Produces:
  ```swift
  public protocol ItemsStoreReading: Sendable {
      // …existing five requirements…
      /// Every conversation's items, regardless of the panel's scope — feeds `awaitingYou`.
      func needsUserStream() -> AsyncStream<[TrackerItem]>
  }
  public extension ItemsStoreReading {
      func needsUserStream() -> AsyncStream<[TrackerItem]> { itemsStream(scope: .all) }
  }
  public final class ItemsPanelViewModel {
      public let convoID: String?
      public private(set) var awaitingYou: [TrackerItem]
      public var awaitingYouCount: Int { awaitingYou.count }
      public init(convoID: String?, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing)
  }
  ```

- [ ] **Step 1: Write the failing tests**

  In `MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift` replace the fake store (lines 6–14) with:
  ```swift
  private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
      var cont: AsyncStream<[TrackerItem]>.Continuation?
      var createsCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
      /// The scope-independent stream `awaitingYou` reads — separate from
      /// `cont` so a test can drive the two independently.
      var awaitingCont: AsyncStream<[TrackerItem]>.Continuation?
      func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { self.cont = $0 } }
      func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
      func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
      func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
      func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.createsCont = $0 } }
      func needsUserStream() -> AsyncStream<[TrackerItem]> { AsyncStream { self.awaitingCont = $0 } }
  }
  ```
  Append these tests inside the class (before line 224's `}`):
  ```swift
      // MARK: - App shell: all-conversations mode (spec §1)

      func testNilConvoStartsInAllScope() {
          let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync())
          XCTAssertNil(vm.convoID)
          XCTAssertEqual(vm.scope, .all)
          XCTAssertEqual(vm.needsYouCount, 0)
      }

      func testAwaitingYouIsCrossConversationNewestFirstRegardlessOfScope() async throws {
          let store = FakeItemsStore(); let sync = FakeSync()
          let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
          vm.start()
          try await waitUntil { store.awaitingCont != nil }
          XCTAssertEqual(vm.scope, .convo("c1"), "the panel's own scope is untouched by the awaiting stream")
          let mine = t("q", num: 1, kind: .question, awaiting: .user, rank: 1)   // updatedAt = 1
          let withAgent = t("a", num: 2, rank: 2)                                // awaiting .agent → excluded
          let foreign = TrackerItem(id: "f", num: 9, kind: .decision, awaiting: .user, rank: 1, title: "F",
                                    originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 9))
          store.awaitingCont?.yield([mine, withAgent, foreign])
          try await waitUntil { vm.awaitingYouCount == 2 }
          XCTAssertEqual(vm.awaitingYou.map(\.id), ["f", "q"], "needsUser only, newest updatedAt first, every conversation")
          XCTAssertEqual(vm.needsYouCount, 0, "the per-conversation badge only follows the scoped stream")
      }

      func testAwaitingYouCountTracksStoreEmits() async throws {
          let store = FakeItemsStore(); let sync = FakeSync()
          let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
          vm.start()
          try await waitUntil { store.awaitingCont != nil }
          store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
          try await waitUntil { vm.awaitingYouCount == 1 }
          store.awaitingCont?.yield([])
          try await waitUntil { vm.awaitingYouCount == 0 }
          vm.stop()
          store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
          try? await Task.sleep(nanoseconds: 50_000_000)
          XCTAssertEqual(vm.awaitingYouCount, 0, "stop() cancels the awaiting subscription too")
      }

      func testNeedsYouCountStillPerConversationWhenConvoIDSet() async throws {
          let store = FakeItemsStore(); let sync = FakeSync()
          let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
          vm.start()
          try await waitUntil { store.cont != nil }
          let foreign = TrackerItem(id: "f", num: 9, kind: .question, awaiting: .user, rank: 1, title: "F", originConvoID: "c2")
          store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), foreign])
          try await waitUntil { vm.sections.needsYou.count == 2 }
          XCTAssertEqual(vm.needsYouCount, 1)
      }

      func testCreateWithoutConversationSurfacesAnError() async {
          let sync = FakeSync()
          let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: sync)
          await vm.create(kind: .task, title: "Do X", body: "")
          XCTAssertTrue(sync.created.isEmpty)
          XCTAssertNotNil(vm.error)
      }
  ```

- [ ] **Step 2: Run to see them fail**

  `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsPanelViewModelTests`
  Expected: compile errors — `cannot convert value of type 'String?' to expected argument type 'String'` (the `nil` convoID), `value of type 'ItemsPanelViewModel' has no member 'awaitingYouCount'`.

- [ ] **Step 3: Implement**

  In `MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift`:
  1. Add to the protocol (after `itemOutboxCreatesStream()`, before the closing `}` at line 17):
     ```swift
         /// Every conversation's items regardless of the panel's scope — the
         /// source of `ItemsPanelViewModel.awaitingYou` (app shell, spec §1).
         /// Defaulted to `itemsStream(scope: .all)` below so `JournalStore`
         /// needs no new query; fakes override it to drive it separately.
         func needsUserStream() -> AsyncStream<[TrackerItem]>
     ```
     and after `extension JournalStore: ItemsStoreReading {}`:
     ```swift
     public extension ItemsStoreReading {
         func needsUserStream() -> AsyncStream<[TrackerItem]> { itemsStream(scope: .all) }
     }
     ```
  2. Replace line 96 `public let convoID: String` with:
     ```swift
         /// The home conversation, or `nil` for the app-wide Decisions instance
         /// (spec §1): `nil` starts `scope` at `.all`, disables `create` (no
         /// conversation to file into) and leaves `needsYouCount` at zero.
         public let convoID: String?
     ```
  3. After `needsYouCount` (line 102) add:
     ```swift
         /// Every open item awaiting the user across ALL conversations, newest
         /// `updatedAt` first — independent of `scope`, fed by its own
         /// `needsUserStream()` subscription. Backs the Decisions list and the
         /// tab / nav badge (spec §1, §2).
         public private(set) var awaitingYou: [TrackerItem] = []
         public var awaitingYouCount: Int { awaitingYou.count }
     ```
  4. Add `private var awaitingTask: Task<Void, Never>?` next to the other task properties (after line 118).
  5. Replace the init (lines 120–122) with:
     ```swift
         public init(convoID: String?, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
             self.convoID = convoID
             self.scope = convoID.map { .convo($0) } ?? .all
             self.store = store; self.api = api; self.sync = sync
         }
     ```
  6. In `start()` (line 149) after `resubscribe()` add:
     ```swift
             awaitingTask = Task { [weak self] in
                 guard let stream = self?.store.needsUserStream() else { return }
                 for await items in stream {
                     guard let self, !Task.isCancelled else { return }
                     self.awaitingYou = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
                 }
             }
     ```
  7. In `stop()` add `awaitingTask?.cancel(); awaitingTask = nil` as the first line.
  8. In `resubscribe()` replace line 187 with:
     ```swift
                 self.needsYouCount = self.convoID.map { home in self.sections.needsYou.filter { $0.originConvoID == home }.count } ?? 0
     ```
     and replace lines 191 + 200 (`let convoID = convoID` and the `if case .convo = scope, payload.convoID != convoID { return nil }`) with a scope-derived filter: delete line 191 and change line 200 to
     ```swift
                     if case .convo(let home) = scope, payload.convoID != home { return nil }
     ```
  9. In `create(kind:title:body:)` (line 253) add as the first statement:
     ```swift
             guard let convoID else { error = "Open a chat's tracker to file a new item."; return }
     ```

- [ ] **Step 4: Run the full SPM suite**

  `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
  Expected: `Executed N tests, with 0 failures` (N = previous + 5).

- [ ] **Step 5: Commit**

  ```
  git checkout -b items-vm-all-mode
  git add MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "items: panel VM gains an all-conversations mode and a cross-chat awaitingYou list" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 4: Optional `convoID` through `ItemsListView` and both `AppDependencies`

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/Items/ItemsListView.swift` (lines 41, 48–53, 58–77)
- Modify: `Matron/App/AppDependencies.swift` (lines 319–323), `MatronMac/App/AppDependencies.swift` (lines 265–269)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift` (append), `MatronTests/AppDependenciesTests.swift` (append), `MatronMacTests/MacAppDependenciesTests.swift` (append)

**Interfaces:**
- Consumes: Task 3's init.
- Produces:
  ```swift
  // ItemsListView
  public init(model: Model, scope: Binding<ItemsScope>, convoID: String?, thumbnail: @escaping (TrackerItem) -> Image?,
              onSelect: @escaping (TrackerItem) -> Void, onMove: @escaping (String, Int) -> Void,
              onCreate: @escaping () -> Void, onOpenConversation: @escaping (String) -> Void)
  // both AppDependencies
  @MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String?) -> ItemsPanelViewModel
  @MainActor func makeDecisionsViewModel(for session: UserSession) -> ItemsPanelViewModel
  ```

- [ ] **Step 1: Failing snapshot test (SPM)**

  Append to `ItemsListSnapshotTests`:
  ```swift
      /// App shell (spec §1): with no home conversation the "This chat / All"
      /// picker is meaningless and is hidden; only the refresh spinner and
      /// the `+` remain in the header.
      func testNoConversationHidesScopePicker() {
          let model = ItemsListView.Model(needsYou: [], tasks: [], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: true)
          let view = ItemsListView(model: model, scope: .constant(.all), convoID: nil, thumbnail: { _ in nil },
                                   onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
              .frame(width: 360, height: 200)
          assertVariants(of: view, named: "ItemsList_noConvo")
      }
  ```
  Run `swift test --package-path MatronShared --filter ItemsListSnapshotTests` → compile error `'nil' is not compatible with expected argument type 'String'`.

- [ ] **Step 2: Implement `ItemsListView`**

  Change line 41 to `let convoID: String?` and the init's `convoID: String` parameter to `convoID: String?`. Replace the header's picker (lines 60–65) with:
  ```swift
              if let convoID {
                  Picker("Scope", selection: Binding(get: { isAll ? 1 : 0 }, set: { scope = $0 == 1 ? .all : .convo(convoID) })) {
                      Text("This chat").tag(0)
                      Text("All").tag(1)
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
              } else {
                  Spacer(minLength: 0)
              }
  ```

- [ ] **Step 3: Record the snapshot twice and run the SPM suite**

  `swift test --package-path MatronShared --filter ItemsListSnapshotTests` (first run records `testNoConversationHidesScopePicker.mac-ItemsList_noConvo-{light,dark,axxxl}.png` and fails), run it again → `Executed 5 tests, with 0 failures`. Then `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` → `0 failures`.

- [ ] **Step 4: Failing app-side tests**

  Append to `MatronTests/AppDependenciesTests.swift` (inside the class):
  ```swift
      /// App shell (spec §1): the Decisions instance has no home conversation
      /// and therefore starts in the cross-conversation scope.
      func test_makeDecisionsViewModel_hasNoHomeConversation_andStartsInAll() {
          let deps = AppDependencies()
          let session = UserSession(userID: "@a:s", deviceID: "D",
                                    homeserverURL: URL(string: "https://s")!, accessToken: "t")
          let vm = deps.makeDecisionsViewModel(for: session)
          XCTAssertNil(vm.convoID)
          XCTAssertEqual(vm.scope, .all)
          let perChat = deps.makeItemsPanelViewModel(for: session, convoID: "c1")
          XCTAssertEqual(perChat.scope, .convo("c1"))
      }
  ```
  Add the same test (same body) to `MatronMacTests/MacAppDependenciesTests.swift` inside its class (check that file's imports include `MatronModels` and `MatronViewModels`; add them if missing). Build either target: `xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO` → `value of type 'AppDependencies' has no member 'makeDecisionsViewModel'`.

- [ ] **Step 5: Implement both factories**

  Replace `makeItemsPanelViewModel` in `Matron/App/AppDependencies.swift` (lines 319–323) with:
  ```swift
      /// Per-chat / cross-chat items panel (spec: Apps → Panel content).
      /// `convoID: nil` is the app-wide instance — see `makeDecisionsViewModel`.
      @MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String?) -> ItemsPanelViewModel {
          let c = core(for: session)
          return ItemsPanelViewModel(convoID: convoID, store: c.store, api: c.api, sync: c.items)
      }

      /// The one Decisions instance per signed-in session (app shell, spec
      /// §1): no home conversation, starts in `.all`, feeds the Decisions
      /// list and the badge. Created and started by the shell, stopped when
      /// the shell leaves the hierarchy on sign-out.
      @MainActor func makeDecisionsViewModel(for session: UserSession) -> ItemsPanelViewModel {
          makeItemsPanelViewModel(for: session, convoID: nil)
      }
  ```
  Apply the identical replacement to `MatronMac/App/AppDependencies.swift` (lines 265–269). The existing call sites (`ChatView.swift:1104`, `MacChatView.swift:492`) pass a `String`, which converts to `String?` unchanged; `ItemsDrawer.swift:156` and `MacItemsPane.swift:127` pass `viewModel.convoID` (now `String?`) into the widened `ItemsListView` parameter.

- [ ] **Step 6: Run iOS and Mac suites**

  `xcodegen generate`, then the iOS test command and the Mac test command from Global Constraints. Expected: both end `Executed N tests, with 0 failures`.

- [ ] **Step 7: Commit**

  ```
  git add MatronShared/Sources/DesignSystem/Items/ItemsListView.swift MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests/testNoConversationHidesScopePicker.mac-ItemsList_noConvo-light.png MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests/testNoConversationHidesScopePicker.mac-ItemsList_noConvo-dark.png MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests/testNoConversationHidesScopePicker.mac-ItemsList_noConvo-axxxl.png Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift MatronTests/AppDependenciesTests.swift MatronMacTests/MacAppDependenciesTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "items: optional home conversation through ItemsListView; makeDecisionsViewModel on both apps" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 5: `DecisionsListView` (shared) with snapshots

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Items/DecisionsListView.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift` (create)

**Interfaces:**
- Consumes: `ItemRow(item:showsOrigin:thumbnail:)`, `TrackerItem`.
- Produces:
  ```swift
  public struct DecisionsListView: View {
      public struct Row: Equatable, Identifiable {
          public let item: TrackerItem
          public let originTitle: String?
          public var id: String { item.id }
          public init(item: TrackerItem, originTitle: String?)
      }
      public struct Model: Equatable {
          public var rows: [Row]
          public var isSupported: Bool?
          public var isRefreshing: Bool
          public init(rows: [Row], isSupported: Bool?, isRefreshing: Bool)
      }
      public init(model: Model, onSelect: @escaping (String) -> Void,
                  onOpenConversation: @escaping (String) -> Void, onRefresh: @escaping () async -> Void)
  }
  ```

- [ ] **Step 1: Write the failing snapshot tests**

  Create `MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift`:
  ```swift
  import SwiftUI
  import XCTest
  import MatronModels
  @testable import MatronDesignSystem

  /// App shell (spec §2): the cross-conversation "what needs you" list. Like
  /// `ItemsListSnapshotTests`, `List` rows don't populate under the
  /// `NSHostingView.fittingSize` harness, so the populated baseline pins the
  /// chrome (Mac header + refresh button) while the row rendering is already
  /// pinned by `ItemsListSnapshotTests.testRowVariants` (`ItemRow` with an
  /// origin subtitle). Empty and unsupported states render fully.
  @MainActor
  final class DecisionsListSnapshotTests: XCTestCase {
      private func t(_ id: String, num: Int, kind: ItemKind, title: String, origin: String) -> TrackerItem {
          TrackerItem(id: id, num: num, kind: kind, awaiting: .user, rank: Double(num), title: title, body: "",
                      originConvoID: origin, createdAt: .init(timeIntervalSince1970: 1_770_000_000),
                      updatedAt: .init(timeIntervalSince1970: 1_770_000_000 + Double(num)))
      }

      private func view(_ model: DecisionsListView.Model) -> some View {
          DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in }, onRefresh: {})
              .frame(width: 360, height: 400)
      }

      func testPopulated() {
          let model = DecisionsListView.Model(
              rows: [
                  .init(item: t("q1", num: 12, kind: .question, title: "Which auth library?", origin: "c1"), originTitle: "auth refactor"),
                  .init(item: t("d1", num: 11, kind: .decision, title: "Use SQLite for the cache", origin: "c2"), originTitle: nil),
              ],
              isSupported: true, isRefreshing: true)
          assertVariants(of: view(model), named: "DecisionsList_populated")
      }

      func testEmpty() {
          assertVariants(of: view(.init(rows: [], isSupported: true, isRefreshing: false)), named: "DecisionsList_empty")
      }

      func testUnsupported() {
          assertVariants(of: view(.init(rows: [], isSupported: false, isRefreshing: false)), named: "DecisionsList_unsupported")
      }

      func testRowsAreIdentifiedByItemID() {
          let row = DecisionsListView.Row(item: t("q1", num: 1, kind: .question, title: "x", origin: "c1"), originTitle: nil)
          XCTAssertEqual(row.id, "q1")
      }
  }
  ```
  Run `swift test --package-path MatronShared --filter DecisionsListSnapshotTests` → `cannot find 'DecisionsListView' in scope`.

- [ ] **Step 2: Implement**

  Create `MatronShared/Sources/DesignSystem/Items/DecisionsListView.swift`:
  ```swift
  import SwiftUI
  import MatronModels

  /// Every open item awaiting the user, across every conversation, newest
  /// first, with its origin conversation (app shell, spec §2). A pure leaf
  /// view: the host maps `ItemsPanelViewModel.awaitingYou` into `Model` so
  /// this is snapshot-testable without a view model. Rows reuse `ItemRow`
  /// with the origin subtitle always on — the same rendering `ItemsListView`
  /// uses in its "All" scope.
  public struct DecisionsListView: View {
      public struct Row: Equatable, Identifiable {
          public let item: TrackerItem
          public let originTitle: String?
          public var id: String { item.id }
          public init(item: TrackerItem, originTitle: String?) {
              self.item = item; self.originTitle = originTitle
          }
      }

      public struct Model: Equatable {
          public var rows: [Row]
          /// `false` shows the unsupported-journal message; `nil` (not yet
          /// known) and `true` both show the list.
          public var isSupported: Bool?
          public var isRefreshing: Bool
          public init(rows: [Row], isSupported: Bool?, isRefreshing: Bool) {
              self.rows = rows; self.isSupported = isSupported; self.isRefreshing = isRefreshing
          }
      }

      let model: Model
      let onSelect: (String) -> Void
      let onOpenConversation: (String) -> Void
      /// Pull to refresh (iOS) and the header button (Mac) both call this —
      /// the host wires it to `ItemsPanelViewModel.refresh()`.
      let onRefresh: () async -> Void

      public init(model: Model, onSelect: @escaping (String) -> Void,
                  onOpenConversation: @escaping (String) -> Void, onRefresh: @escaping () async -> Void) {
          self.model = model; self.onSelect = onSelect; self.onOpenConversation = onOpenConversation; self.onRefresh = onRefresh
      }

      public var body: some View {
          VStack(spacing: 0) {
              #if os(macOS)
              // The Mac list column has no pull-to-refresh, so the header
              // carries the refresh button; iOS uses `.refreshable` below.
              HStack {
                  Text("Decisions").font(.headline)
                  Spacer()
                  if model.isRefreshing {
                      ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                  }
                  Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                      .buttonStyle(.plain)
                      .help("Refresh")
                      .accessibilityLabel("Refresh")
              }
              .padding(.horizontal).padding(.vertical, 8)
              #endif
              if model.isSupported == false {
                  ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                         description: Text("Update the journal server to use items."))
              } else if model.rows.isEmpty {
                  ContentUnavailableView("Nothing needs you", systemImage: "checkmark.seal",
                                         description: Text("Questions and decisions waiting on you, from every conversation, appear here."))
              } else {
                  List {
                      ForEach(model.rows) { row in
                          Button { onSelect(row.item.id) } label: {
                              ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat")
                          }
                          .buttonStyle(.plain)
                          .foregroundStyle(Color.primary)
                          .contextMenu {
                              Button("Open conversation") { onOpenConversation(row.item.originConvoID) }
                          }
                      }
                  }
                  #if os(iOS)
                  .listStyle(.insetGrouped)
                  .refreshable { await onRefresh() }
                  #else
                  .listStyle(.inset)
                  #endif
              }
          }
      }
  }
  ```

- [ ] **Step 3: Record twice, then the full suite**

  `swift test --package-path MatronShared --filter DecisionsListSnapshotTests` (records 9 PNGs, fails) then again → `Executed 4 tests, with 0 failures`. Then `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` → `0 failures`.

- [ ] **Step 4: Commit and open PR 1**

  ```
  git add MatronShared/Sources/DesignSystem/Items/DecisionsListView.swift MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/DecisionsListSnapshotTests
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "items: DecisionsListView — every item awaiting you, across conversations" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  Push; open PR `Items VM all-conversations mode + DecisionsListView` (base: `remove-make-task-pill`).

---

## PR 2 — `ios-shell-tabs` (spec §3, Decisions on iOS)

### Task 6: `ItemRoute`, `AppTab`, `AppShellNavigation` (pure, tested)

**Files:**
- Create: `Matron/App/ItemRoute.swift`, `Matron/App/AppShellNavigation.swift`
- Test: `MatronTests/AppShellNavigationTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  struct ItemRoute: Hashable {
      let id: String
      static let pathPrefix: String            // "item/"
      var pathValue: String                    // pathPrefix + id — the value pushed on a [String] chat stack
      init(id: String)
      init?(pathValue: String)
  }
  enum AppTab: Hashable { case conversations, decisions }   // .coordinator joins in Task 16
  @MainActor @Observable final class AppShellNavigation {
      var tab: AppTab
      var chatPath: [String]
      var decisionsPath: [ItemRoute]
      func openChat(_ roomID: String)                        // deep links: switch to Conversations, REPLACE the path
      func openConversation(fromDecisions convoID: String)   // Decisions → Conversations, append
      func pushDecision(_ itemID: String)
  }
  ```

- [ ] **Step 1: Failing tests**

  Create `MatronTests/AppShellNavigationTests.swift`:
  ```swift
  import XCTest
  @testable import Matron

  /// App shell (spec §3): the shell's navigation state is a plain observable
  /// object so every cross-tab rule is a pure function of it.
  @MainActor
  final class AppShellNavigationTests: XCTestCase {
      func test_itemRoute_roundTripsThroughThePathValue() {
          let route = ItemRoute(id: "it_1")
          XCTAssertEqual(route.pathValue, "item/it_1")
          XCTAssertEqual(ItemRoute(pathValue: "item/it_1"), route)
          XCTAssertNil(ItemRoute(pathValue: "cv_1"), "a conversation id is not an item route")
          XCTAssertNil(ItemRoute(pathValue: "item/"), "an empty id is not a route")
      }

      func test_deepLink_switchesToConversations_andReplacesThePath() {
          let nav = AppShellNavigation()
          nav.tab = .decisions
          nav.chatPath = ["!old:s", "!child:s"]
          nav.openChat("!new:s")
          XCTAssertEqual(nav.tab, .conversations)
          XCTAssertEqual(nav.chatPath, ["!new:s"], "a deep link collapses the stack to the target (Dan, 2026-08-06)")
      }

      func test_deepLink_isIdempotent_forTheOpenChat() {
          let nav = AppShellNavigation()
          nav.chatPath = ["!r:s"]
          nav.openChat("!r:s")
          XCTAssertEqual(nav.chatPath, ["!r:s"])
      }

      func test_openConversationFromDecisions_switchesTab_thenAppends() {
          let nav = AppShellNavigation()
          nav.tab = .decisions
          nav.decisionsPath = [ItemRoute(id: "it_1")]
          nav.openConversation(fromDecisions: "!r:s")
          XCTAssertEqual(nav.tab, .conversations)
          XCTAssertEqual(nav.chatPath, ["!r:s"])
          XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_1")], "the Decisions stack is left where it was")
          nav.openConversation(fromDecisions: "!r:s")
          XCTAssertEqual(nav.chatPath, ["!r:s"], "no duplicate push for the chat already on top")
      }

      func test_pushDecision_appendsToTheDecisionsStack() {
          let nav = AppShellNavigation()
          nav.pushDecision("it_9")
          XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
          XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
      }
  }
  ```
  `xcodegen generate` then the iOS test command → compile error `cannot find 'AppShellNavigation' in scope`.

- [ ] **Step 2: Implement**

  `Matron/App/ItemRoute.swift`:
  ```swift
  import Foundation

  /// A tracker item pushed onto a navigation stack (app shell, spec §3/§4).
  /// The Decisions tab's stack is `[ItemRoute]`; the chat stacks stay
  /// `[String]` (the sub-chat switcher and `pushSpawnedRoom` rely on array
  /// semantics `NavigationPath` doesn't offer), so on those an item rides as
  /// `pathValue` and the `String` destination decodes it with
  /// `init?(pathValue:)`. Conversation ids never carry the prefix.
  struct ItemRoute: Hashable {
      let id: String
      static let pathPrefix = "item/"

      init(id: String) { self.id = id }

      init?(pathValue: String) {
          guard pathValue.hasPrefix(Self.pathPrefix) else { return nil }
          let id = String(pathValue.dropFirst(Self.pathPrefix.count))
          guard !id.isEmpty else { return nil }
          self.id = id
      }

      var pathValue: String { Self.pathPrefix + id }
  }
  ```
  `Matron/App/AppShellNavigation.swift`:
  ```swift
  import Foundation
  import Observation

  /// The bottom tabs (app shell, spec §3), in bar order.
  enum AppTab: Hashable {
      case conversations
      case decisions
  }

  /// Navigation state of the signed-in shell: the selected tab and each
  /// tab's stack path. An observable object rather than `@State` on the view
  /// so the cross-tab rules (deep links land in Conversations; Decisions
  /// hands off to Conversations) are plain, testable functions and so
  /// tests can inject a pre-set state into `AppShellView`.
  @MainActor @Observable
  final class AppShellNavigation {
      var tab: AppTab = .conversations
      /// Conversations tab stack. `[String]` because `ChatSummary.ID == String`
      /// and the sub-chat switcher replaces entries in place.
      var chatPath: [String] = []
      var decisionsPath: [ItemRoute] = []

      init() {}

      /// Open a top-level conversation by REPLACING the whole Conversations
      /// path, never appending: notification taps, search results and
      /// auto-opened new conversations used to stack chat-on-chat. Back from
      /// a conversation always returns to the chat list (Dan, 2026-08-06).
      /// No-op on the path when the target is already the sole open chat.
      func openChat(_ roomID: String) {
          tab = .conversations
          if chatPath != [roomID] { chatPath = [roomID] }
      }

      /// "Open conversation" from a Decisions row or its detail: switch to
      /// Conversations first, then push, in that order and in one
      /// transaction so the push lands in the visible stack (spec §3).
      func openConversation(fromDecisions convoID: String) {
          tab = .conversations
          if chatPath.last != convoID { chatPath.append(convoID) }
      }

      func pushDecision(_ itemID: String) {
          decisionsPath.append(ItemRoute(id: itemID))
      }
  }
  ```

- [ ] **Step 3: Run**

  iOS test command → `Executed N tests, with 0 failures` (N = previous + 5).

- [ ] **Step 4: Commit**

  ```
  git checkout -b ios-shell-tabs
  git add Matron/App/ItemRoute.swift Matron/App/AppShellNavigation.swift MatronTests/AppShellNavigationTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: ItemRoute and the shell's navigation state" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 7: `AppShellView` with Conversations + Decisions tabs; `MatronApp` shrinks

**Files:**
- Create: `Matron/App/AppShellView.swift`
- Modify: `Matron/App/MatronApp.swift` (state lines 22–28; signed-in branch lines 51–105; `openChat` lines 258–270; `signOut` lines 313–316)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (line 39 `vmCache`)
- Modify: `Matron/Features/Items/ItemDetailHost.swift` (line 20 `currentConvoID`)
- Test: `MatronTests/AppShellViewTests.swift` (create)

**Interfaces:**
- Consumes: `AppShellNavigation`, `DecisionsListView`, `ItemDetailHost`, `deps.makeDecisionsViewModel(for:)`, `JournalStore.conversationTitles()`, `NotificationDelegate.shared.tappedRoomID` / `consumePendingRoomID()`, `SyncService.newConversations()`.
- Produces:
  ```swift
  struct AppShellView: View {
      init(session: UserSession, deps: AppDependencies, onSignOut: @escaping () -> Void,
           navigation: AppShellNavigation = AppShellNavigation())
  }
  // ChatListView: `@State var vmCache = ChatVMCache()` (memberwise `vmCache:` now injectable)
  // ItemDetailHost: `let currentConvoID: String?`
  ```

- [ ] **Step 1: Failing render test**

  Create `MatronTests/AppShellViewTests.swift`:
  ```swift
  import XCTest
  import SwiftUI
  import UIKit
  import MatronModels
  @testable import Matron

  /// App shell (spec §3). Renders the REAL shell in a scene-attached
  /// `UIWindow` (the `SummariesSheetBindingTests` pattern): SwiftUI bridges
  /// `TabView` to a `UITabBarController`, so the tab bar is a genuine
  /// `UITabBar` we can find and inspect, unlike arbitrary body content.
  @MainActor
  final class AppShellViewTests: XCTestCase {
      private var window: UIWindow!

      override func tearDown() {
          window?.isHidden = true
          window?.rootViewController = nil
          window = nil
          super.tearDown()
      }

      private func makeShell(navigation: AppShellNavigation) -> AppShellView {
          let session = UserSession(userID: "@a:s", deviceID: "D",
                                    homeserverURL: URL(string: "https://s")!, accessToken: "t")
          return AppShellView(session: session, deps: AppDependencies(), onSignOut: {}, navigation: navigation)
      }

      func test_shell_showsTwoTabs_atTheRoot() throws {
          renderInWindow(makeShell(navigation: AppShellNavigation()))
          let bar = try XCTUnwrap(findTabBar(in: window), "TabView must bridge to a UITabBar")
          XCTAssertEqual(bar.items?.count, 2)
          XCTAssertFalse(bar.isHidden)
          XCTAssertLessThan(bar.frame.minY, window.bounds.maxY, "the bar is on screen at the root")
      }

      func test_shell_opensOnConversations() {
          let nav = AppShellNavigation()
          renderInWindow(makeShell(navigation: nav))
          XCTAssertEqual(nav.tab, .conversations)
      }

      // MARK: - helpers

      @discardableResult
      func renderInWindow<V: View>(_ view: V) -> UIView {
          let hosting = UIHostingController(rootView: view)
          if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
              window = UIWindow(windowScene: scene)
              window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
          } else {
              window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
          }
          window.rootViewController = hosting
          window.makeKeyAndVisible()
          window.layoutIfNeeded()
          hosting.view.layoutIfNeeded()
          for _ in 0..<5 {
              RunLoop.current.run(until: Date().addingTimeInterval(0.05))
              hosting.view.layoutIfNeeded()
          }
          return hosting.view
      }

      func findTabBar(in root: UIView) -> UITabBar? {
          if let bar = root as? UITabBar { return bar }
          for sub in root.subviews {
              if let found = findTabBar(in: sub) { return found }
          }
          return nil
      }
  }
  ```
  `xcodegen generate`; iOS test command → `cannot find 'AppShellView' in scope`.

- [ ] **Step 2: Implement `AppShellView`**

  Create `Matron/App/AppShellView.swift`:
  ```swift
  import SwiftUI
  import MatronJournal
  import MatronModels
  import MatronViewModels
  import MatronDesignSystem

  /// The signed-in shell (app shell, spec §3): a bottom tab bar over the
  /// Conversations stack (the pre-existing chat list + every deep-link path)
  /// and the Decisions stack. Owns the per-session Decisions view model —
  /// one `ItemsPanelViewModel(convoID: nil)` started here, stopped when the
  /// shell leaves the hierarchy on sign-out — so the tab badge is live
  /// app-wide. `MatronApp` is left with bootstrap / sign-in gating and the
  /// process-level services (push, background refresh, lock).
  struct AppShellView: View {
      let session: UserSession
      let deps: AppDependencies
      let onSignOut: () -> Void

      @State private var nav: AppShellNavigation
      @State private var chatListVM: ChatListViewModel
      /// Shared per-room chat/composer VM cache — one for the whole shell so
      /// a room opened from any tab rebinds to the same live view models.
      @State private var vmCache = ChatVMCache()
      @State private var decisionsVM: ItemsPanelViewModel
      /// Origin conversation titles for the Decisions rows (`conversationTitles()`
      /// is a cheap id→title scan, re-run when the set of origins changes).
      @State private var originTitles: [String: String] = [:]

      init(session: UserSession, deps: AppDependencies, onSignOut: @escaping () -> Void,
           navigation: AppShellNavigation = AppShellNavigation()) {
          self.session = session
          self.deps = deps
          self.onSignOut = onSignOut
          _nav = State(initialValue: navigation)
          _chatListVM = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
          _decisionsVM = State(initialValue: deps.makeDecisionsViewModel(for: session))
      }

      var body: some View {
          TabView(selection: $nav.tab) {
              conversationsTab
                  .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                  .tag(AppTab.conversations)
              decisionsTab
                  .tabItem { Label("Decisions", systemImage: "checkmark.circle") }
                  // `.badge(Int)` hides itself at zero.
                  .badge(decisionsVM.awaitingYouCount)
                  .tag(AppTab.decisions)
          }
          .environment(\.appDependencies, deps)
          .environment(\.currentSession, session)
          // Notification-tap deep link: NotificationDelegate publishes the
          // room id; the shell switches to Conversations and sets the path.
          // Idempotent on duplicate sends.
          .onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
              nav.openChat(roomID)
          }
          // Auto-open a conversation the bridge just created while we're
          // live (e.g. /start in another chat). The engine only emits ids
          // for convos born while running.
          .task(id: session.userID) {
              for await roomID in await deps.syncService(for: session).newConversations() {
                  nav.openChat(roomID)
              }
          }
          // Cold-start tap drain: a lock-screen tap that launched the app
          // ran `didReceive` before `.onReceive` above subscribed; the
          // delegate buffered it.
          .task(id: session.userID) {
              if let pending = NotificationDelegate.shared.consumePendingRoomID() {
                  nav.openChat(pending)
              }
          }
          .task { decisionsVM.start() }
          .onDisappear { decisionsVM.stop() }
      }

      private var conversationsTab: some View {
          NavigationStack(path: $nav.chatPath) {
              ChatListView(
                  viewModel: chatListVM,
                  vmCache: vmCache,
                  onSignOut: onSignOut,
                  // A search result / new chat navigates via the path the
                  // shell owns (same mechanism as a notification tap).
                  onOpenChat: { roomID in nav.openChat(roomID) }
              )
          }
          // Lets the running-subagent strip / sub-chat switcher push a child
          // chat or switch siblings on THIS tab's stack.
          .environment(\.chatNavigationPath, $nav.chatPath)
      }

      private var decisionsTab: some View {
          NavigationStack(path: $nav.decisionsPath) {
              DecisionsListView(
                  model: .init(
                      rows: decisionsVM.awaitingYou.map { .init(item: $0, originTitle: originTitles[$0.originConvoID]) },
                      isSupported: decisionsVM.isSupported,
                      isRefreshing: decisionsVM.isRefreshing),
                  onSelect: { nav.pushDecision($0) },
                  onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                  onRefresh: { await decisionsVM.refresh() }
              )
              .navigationTitle("Decisions")
              .navigationDestination(for: ItemRoute.self) { route in
                  ItemDetailHost(itemID: route.id, session: session, currentConvoID: nil,
                                 onOpenConversation: { nav.openConversation(fromDecisions: $0) })
              }
              .task(id: decisionsVM.awaitingYou.map(\.originConvoID)) {
                  originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
              }
              // Refresh failures surface through the VM's `error` — the same
              // alert the tracker uses (spec §7).
              .alert("Tracker", isPresented: Binding(get: { decisionsVM.error != nil }, set: { if !$0 { decisionsVM.error = nil } })) {
                  Button("OK") { decisionsVM.error = nil }
              } message: {
                  Text(decisionsVM.error ?? "")
              }
          }
      }
  }
  ```

- [ ] **Step 3: Widen the two call sites**

  1. `Matron/Features/ChatList/ChatListView.swift` line 39: change `@State private var vmCache = ChatVMCache()` to `@State var vmCache = ChatVMCache()` and extend its doc comment with one line: `/// Injected by \`AppShellView\` so every tab shares one cache; defaulted for previews/tests.`
  2. `Matron/Features/Items/ItemDetailHost.swift` line 20: `let currentConvoID: String?` and adjust its doc comment to `/// The chat this detail was opened from (\`ItemsPanelViewModel.convoID\`), or \`nil\` from the Decisions tab — used to hide the "opened from…" origin link when it would just point back at the chat underneath.` The comparison on line 81 compiles unchanged.

- [ ] **Step 4: Shrink `MatronApp`**

  In `Matron/App/MatronApp.swift`:
  1. Delete lines 22–28 (the `chatPath` doc + `@State private var chatPath: [String] = []`).
  2. Replace lines 52–105 (from `NavigationStack(path: $chatPath) {` through the cold-start drain `.task`'s closing `}`) with:
     ```swift
                     AppShellView(session: session, deps: dependencies, onSignOut: { signOut() })
                     // Settings (a sheet off the chat list) reads this to
                     // render the Privacy section — sheets inherit the
                     // presenting hierarchy's environment.
                     .environment(\.appLockController, appLock)
                     .task { try? await dependencies.syncService(for: session).start() }
     ```
     Everything from the push `.task(id: session.userID)` (line 112) onward stays attached, unchanged.
  3. Delete `openChat(_:)` (lines 258–270 with its doc comment).
  4. In `signOut()` delete lines 313–316 (the `chatPath = []` comment + assignment); keep `NotificationDelegate.shared.clearPendingRoomID()`.
  5. `import MatronDesignSystem` / `MatronJournal` / `MatronViewModels` stay (still used by the lock/push code and `MatronAppearance`).

- [ ] **Step 5: Run**

  `xcodegen generate`; iOS test command → `Executed N tests, with 0 failures` (N = previous + 2). Also build the Mac app to be sure nothing shared broke: the Mac test command → `0 failures`.

- [ ] **Step 6: Commit**

  ```
  git add Matron/App/AppShellView.swift Matron/App/MatronApp.swift Matron/Features/ChatList/ChatListView.swift Matron/Features/Items/ItemDetailHost.swift MatronTests/AppShellViewTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: AppShellView — Conversations and Decisions tabs with a live badge" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 8: Tab bar hidden inside a pushed chat and item detail (`ChatDestinationView`)

**Files:**
- Create: `Matron/Features/ChatList/ChatDestinationView.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift` (`chatDestination(for:)` lines 375–445)
- Modify: `Matron/Features/Items/ItemDetailHost.swift` (body, after line 164's `.sheet`)
- Test: `MatronTests/ChatListViewBindingTests.swift` (source-scan test lines 112–143), `MatronTests/AppShellViewTests.swift` (append)

**Interfaces:**
- Produces:
  ```swift
  struct ChatDestinationView: View {
      let id: ChatSummary.ID
      let summary: ChatSummary?
      let vmCache: ChatVMCache
      var hidesTabBar: Bool = true
  }
  ```

- [ ] **Step 1: Failing test**

  Append to `AppShellViewTests`:
  ```swift
      /// Spec §3: the tab bar shows only at the root of each tab — a pushed
      /// chat carries `.toolbar(.hidden, for: .tabBar)`.
      func test_pushedChat_hidesTheTabBar() throws {
          let nav = AppShellNavigation()
          nav.chatPath = ["!r:s"]
          renderInWindow(makeShell(navigation: nav))
          let bar = try XCTUnwrap(findTabBar(in: window))
          XCTAssertTrue(bar.isHidden || bar.frame.minY >= window.bounds.maxY - 1 || bar.alpha == 0,
                        "the tab bar must be hidden (or slid off screen) inside a pushed chat")
      }
  ```
  And update the source-scan test in `ChatListViewBindingTests` (lines 112–143): change the path component `"Matron/Features/ChatList/ChatListView.swift"` to `"Matron/Features/ChatList/ChatDestinationView.swift"`, the anchor `source.range(of: "func chatDestination(")` to `source.range(of: "var body: some View")`, and the two failure messages' `chatDestination(for:)` wording to `ChatDestinationView.body`. Run the iOS tests → `test_pushedChat_hidesTheTabBar` fails (bar visible) and the source-scan test fails (file not found).

- [ ] **Step 2: Implement**

  Create `Matron/Features/ChatList/ChatDestinationView.swift`:
  ```swift
  import SwiftUI
  import MatronChat
  import MatronModels

  /// The `String` push destination shared by every chat stack (app shell):
  /// a subagent child opens the read-only `SubChatView`, anything else the
  /// full `ChatView`. Extracted from `ChatListView.chatDestination(for:)` so
  /// the Coordinator tab can host the same destination on its own stack.
  ///
  /// Resolves view models from the shared `ChatVMCache` and keys each branch
  /// with `.id(id)`: `openChat` REPLACES the path ([A] → [B]), which keeps
  /// this destination's structural position — without the key SwiftUI
  /// reuses the old instance's `@State`, so `viewModel`/`composerVM` stay
  /// chat A's while the plain-`let` `chatTitle` updates to chat B (f3eb091).
  /// `ChatListViewBindingTests` pins the `.id(id)` by scanning this file.
  ///
  /// Hides the tab bar (spec §3: the bar shows only at the root of a tab);
  /// the Coordinator tab's root passes `hidesTabBar: false`.
  struct ChatDestinationView: View {
      let id: ChatSummary.ID
      let summary: ChatSummary?
      let vmCache: ChatVMCache
      var hidesTabBar: Bool = true

      @Environment(\.appDependencies) private var deps
      @Environment(\.currentSession) private var session

      var body: some View {
          Group {
              if let deps, let session {
                  if let parentConvoID = deps.parentConvoID(of: id, for: session) {
                      let (chatVM, stripVM) = vmCache.subChatViewModels(
                          for: id, parentConvoID: parentConvoID, deps: deps, session: session)
                      SubChatView(viewModel: chatVM, stripViewModel: stripVM,
                                  childID: id, fallbackTitle: "Subagent")
                          .id(id)
                  } else {
                      let (chatVM, composerVM) = vmCache.viewModels(for: id, deps: deps, session: session)
                      ChatView(
                          viewModel: chatVM,
                          composerVM: composerVM,
                          stripViewModel: vmCache.stripViewModel(forParent: id, deps: deps, session: session),
                          chatTitle: summary?.title ?? "",
                          boxName: summary?.boxName,
                          sessionShort: summary?.sessionShort,
                          boxShort: summary?.boxShort,
                          roomBoxNames: summary?.roomBoxNames ?? [],
                          roomBoxShorts: summary?.roomBoxShorts ?? []
                      )
                      .id(id)
                  }
              } else {
                  ContentUnavailableView(
                      "Session unavailable",
                      systemImage: "exclamationmark.triangle",
                      description: Text("Sign in again to open this chat.")
                  )
              }
          }
          .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
      }
  }
  ```
  In `ChatListView.swift` replace `chatDestination(for:)` (lines 375–445, doc comment included) with:
  ```swift
      /// Builds the destination for a tapped row. The lookup can legitimately
      /// return `nil` for a valid, open room — a conversation the bridge just
      /// created auto-opens before the chat-list snapshot lands — so the
      /// destination is built for any id whenever the session is present and
      /// the title fills in live. See `ChatDestinationView`.
      func chatDestination(for id: ChatSummary.ID) -> some View {
          ChatDestinationView(id: id, summary: currentSummary(for: id), vmCache: vmCache)
      }
  ```
  In `ItemDetailHost.swift`, after the `.sheet(item: $attachmentPreview) { … }` modifier (ends line 163) add:
  ```swift
          // App shell (spec §3): the tab bar shows only at a tab's root.
          .toolbar(.hidden, for: .tabBar)
  ```

- [ ] **Step 3: Run**

  `xcodegen generate`; iOS test command → `Executed N tests, with 0 failures`.

- [ ] **Step 4: Commit and open PR 2**

  ```
  git add Matron/Features/ChatList/ChatDestinationView.swift Matron/Features/ChatList/ChatListView.swift Matron/Features/Items/ItemDetailHost.swift MatronTests/ChatListViewBindingTests.swift MatronTests/AppShellViewTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: chat and item destinations hide the tab bar; ChatDestinationView shared by every stack" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  Push; open PR `iOS shell: tabs + Decisions` (base: `items-vm-all-mode`).

---

## PR 3 — `ios-tasks-pager` (spec §4; deletes `ItemsDrawer`)

### Task 9: `ChatPage`, `ChatPagerModel`, `ChatPager`, `ChatView.pushItem`

**Files:**
- Create: `Matron/Features/Chat/ChatPager.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (add `static func pushItem` next to `openItem`, lines 221–236)
- Test: `MatronTests/ChatPagerTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  enum ChatPage: Hashable { case chat, tasks }
  @MainActor @Observable final class ChatPagerModel {
      var page: ChatPage
      init(resignComposer: @escaping () -> Void = ChatPagerModel.resignFirstResponder)
      func go(to page: ChatPage)          // toolbar buttons
      func handleScrolled(to page: ChatPage)  // the ScrollView's position write-back
      static func resignFirstResponder()
  }
  struct ChatPager<Chat: View, Tasks: View>: View {
      init(model: ChatPagerModel, showsTasks: Bool, @ViewBuilder chat: @escaping () -> Chat, @ViewBuilder tasks: @escaping () -> Tasks)
  }
  extension ChatView { static func pushItem(_ itemID: String, onto path: Binding<[String]>?) }
  ```

- [ ] **Step 1: Failing tests**

  Create `MatronTests/ChatPagerTests.swift`:
  ```swift
  import XCTest
  import SwiftUI
  @testable import Matron

  /// App shell (spec §4): the chat screen pages between the timeline and the
  /// tracker. The model owns the page and the composer-focus rule; the view
  /// is a thin paging ScrollView over it.
  @MainActor
  final class ChatPagerTests: XCTestCase {
      func test_startsOnTheChatPage() {
          XCTAssertEqual(ChatPagerModel(resignComposer: {}).page, .chat)
      }

      func test_checklistButton_goesToTasks_andResignsTheComposer() {
          var resigned = 0
          let model = ChatPagerModel(resignComposer: { resigned += 1 })
          model.go(to: .tasks)
          XCTAssertEqual(model.page, .tasks)
          XCTAssertEqual(resigned, 1)
      }

      func test_returnButton_goesBackToChat_withoutRefocusing() {
          var resigned = 0
          let model = ChatPagerModel(resignComposer: { resigned += 1 })
          model.go(to: .tasks)
          model.go(to: .chat)
          XCTAssertEqual(model.page, .chat)
          XCTAssertEqual(resigned, 1, "paging back never touches the keyboard")
      }

      func test_swipeToTasks_resignsTheComposer_once() {
          var resigned = 0
          let model = ChatPagerModel(resignComposer: { resigned += 1 })
          model.handleScrolled(to: .tasks)
          model.handleScrolled(to: .tasks)
          XCTAssertEqual(model.page, .tasks)
          XCTAssertEqual(resigned, 1, "repeated write-backs for the same page are no-ops")
          model.handleScrolled(to: .chat)
          XCTAssertEqual(model.page, .chat)
          XCTAssertEqual(resigned, 1)
      }

      func test_onSelect_appendsAnItemRouteToTheOuterPath_notALocalStack() {
          var path: [String] = ["!r:s"]
          let binding = Binding(get: { path }, set: { path = $0 })
          ChatView.pushItem("it_1", onto: binding)
          XCTAssertEqual(path, ["!r:s", ItemRoute(id: "it_1").pathValue])
          ChatView.pushItem("it_1", onto: binding)
          XCTAssertEqual(path.count, 2, "a repeat tap on the same item is idempotent")
          ChatView.pushItem("it_2", onto: nil)
          XCTAssertEqual(path.count, 2, "no path (previews/tests) is a no-op")
      }
  }
  ```
  `xcodegen generate`; iOS test command → `cannot find 'ChatPagerModel' in scope`.

- [ ] **Step 2: Implement**

  Create `Matron/Features/Chat/ChatPager.swift`:
  ```swift
  import SwiftUI
  import UIKit
  import Observation

  /// The two pages of the chat screen (app shell, spec §4).
  enum ChatPage: Hashable {
      case chat
      case tasks
  }

  /// Owns which page is showing and the one side effect of paging: landing on
  /// the tasks page drops the composer's keyboard; paging back does not
  /// re-focus it. `resignComposer` is injectable so tests can observe it —
  /// the default sends `resignFirstResponder` down the responder chain, the
  /// composer being a plain `TextField` with no `@FocusState` seam of its own.
  @MainActor @Observable
  final class ChatPagerModel {
      var page: ChatPage = .chat
      private let resignComposer: () -> Void

      init(resignComposer: @escaping () -> Void = ChatPagerModel.resignFirstResponder) {
          self.resignComposer = resignComposer
      }

      /// Toolbar buttons. Callers wrap in `withAnimation` for the slide.
      func go(to page: ChatPage) {
          handleScrolled(to: page)
      }

      /// The pager's `.scrollPosition(id:)` write-back after a swipe.
      func handleScrolled(to page: ChatPage) {
          guard self.page != page else { return }
          self.page = page
          if page == .tasks { resignComposer() }
      }

      static func resignFirstResponder() {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      }
  }

  /// Horizontal paging container: page 0 is the chat (timeline + composer),
  /// page 1 the tracker. Native `.paging` gives the Instagram/X feel and the
  /// interactive drag-back for free; both pages stay mounted (a plain
  /// `HStack`, not lazy) so the timeline's scroll state survives paging.
  /// `showsTasks == false` (unsupported journal) mounts one page only, and
  /// `.scrollBounceBehavior(.basedOnSize)` makes the swipe a no-op rather
  /// than a rubber-band. The pager only owns horizontal drags: the vertical
  /// timeline and list scroll views underneath keep their own gestures, and
  /// UIKit's leading-edge back-swipe recognizer still wins over a scroll view.
  struct ChatPager<Chat: View, Tasks: View>: View {
      let model: ChatPagerModel
      let showsTasks: Bool
      @ViewBuilder let chat: () -> Chat
      @ViewBuilder let tasks: () -> Tasks

      @State private var scrolledPage: ChatPage?

      var body: some View {
          GeometryReader { geo in
              ScrollView(.horizontal) {
                  HStack(spacing: 0) {
                      chat()
                          .frame(width: geo.size.width, height: geo.size.height)
                          .id(ChatPage.chat)
                      if showsTasks {
                          tasks()
                              .frame(width: geo.size.width, height: geo.size.height)
                              .id(ChatPage.tasks)
                      }
                  }
                  .scrollTargetLayout()
              }
              .scrollTargetBehavior(.paging)
              .scrollIndicators(.hidden)
              .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
              .scrollPosition(id: $scrolledPage)
              .onAppear { scrolledPage = model.page }
              // Swipe → model (keyboard rule lives there).
              .onChange(of: scrolledPage) { _, page in
                  if let page { model.handleScrolled(to: page) }
              }
              // Button → scroll (the model changed first; mirror it).
              .onChange(of: model.page) { _, page in
                  if scrolledPage != page { scrolledPage = page }
              }
              // A journal that turns out unsupported while on the tasks page
              // loses that page — snap home rather than strand the position.
              .onChange(of: showsTasks) { _, shows in
                  if !shows { model.handleScrolled(to: .chat) }
              }
          }
      }
  }
  ```
  In `ChatView.swift`, directly after `openSpawnedRoom` (line 219) add:
  ```swift
      /// Pushes a tracker item onto the OUTER chat stack as an `ItemRoute`
      /// (spec §4) — never a local `NavigationStack`, which pops the outer
      /// one on iOS 26 (PR #188). Static so `ChatPagerTests` can pin it
      /// against a bare binding. Idempotent for the item already on top.
      static func pushItem(_ itemID: String, onto path: Binding<[String]>?) {
          guard let path else { return }
          let value = ItemRoute(id: itemID).pathValue
          guard path.wrappedValue.last != value else { return }
          path.wrappedValue.append(value)
      }
  ```

- [ ] **Step 3: Run**

  iOS test command → `Executed N tests, with 0 failures` (N = previous + 5).

- [ ] **Step 4: Commit**

  ```
  git checkout -b ios-tasks-pager
  git add Matron/Features/Chat/ChatPager.swift Matron/Features/Chat/ChatView.swift MatronTests/ChatPagerTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: ChatPager and its model — page state, keyboard rule, ItemRoute push" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 10: `ChatView` pages to the tracker; drawer deleted; `ItemRoute` on the chat stack

**Files:**
- Create: `Matron/Features/Items/NewItemSheet.swift` (moved out of `ItemsDrawer.swift`, lines 200–249, now internal)
- Delete: `Matron/Features/Items/ItemsDrawer.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (`openItem`/`openDrawer` lines 221–251; state lines 327–346; `body` lines 431–1258 — the VStack 432–926 becomes `chatPage`; gesture 927–963 removed; toolbar 973–1047; `fullScreenCover` 1222–1257 removed)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (`.navigationDestination` lines 217–219)
- Test: `MatronTests/ChatViewBindingTests.swift` (existing; stays green)

**Interfaces:**
- Consumes: `ChatPager`, `ChatPagerModel`, `ItemsListView`, `NewItemSheet`, `ItemDetailHost`, `ItemRoute`.
- Produces: `ChatListView.itemDestination(_ route: ItemRoute) -> some View` (private), `ChatView.tasksPage` (private).

- [ ] **Step 1: Move `NewItemSheet` and delete the drawer**

  Create `Matron/Features/Items/NewItemSheet.swift` with the exact contents of `ItemsDrawer.swift` lines 200–249 (the `NewItemSheet` struct), preceded by `import SwiftUI`, `import MatronModels`, `import MatronDesignSystem`, with `private struct NewItemSheet` changed to `struct NewItemSheet` and the doc comment `/// Create-item sheet: kind picker, title, free-text body. Mirrors the Mac pane's create sheet with iOS \`Form\` chrome. Presented from the chat's tasks page.` Then `git rm Matron/Features/Items/ItemsDrawer.swift`, `xcodegen generate`, and build (`xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO`) → expected failure `cannot find 'ItemsDrawer' in scope` in `ChatView.swift`.

- [ ] **Step 2: Rewire `ChatView`**

  1. Replace `openItem`/`openDrawer` (lines 221–251, both doc comments included) with:
     ```swift
         /// Tapping an inline `.itemMarker` card pushes that item onto the
         /// outer stack straight away — no need to page to the tracker first.
         private func openItem(_ itemID: String) {
             Self.pushItem(itemID, onto: navigationPath)
         }
     ```
     (keep the `pushItem` added in Task 9).
  2. Replace the state block lines 327–346 (`/// Task 11 (items tracker): right-edge drawer …` through `@State private var chatContainerWidth: CGFloat = 0`) with:
     ```swift
         /// Tasks page (spec §4). The items VM is created and started in `.task`
         /// regardless of which page shows — the toolbar's `NeedsYouBadge` needs
         /// a live `needsYouCount` on the chat page — and stopped in the same
         /// `onDisappear` that stops `viewModel`/`stripViewModel`.
         @State private var itemsVM: ItemsPanelViewModel?
         @State private var pager = ChatPagerModel()
         @State private var showCreateItem = false
         /// id→title for the tracker's "All" rows; one cheap store scan per
         /// scope switch (`conversationTitles()`).
         @State private var originTitles: [String: String] = [:]
     ```
  3. Rename the existing `var body: some View {` (line 431) to `private var chatPage: some View {` and end it right after the VStack's closing brace (line 926) — i.e. everything from line 927 (`// Task 11: measures this container's width…`) through line 963 (the `.simultaneousGesture(...)` closing `)`) is deleted, and the modifiers from line 964 (`// matron-web's cream timeline gradient…`) onward move into the new `body` below.
  4. Insert the new `body` directly above `chatPage`:
     ```swift
         /// Whether the tracker page exists: the VM must exist and the journal
         /// must not have said "unsupported" (a 404 on GET /items). With one
         /// page the swipe does nothing (spec §7).
         private var showsTasksPage: Bool {
             guard let itemsVM else { return false }
             return itemsVM.isSupported != false
         }

         var body: some View {
             ChatPager(model: pager, showsTasks: showsTasksPage) {
                 chatPage
             } tasks: {
                 tasksPage
             }
             // VoiceOver hears the page change; the announcement names the
             // page that just arrived.
             .onChange(of: pager.page) { _, page in
                 UIAccessibility.post(notification: .screenChanged,
                                      argument: page == .tasks ? "Tasks and decisions" : chatTitle)
             }
     ```
     followed by the moved modifiers (`.background(MatronTimelineBackground())`, `.navigationTitle(chatTitle)`, … through `.onChange(of: viewModel.rows.isEmpty) { … }` at line 1221) and then the closing `}` of `body`. Delete the `.fullScreenCover(isPresented: $showItems) { … }` block and its comment (lines 1222–1257).
  5. Add `tasksPage` after `chatPage`:
     ```swift
         /// Page 1: this conversation's tracker (the existing `itemsVM`, scope
         /// defaulting to this chat, picker available). No `NavigationStack` of
         /// its own — item detail is pushed onto the OUTER stack as an
         /// `ItemRoute` (spec §4; PR #188).
         @ViewBuilder
         private var tasksPage: some View {
             if let itemsVM {
                 ItemsListView(
                     model: .init(
                         needsYou: itemsVM.sections.needsYou,
                         tasks: itemsVM.sections.tasks,
                         decisions: itemsVM.sections.decisions,
                         done: itemsVM.sections.done,
                         originTitles: originTitles,
                         isSupported: itemsVM.isSupported,
                         isRefreshing: itemsVM.isRefreshing,
                         pending: itemsVM.pendingCreates.map {
                             ItemsListView.PendingRow(id: $0.id, kind: $0.kind, title: $0.title,
                                                      isFailed: $0.lastError != nil, error: $0.lastError)
                         }
                     ),
                     scope: Binding(get: { itemsVM.scope }, set: { itemsVM.scope = $0 }),
                     convoID: itemsVM.convoID,
                     thumbnail: { _ in nil },
                     onSelect: { Self.pushItem($0.id, onto: navigationPath) },
                     onMove: { id, index in Task { await itemsVM.move(itemID: id, toIndex: index) } },
                     onCreate: { showCreateItem = true },
                     onOpenConversation: { id in
                         // An origin link back to THIS room would push a second
                         // entry onto the chat already showing — skip it.
                         guard id != viewModel.roomID else { return }
                         navigationPath?.wrappedValue.append(id)
                     }
                 )
                 .task(id: itemsVM.scope) {
                     guard let deps, let session else { return }
                     originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
                 }
                 .sheet(isPresented: $showCreateItem) {
                     NewItemSheet { kind, title, itemBody in
                         Task { await itemsVM.create(kind: kind, title: title, body: itemBody) }
                     }
                 }
                 .alert("Tracker", isPresented: Binding(get: { itemsVM.error != nil }, set: { if !$0 { itemsVM.error = nil } })) {
                     Button("OK") { itemsVM.error = nil }
                 } message: {
                     Text(itemsVM.error ?? "")
                 }
             } else {
                 Color.clear
             }
         }
     ```
  6. Toolbar (lines 973–1047 today): the principal item's `Button { showSummaries = true } label: { … }` becomes page-aware — wrap it:
     ```swift
             ToolbarItem(placement: .principal) {
                 if pager.page == .tasks {
                     Text("Tasks & decisions").font(.headline)
                 } else {
                     Button { showSummaries = true } label: {
                         // …existing VStack label unchanged…
                     }
                     .buttonStyle(.plain)
                     // …existing accessibility modifiers unchanged…
                 }
             }
     ```
     and replace the checklist `ToolbarItem` (lines 1017–1031) with:
     ```swift
             // Tasks page (spec §4). Hidden once the panel VM has confirmed the
             // journal doesn't support the tracker; on the tasks page the same
             // slot returns to the chat.
             if showsTasksPage, let itemsVM {
                 ToolbarItem(placement: .topBarTrailing) {
                     if pager.page == .tasks {
                         Button { withAnimation { pager.go(to: .chat) } } label: {
                             Image(systemName: "bubble.left")
                         }
                         .accessibilityLabel("Back to the chat")
                     } else {
                         Button { withAnimation { pager.go(to: .tasks) } } label: {
                             Image(systemName: "checklist")
                                 .overlay(alignment: .topTrailing) {
                                     NeedsYouBadge(count: itemsVM.needsYouCount)
                                         .scaleEffect(0.75)
                                         .offset(x: 10, y: -8)
                                 }
                         }
                         .accessibilityLabel("Tasks and decisions")
                     }
                 }
             }
     ```
  7. The `.task` (line 1103–1107) and `onDisappear` (`itemsVM?.stop()`, line 1173) stay as they are. `grep -n "showItems\|itemsPath\|chatContainerWidth\|openDrawer\|ItemsDrawer" Matron/Features/Chat/ChatView.swift` must print nothing.

- [ ] **Step 3: `ItemRoute` destination on the chat stack**

  In `ChatListView.swift` add `@Environment(\.chatNavigationPath) private var chatNavigationPath` next to the other environment reads (after line 41) and replace lines 217–219 with:
  ```swift
          .navigationDestination(for: ChatSummary.ID.self) { id in
              if let route = ItemRoute(pathValue: id) {
                  itemDestination(route)
              } else {
                  chatDestination(for: id)
              }
          }
  ```
  and add after `currentSummary(for:)`:
  ```swift
      /// Item detail pushed from a chat's tasks page (spec §4) — it rides the
      /// same `[String]` stack as `ItemRoute.pathValue`. The chat underneath
      /// is the nearest non-item entry below it, so the "opened from…" link
      /// hides when it would only point back at that chat; an origin link
      /// elsewhere appends the conversation as before.
      @ViewBuilder
      private func itemDestination(_ route: ItemRoute) -> some View {
          if let session {
              let current = chatNavigationPath?.wrappedValue.last(where: { ItemRoute(pathValue: $0) == nil })
              ItemDetailHost(itemID: route.id, session: session, currentConvoID: current,
                             onOpenConversation: { convoID in
                                 guard convoID != current else { return }
                                 chatNavigationPath?.wrappedValue.append(convoID)
                             })
          } else {
              ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle",
                                     description: Text("Sign in again to open this item."))
          }
      }
  ```

- [ ] **Step 4: Run**

  `xcodegen generate`; iOS test command → `Executed N tests, with 0 failures`. Then run the app on a simulator (`xcodebuild build …` succeeded is not enough here): open a chat, tap the checklist button, confirm the slide, tap `bubble.left`, swipe both ways, tap a row and confirm the detail pushes on the outer stack and back returns to the tasks page. Device-only checks (leading-edge back swipe on page 0, keyboard dropping on page change, VoiceOver) go on `manual-tests.md` for Dan.

- [ ] **Step 5: Commit and open PR 3**

  ```
  git add Matron/Features/Items/NewItemSheet.swift Matron/Features/Chat/ChatView.swift Matron/Features/ChatList/ChatListView.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: the chat pages horizontally to its tracker; the right-edge drawer is gone" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  (`git rm` already staged the deletion.) Push; open PR `iOS tasks pager` (base: `ios-shell-tabs`).

---

## PR 4 — `mac-nav-column` (spec §5, Coordinator and Decisions entries)

### Task 11: `MacNav` + `MacNavColumn` with snapshots

**Files:**
- Create: `MatronMac/Features/Nav/MacNavColumn.swift`
- Test: `MatronMacTests/MacNavColumnSnapshotTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  enum MacNav: Hashable, CaseIterable { case coordinator, conversations, decisions
      var title: String; var symbol: String }
  struct MacNavColumn: View {
      static let width: CGFloat = 72
      init(selection: Binding<MacNav>, decisionsCount: Int)
  }
  ```

- [ ] **Step 1: Failing snapshot tests**

  Create `MatronMacTests/MacNavColumnSnapshotTests.swift`:
  ```swift
  #if os(macOS)
  import SwiftUI
  import XCTest
  @testable import MatronMac

  /// App shell (spec §5): the big-icon navigation column to the left of the
  /// conversations list. Pure view, so the baselines need no VM.
  final class MacNavColumnSnapshotTests: XCTestCase {
      @MainActor
      func testBadge() {
          let view = MacNavColumn(selection: .constant(.decisions), decisionsCount: 4)
              .frame(height: 320)
          assertVariants(of: view, named: "MacNavColumn_badge")
      }

      @MainActor
      func testNoBadge() {
          let view = MacNavColumn(selection: .constant(.conversations), decisionsCount: 0)
              .frame(height: 320)
          assertVariants(of: view, named: "MacNavColumn_noBadge")
      }

      func testEntriesInBarOrder() {
          XCTAssertEqual(MacNav.allCases, [.coordinator, .conversations, .decisions])
          XCTAssertEqual(MacNav.decisions.symbol, "checkmark.circle")
          XCTAssertEqual(MacNavColumn.width, 72)
      }
  }
  #endif
  ```
  `xcodegen generate`; Mac test command → `cannot find 'MacNavColumn' in scope`.

- [ ] **Step 2: Implement**

  Create `MatronMac/Features/Nav/MacNavColumn.swift`:
  ```swift
  import SwiftUI

  /// Top-level Mac navigation entries (app shell, spec §5), top to bottom.
  enum MacNav: Hashable, CaseIterable {
      case coordinator
      case conversations
      case decisions

      var title: String {
          switch self {
          case .coordinator: return "Coordinator"
          case .conversations: return "Conversations"
          case .decisions: return "Decisions"
          }
      }

      var symbol: String {
          switch self {
          case .coordinator: return "person.crop.circle.badge.checkmark"
          case .conversations: return "bubble.left.and.bubble.right"
          case .decisions: return "checkmark.circle"
          }
      }
  }

  /// Fixed-width vertical column of large icons with labels beneath — the
  /// Slack-workspace-switcher shape Dan asked for. Lives INSIDE the sidebar
  /// column of `MacChatListView`'s split view (so the sidebar's material and
  /// `navigationSplitViewColumnWidth` still apply) and is never collapsible.
  /// The Decisions entry carries a red count badge at its top-trailing
  /// corner, hidden at zero.
  struct MacNavColumn: View {
      @Binding var selection: MacNav
      let decisionsCount: Int

      static let width: CGFloat = 72

      var body: some View {
          VStack(spacing: 4) {
              ForEach(MacNav.allCases, id: \.self) { entry in
                  Button { selection = entry } label: {
                      VStack(spacing: 4) {
                          Image(systemName: entry.symbol)
                              .font(.system(size: 22))
                              .frame(height: 28)
                              .overlay(alignment: .topTrailing) {
                                  if entry == .decisions, decisionsCount > 0 {
                                      countBadge
                                  }
                              }
                          Text(entry.title)
                              .font(.caption2)
                              .lineLimit(1)
                      }
                      .frame(width: Self.width - 12, height: 56)
                      .background(
                          selection == entry ? Color.accentColor.opacity(0.18) : Color.clear,
                          in: RoundedRectangle(cornerRadius: 8))
                      .foregroundStyle(selection == entry ? Color.accentColor : Color.secondary)
                      .contentShape(RoundedRectangle(cornerRadius: 8))
                  }
                  .buttonStyle(.plain)
                  .help(entry.title)
                  .accessibilityLabel(entry.title + (entry == .decisions && decisionsCount > 0 ? ", \(decisionsCount) need you" : ""))
                  .accessibilityAddTraits(selection == entry ? .isSelected : [])
                  .accessibilityIdentifier("nav.\(entry.title.lowercased())")
              }
              Spacer(minLength: 0)
          }
          .padding(.top, 8)
          .frame(width: Self.width)
          .frame(maxHeight: .infinity)
      }

      private var countBadge: some View {
          Text(decisionsCount > 99 ? "99+" : "\(decisionsCount)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .frame(minWidth: 16)
              .background(Color.red, in: Capsule())
              .offset(x: 8, y: -6)
      }
  }
  ```

- [ ] **Step 3: Record the Mac snapshots twice, then the suite**

  `MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacNavColumnSnapshotTests` (no skip var; first run records `MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/*.png` and fails), run again → `Executed 3 tests, with 0 failures`. Then the full Mac test command (with the skip var) → `0 failures`.

- [ ] **Step 4: Commit**

  ```
  git checkout -b mac-nav-column
  git add MatronMac/Features/Nav/MacNavColumn.swift MatronMacTests/MacNavColumnSnapshotTests.swift MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "mac: MacNavColumn — big-icon navigation with a Decisions count badge" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 12: ⌘1 / ⌘2 / ⌘3 commands

**Files:**
- Modify: `MatronMac/App/Commands.swift` (enum lines 12–22; View menu group lines 79–92; listener table lines 38–43)
- Test: `MatronMacTests/MacCommandsTests.swift` (lines 26–35; append)

**Interfaces:**
- Produces: `MatronCommand.showCoordinator`, `.showConversations`, `.showDecisions`.

- [ ] **Step 1: Failing tests**

  In `MacCommandsTests.test_allCases_includes_phase2_set` add `.showCoordinator, .showConversations, .showDecisions,` to the `triggers` array, and append:
  ```swift
      /// App shell (spec §5): ⌘1/⌘2/⌘3 select the nav column's entries.
      func test_post_showDecisions_notifiesObserver() {
          let exp = expectation(description: "showDecisions observed")
          let observer = NotificationCenter.default.addObserver(
              forName: .matronCommand(.showDecisions), object: nil, queue: nil
          ) { _ in exp.fulfill() }
          NotificationCenter.default.post(name: .matronCommand(.showDecisions), object: nil)
          wait(for: [exp], timeout: 1)
          NotificationCenter.default.removeObserver(observer)
      }
  ```
  Mac test command → `type 'MatronCommand' has no member 'showCoordinator'`.

- [ ] **Step 2: Implement**

  In `Commands.swift` add to the enum after `case refresh`:
  ```swift
      /// App shell (spec §5): nav-column selection — ⌘1 / ⌘2 / ⌘3.
      case showCoordinator
      case showConversations
      case showDecisions
  ```
  Add to the listener table doc comment (after the `.refresh` line): `///   - \`.showCoordinator/.showConversations/.showDecisions\` — \`MacChatListView\` (sets \`nav\`)`. In the View menu `CommandGroup(after: .sidebar)` insert before `Divider()`:
  ```swift
              Button("Coordinator") { post(.showCoordinator) }
                  .keyboardShortcut("1", modifiers: .command)
              Button("Conversations") { post(.showConversations) }
                  .keyboardShortcut("2", modifiers: .command)
              Button("Decisions") { post(.showDecisions) }
                  .keyboardShortcut("3", modifiers: .command)
              Divider()
  ```

- [ ] **Step 3: Run** the Mac test command → `Executed N tests, with 0 failures` (N = previous + 1).

- [ ] **Step 4: Commit**

  ```
  git add MatronMac/App/Commands.swift MatronMacTests/MacCommandsTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "mac: ⌘1/⌘2/⌘3 select Coordinator, Conversations, Decisions" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 13: `MacChatListView` hosts the nav column, Decisions, and the Coordinator placeholder

**Files:**
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (state after line 61; `handleSelectionChange` lines 107–119; `body` lines 125–159 sidebar + 159–197 detail; listeners after line 264; `.task { viewModel.start() }` line 320; `onDisappear` line 336)
- Modify: `MatronMac/Features/Items/MacItemsPane.swift` (line 221 `currentConvoID`)
- Test: `MatronMacTests/MacSidebarWidthTests.swift` (lines 45–50; append), `MatronMacTests/MacChatListViewTests.swift` (existing)

**Interfaces:**
- Consumes: `MacNavColumn`, `DecisionsListView`, `MacItemDetailHost`, `MacItemsPaneState`, `deps.makeDecisionsViewModel(for:)`, `MatronCommand.show*`.
- Produces: `MacItemDetailHost.currentConvoID: String?`; `MacChatListView` internal `@State var nav: MacNav` (internal, not private, so tests can read it after construction).

- [ ] **Step 1: Failing width test**

  In `MacSidebarWidthTests.test_sidebarColumn_honoursIdealWidthOnFirstLayout` change the three expectations to `400 + MacNavColumn.width` (472), `260 + MacNavColumn.width` (332) and `600 + MacNavColumn.width` (672), with the message `"sidebar should open at the 400pt list ideal plus the 72pt nav column"`. Append:
  ```swift
      /// App shell (spec §5): the nav column is part of the sidebar column,
      /// so the list still meets its 260pt minimum once the column's 72pt
      /// are added — and the view opens on Conversations.
      func test_sidebar_opensOnConversations_withTheNavColumnInside() {
          let vm = ChatListViewModel(chat: WidthFakeChatActions(snapshots: [[]]))
          let view = MacChatListView(viewModel: vm)
          XCTAssertEqual(view.nav, .conversations)
          XCTAssertEqual(MacNavColumn.width, 72)
      }
  ```
  Mac test command → the width assertions fail (400 ≠ 472) and `value of type 'MacChatListView' has no member 'nav'`.

- [ ] **Step 2: Implement in `MacChatListView`**

  1. After `itemsPaneOpen` (line 61) add:
     ```swift
         /// App shell (spec §5): which top-level surface the sidebar's nav
         /// column has selected. Internal (not private) so tests can read the
         /// default. Also driven by ⌘1/⌘2/⌘3 via the command bus.
         @State var nav: MacNav = .conversations
         /// The per-session Decisions view model (`ItemsPanelViewModel(convoID:
         /// nil)`): created and started once the session resolves, kept
         /// running whichever entry is selected so the badge is live, stopped
         /// in `onDisappear` (sign-out tears this view down).
         @State private var decisionsVM: ItemsPanelViewModel?
         @State private var decisionsPaneState = MacItemsPaneState()
         @State private var selectedDecisionID: String?
         @State private var decisionsOriginTitles: [String: String] = [:]
     ```
  2. In `handleSelectionChange` add, before the search-clearing `if`:
     ```swift
         // Every path that selects a conversation — sidebar click, deep link,
         // auto-open, search hit, "Open conversation" from Decisions — means
         // "show me that chat": bring the Conversations entry forward first.
         if new != nil { nav = .conversations }
     ```
  3. Replace the sidebar closure's content (lines 127–158) with:
     ```swift
             HStack(spacing: 0) {
                 MacNavColumn(selection: $nav, decisionsCount: decisionsVM?.awaitingYouCount ?? 0)
                 Divider()
                 switch nav {
                 case .conversations:
                     sidebarColumn
                 case .decisions:
                     decisionsColumn
                 case .coordinator:
                     // Coordinator selected: the list column collapses to the
                     // nav column alone (the width modifier below shrinks it).
                     Spacer(minLength: 0)
                 }
             }
             // Drop the system sidebar-collapse toolbar button. The
             // ⌘⇧S menu item / `.toggleSidebar` notification handler
             // still collapses the sidebar; only the redundant toolbar
             // chevron is removed.
             .toolbar(removing: .sidebarToggle)
             // MUST come after `.toolbar(removing: .sidebarToggle)`:
             // on macOS 26 that modifier masks an inner column-width
             // preference and the sidebar falls back to the system
             // default (probe-bisected 2026-07-20). The list keeps its
             // 260/400/600 and the nav column adds its fixed 72 (spec §5);
             // with Coordinator selected only the nav column remains.
             .navigationSplitViewColumnWidth(
                 min: nav == .coordinator ? MacNavColumn.width : 260 + MacNavColumn.width,
                 ideal: nav == .coordinator ? MacNavColumn.width : 400 + MacNavColumn.width,
                 max: nav == .coordinator ? MacNavColumn.width : 600 + MacNavColumn.width)
             .toolbar {
                 // …the existing ToolbarSpacer / New chat button block, unchanged…
             }
     ```
  4. Replace the detail closure (lines 159–197) with:
     ```swift
         } detail: {
             switch nav {
             case .conversations:
                 if let searchModel, !searchModel.query.isEmpty {
                     // …existing MacSearchResultsView block, unchanged…
                 } else {
                     detail
                 }
             case .decisions:
                 decisionsDetail
             case .coordinator:
                 // Content lands with the coordinator setting (PR 5).
                 ContentUnavailableView(
                     "Coordinator",
                     systemImage: MacNav.coordinator.symbol,
                     description: Text("Your coordinator conversation will live here."))
             }
         }
     ```
  5. After the `.onReceive(... .matronOpenRoom)` listener add:
     ```swift
         // ⌘1/⌘2/⌘3 (Commands.swift) — same bus shape as `.toggleSidebar`.
         .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showCoordinator))) { _ in nav = .coordinator }
         .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showConversations))) { _ in nav = .conversations }
         .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showDecisions))) { _ in nav = .decisions }
         // The Decisions VM lives for the session (spec §5b): one instance,
         // started here, feeding both the list and the nav badge.
         .task(id: session?.userID) {
             guard let deps, let session else { return }
             decisionsVM?.stop()
             let vm = deps.makeDecisionsViewModel(for: session)
             decisionsVM = vm
             vm.start()
         }
         .task(id: decisionsVM?.awaitingYou.map(\.originConvoID) ?? []) {
             guard let deps, let session else { return }
             decisionsOriginTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
         }
     ```
  6. Change `.onDisappear { viewModel.cancel() }` (line 336) to:
     ```swift
         .onDisappear {
             viewModel.cancel()
             decisionsVM?.stop()
             decisionsPaneState.detailViewModel?.stop()
             decisionsPaneState.detailRecorder.cancel()
         }
     ```
  7. Add the two new column builders after `sidebar`:
     ```swift
         /// Decisions selected (spec §5): the list column is the shared
         /// `DecisionsListView`; a row selects the detail on the right.
         @ViewBuilder
         private var decisionsColumn: some View {
             if let decisionsVM {
                 DecisionsListView(
                     model: .init(
                         rows: decisionsVM.awaitingYou.map { .init(item: $0, originTitle: decisionsOriginTitles[$0.originConvoID]) },
                         isSupported: decisionsVM.isSupported,
                         isRefreshing: decisionsVM.isRefreshing),
                     onSelect: { selectedDecisionID = $0 },
                     onOpenConversation: openConversationFromDecisions,
                     onRefresh: { await decisionsVM.refresh() }
                 )
                 .alert("Tracker", isPresented: Binding(get: { decisionsVM.error != nil }, set: { if !$0 { decisionsVM.error = nil } })) {
                     Button("OK") { decisionsVM.error = nil }
                 } message: {
                     Text(decisionsVM.error ?? "")
                 }
             } else {
                 ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
             }
         }

         @ViewBuilder
         private var decisionsDetail: some View {
             if let id = selectedDecisionID, let session {
                 MacItemDetailHost(itemID: id, session: session, currentConvoID: nil,
                                   state: decisionsPaneState, onOpenConversation: openConversationFromDecisions)
             } else {
                 ContentUnavailableView(
                     "Select an item",
                     systemImage: "checkmark.circle",
                     description: Text("Pick something that needs you from the list."))
             }
         }

         /// "Open conversation" from a Decisions row or its detail: switch the
         /// nav entry, then select that chat (spec §5).
         private func openConversationFromDecisions(_ convoID: String) {
             nav = .conversations
             listLogger.notice("selection set by decisions: \(convoID, privacy: .public)")
             selectedSummaryID = convoID
         }
     ```
  8. `MacItemsPane.swift` line 221: `let currentConvoID: String?` (doc: add `, or \`nil\` from the Decisions column`). The comparison on line 260 compiles unchanged.

- [ ] **Step 3: Run** `xcodegen generate` (no new files, but harmless) and the Mac test command → `Executed N tests, with 0 failures` (N = previous + 1). Launch the Mac app once: confirm the column, that ⌘3 shows Decisions, that a row shows detail, and that "Open conversation" flips back to Conversations with that chat selected.

- [ ] **Step 4: Commit and open PR 4**

  ```
  git add MatronMac/Features/ChatList/MacChatListView.swift MatronMac/Features/Items/MacItemsPane.swift MatronMacTests/MacSidebarWidthTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "mac: nav column in the sidebar — Decisions list and detail, Coordinator entry" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  Push; open PR `Mac big-icon nav column` (base: `ios-tasks-pager`).

---

## PR 5 — `coordinator-tab` (spec §5b + §3 Coordinator tab + Mac Coordinator content)

### Task 14: `CoordinatorSetting` (MatronModels)

**Files:**
- Create: `MatronShared/Sources/Models/CoordinatorSetting.swift`
- Test: `MatronShared/Tests/ViewModelTests/CoordinatorSettingTests.swift` (create; `ViewModelTests` already depends on `MatronModels`)

**Interfaces:**
- Produces:
  ```swift
  public struct CoordinatorSetting {
      public static func defaultsKey(for userID: String) -> String   // "coordinator.convoID.<userID>"
      public init(userID: String, defaults: UserDefaults = .standard)
      public var convoID: String? { get nonmutating set }             // nil clears
      public static func clear(for userID: String, defaults: UserDefaults = .standard)
  }
  ```

- [ ] **Step 1: Failing tests**

  Create `MatronShared/Tests/ViewModelTests/CoordinatorSettingTests.swift`:
  ```swift
  import XCTest
  import MatronModels

  /// App shell (spec §5b): the coordinator conversation id, one per
  /// signed-in journal user. Each test uses its own throwaway suite (the
  /// `BoxCapacityCacheTests` idiom) so `.standard` is never touched.
  final class CoordinatorSettingTests: XCTestCase {
      private var suiteName: String!
      private var defaults: UserDefaults!

      override func setUp() {
          super.setUp()
          suiteName = "test.coordinatorSetting.\(UUID().uuidString)"
          defaults = UserDefaults(suiteName: suiteName)
      }

      override func tearDown() {
          defaults.removePersistentDomain(forName: suiteName)
          super.tearDown()
      }

      func testKeyIsPerUser() {
          XCTAssertEqual(CoordinatorSetting.defaultsKey(for: "@a:s"), "coordinator.convoID.@a:s")
      }

      func testRoundTripsPerUser() {
          let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
          let b = CoordinatorSetting(userID: "@b:s", defaults: defaults)
          XCTAssertNil(a.convoID, "nil by default")
          a.convoID = "cv_1"
          XCTAssertEqual(a.convoID, "cv_1")
          XCTAssertNil(b.convoID, "another user's setting is untouched")
          XCTAssertEqual(CoordinatorSetting(userID: "@a:s", defaults: defaults).convoID, "cv_1", "survives a new instance")
      }

      func testClears() {
          let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
          a.convoID = "cv_1"
          a.convoID = nil
          XCTAssertNil(a.convoID)
          a.convoID = "cv_2"
          CoordinatorSetting.clear(for: "@a:s", defaults: defaults)
          XCTAssertNil(a.convoID)
          XCTAssertNil(defaults.object(forKey: CoordinatorSetting.defaultsKey(for: "@a:s")), "clearing removes the key outright")
      }
  }
  ```
  `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter CoordinatorSettingTests` → `cannot find 'CoordinatorSetting' in scope`.

- [ ] **Step 2: Implement**

  Create `MatronShared/Sources/Models/CoordinatorSetting.swift`:
  ```swift
  import Foundation

  /// The designated coordinator conversation (app shell, spec §5b): one
  /// convo id per signed-in journal user, stored in `UserDefaults` under
  /// `coordinator.convoID.<userID>` — the same per-user key shape as
  /// `UserDefaultsBoxCapacityCache`, and readable by `@AppStorage` through
  /// `defaultsKey(for:)` so views update live. `nil` by default; clearing
  /// removes the key. Nothing else about the conversation changes: it stays
  /// in the Conversations list and opens from there as an ordinary chat.
  public struct CoordinatorSetting {
      public static func defaultsKey(for userID: String) -> String {
          "coordinator.convoID.\(userID)"
      }

      private let defaults: UserDefaults
      private let key: String

      public init(userID: String, defaults: UserDefaults = .standard) {
          self.defaults = defaults
          self.key = Self.defaultsKey(for: userID)
      }

      public var convoID: String? {
          get { defaults.string(forKey: key) }
          nonmutating set {
              if let newValue {
                  defaults.set(newValue, forKey: key)
              } else {
                  defaults.removeObject(forKey: key)
              }
          }
      }

      public static func clear(for userID: String, defaults: UserDefaults = .standard) {
          defaults.removeObject(forKey: defaultsKey(for: userID))
      }
  }
  ```

- [ ] **Step 3: Run** `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` → `Executed N tests, with 0 failures` (N = previous + 3).

- [ ] **Step 4: Commit**

  ```
  git checkout -b coordinator-tab
  git add MatronShared/Sources/Models/CoordinatorSetting.swift MatronShared/Tests/ViewModelTests/CoordinatorSettingTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "models: CoordinatorSetting — the coordinator conversation id per user" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 15: iOS chooser, setup view, and the Settings row

**Files:**
- Create: `Matron/Features/Coordinator/CoordinatorChooserSheet.swift`, `Matron/Features/Coordinator/CoordinatorSetupView.swift`, `Matron/Features/Coordinator/CoordinatorSettingRow.swift`
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (properties lines 15–21; form after line 59), `Matron/Features/ChatList/ChatListView.swift` (`DeviceSettingsView(` call lines 154–163)
- Test: `MatronTests/CoordinatorChooserSheetTests.swift` (create)

**Interfaces:**
- Consumes: `ChatListViewModel`, `ChatRow` (internal, `ChatListView.swift`), `NewChatSheet(deps:session:onCreated:)`, `CoordinatorSetting`.
- Produces:
  ```swift
  struct CoordinatorChooserSheet: View {
      init(deps: AppDependencies, session: UserSession, onPick: @escaping (String) -> Void)
      static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary]   // pure, tested
  }
  struct CoordinatorSetupView: View { let onChoose: () -> Void }
  struct CoordinatorSettingRow: View { init(session: UserSession, deps: AppDependencies) }
  // DeviceSettingsView gains `var deps: AppDependencies? = nil`
  ```

- [ ] **Step 1: Failing tests**

  Create `MatronTests/CoordinatorChooserSheetTests.swift`:
  ```swift
  import XCTest
  import MatronChat
  import MatronModels
  @testable import Matron

  /// App shell (spec §5b): the chooser lists the user's conversations with
  /// a search box on top and hands the picked id back through `onPick`.
  @MainActor
  final class CoordinatorChooserSheetTests: XCTestCase {
      private let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)

      func test_filter_matchesTitleCaseInsensitively_andEmptyQueryKeepsAll() {
          let chats = [
              ChatSummary(id: "!1:s", title: "Auth refactor", bot: bot, lastActivity: .now, unreadCount: 0),
              ChatSummary(id: "!2:s", title: "Release notes", bot: bot, lastActivity: .now, unreadCount: 0),
          ]
          XCTAssertEqual(CoordinatorChooserSheet.filtered(chats, query: "").map(\.id), ["!1:s", "!2:s"])
          XCTAssertEqual(CoordinatorChooserSheet.filtered(chats, query: "  AUTH ").map(\.id), ["!1:s"])
          XCTAssertTrue(CoordinatorChooserSheet.filtered(chats, query: "zzz").isEmpty)
      }

      func test_onPick_isInvocable() {
          let deps = AppDependencies()
          let session = UserSession(userID: "@a:s", deviceID: "D",
                                    homeserverURL: URL(string: "https://s")!, accessToken: "t")
          var picked: String?
          let sheet = CoordinatorChooserSheet(deps: deps, session: session) { picked = $0 }
          XCTAssertNotNil(sheet.body)
          sheet.onPick("!1:s")
          XCTAssertEqual(picked, "!1:s")
      }
  }
  ```
  `xcodegen generate`; iOS test command → `cannot find 'CoordinatorChooserSheet' in scope`.

- [ ] **Step 2: Implement the three views**

  `Matron/Features/Coordinator/CoordinatorChooserSheet.swift`:
  ```swift
  import SwiftUI
  import MatronChat
  import MatronModels
  import MatronViewModels

  /// Picks the coordinator conversation (app shell, spec §5b): the user's
  /// existing conversations (the chat-list rows, search box on top) plus a
  /// "New coordinator chat…" row that runs the existing New Chat flow and
  /// stores the resulting id. Owns its own `ChatListViewModel` so it can be
  /// presented from Settings, which has no list of its own.
  struct CoordinatorChooserSheet: View {
      let deps: AppDependencies
      let session: UserSession
      let onPick: (String) -> Void

      @Environment(\.dismiss) private var dismiss
      @State private var viewModel: ChatListViewModel
      @State private var query = ""
      @State private var showingNewChat = false

      init(deps: AppDependencies, session: UserSession, onPick: @escaping (String) -> Void) {
          self.deps = deps
          self.session = session
          self.onPick = onPick
          _viewModel = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
      }

      /// Title match, case-insensitive, whitespace-trimmed; an empty query
      /// keeps every chat. Static so it's unit-testable without rendering.
      static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary] {
          let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !q.isEmpty else { return chats }
          return chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
      }

      private var chats: [ChatSummary] {
          Self.filtered(viewModel.groups.flatMap(\.summaries), query: query)
      }

      var body: some View {
          NavigationStack {
              List {
                  Section {
                      Button {
                          showingNewChat = true
                      } label: {
                          Label("New coordinator chat…", systemImage: "square.and.pencil")
                      }
                  }
                  Section("Conversations") {
                      if viewModel.isLoading {
                          ProgressView()
                      } else if chats.isEmpty {
                          Text("No conversations match.").foregroundStyle(.secondary)
                      }
                      ForEach(chats) { summary in
                          Button { onPick(summary.id) } label: { ChatRow(summary: summary) }
                              .buttonStyle(.plain)
                              .foregroundStyle(Color.primary)
                      }
                  }
              }
              .listStyle(.insetGrouped)
              .searchable(text: $query, prompt: "Search conversations")
              .navigationTitle("Coordinator")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                  ToolbarItem(placement: .cancellationAction) {
                      Button("Cancel") { dismiss() }
                  }
              }
              .task { viewModel.start() }
              .onDisappear { viewModel.cancel() }
              .sheet(isPresented: $showingNewChat) {
                  NewChatSheet(deps: deps, session: session) { convoID in
                      showingNewChat = false
                      onPick(convoID)
                  }
              }
          }
      }
  }
  ```
  `Matron/Features/Coordinator/CoordinatorSetupView.swift`:
  ```swift
  import SwiftUI

  /// The Coordinator tab's root when no coordinator conversation is set
  /// (app shell, spec §3): a short explanation and the chooser button.
  struct CoordinatorSetupView: View {
      let onChoose: () -> Void

      var body: some View {
          ContentUnavailableView {
              Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
          } description: {
              Text("Pick one conversation to act as your coordinator. It keeps its own tab; everything else about it stays the same.")
          } actions: {
              Button("Choose a conversation…", action: onChoose)
                  .buttonStyle(.borderedProminent)
          }
      }
  }
  ```
  `Matron/Features/Coordinator/CoordinatorSettingRow.swift`:
  ```swift
  import SwiftUI
  import MatronModels

  /// Settings → Device → Coordinator (app shell, spec §5b): shows the current
  /// coordinator chat's title with Change and Clear. Reads and writes the
  /// per-user key through `@AppStorage`, so the shell's tab updates live.
  struct CoordinatorSettingRow: View {
      let session: UserSession
      let deps: AppDependencies
      @AppStorage private var convoID: String?
      @State private var showingChooser = false

      init(session: UserSession, deps: AppDependencies) {
          self.session = session
          self.deps = deps
          _convoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
      }

      private var title: String? {
          guard let convoID else { return nil }
          let stored = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
          return (stored?.isEmpty == false) ? stored : convoID
      }

      var body: some View {
          Section("Coordinator") {
              if let title {
                  LabeledContent("Conversation", value: title)
                  Button("Change…") { showingChooser = true }
                  Button("Clear", role: .destructive) { convoID = nil }
              } else {
                  Text("No coordinator conversation yet.").foregroundStyle(.secondary)
                  Button("Choose…") { showingChooser = true }
              }
          }
          .sheet(isPresented: $showingChooser) {
              CoordinatorChooserSheet(deps: deps, session: session) { id in
                  convoID = id
                  showingChooser = false
              }
          }
      }
  }
  ```

- [ ] **Step 3: Wire Settings**

  In `DeviceSettingsView.swift` add after `var onSignOut: (() -> Void)? = nil` (line 21):
  ```swift
      /// App shell (spec §5b): the Coordinator row needs the chat service
      /// (chooser) and the store (title). Optional so previews/tests render
      /// without it.
      var deps: AppDependencies? = nil
  ```
  and after the Devices section (after line 59's `}`), before the Privacy section:
  ```swift
          if let deps {
              CoordinatorSettingRow(session: session, deps: deps)
          }
  ```
  In `ChatListView.swift` add `deps: deps,` to the `DeviceSettingsView(` call (after `agentChatAPI:`; `deps` is already optional there so pass it as is).

- [ ] **Step 4: Run** `xcodegen generate`; iOS test command → `Executed N tests, with 0 failures` (N = previous + 2).

- [ ] **Step 5: Commit**

  ```
  git add Matron/Features/Coordinator/CoordinatorChooserSheet.swift Matron/Features/Coordinator/CoordinatorSetupView.swift Matron/Features/Coordinator/CoordinatorSettingRow.swift Matron/Features/Settings/DeviceSettingsView.swift Matron/Features/ChatList/ChatListView.swift MatronTests/CoordinatorChooserSheetTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: coordinator chooser, setup view and the Settings row" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 16: iOS Coordinator tab

**Files:**
- Create: `Matron/Features/Coordinator/CoordinatorTabView.swift`
- Modify: `Matron/App/AppShellNavigation.swift` (`AppTab`, add `coordinatorPath` + `push(_:on:)`), `Matron/App/AppShellView.swift` (tab list, `@AppStorage`, badge)
- Test: `MatronTests/AppShellNavigationTests.swift` (append), `MatronTests/AppShellViewTests.swift` (modify `items?.count`, append), `MatronTests/CoordinatorTabViewTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  enum AppTab: Hashable { case coordinator, conversations, decisions }
  // AppShellNavigation
  var coordinatorPath: [String]
  func push(_ value: String, on tab: AppTab)     // appends to that tab's stack (Decisions takes an ItemRoute pathValue)
  struct CoordinatorTabView: View {
      enum Root: Equatable { case setup, chat(String) }
      static func root(for convoID: String?) -> Root
      init(session: UserSession, deps: AppDependencies, chatListVM: ChatListViewModel, vmCache: ChatVMCache,
           path: Binding<[String]>, convoID: Binding<String?>)
  }
  ```

- [ ] **Step 1: Failing tests**

  Append to `AppShellNavigationTests`:
  ```swift
      func test_coordinatorTab_hasItsOwnStack() {
          let nav = AppShellNavigation()
          nav.tab = .coordinator
          nav.push("!child:s", on: .coordinator)
          XCTAssertEqual(nav.coordinatorPath, ["!child:s"], "a sub-chat opened from the coordinator pushes on coordinatorPath")
          XCTAssertEqual(nav.chatPath, [], "…not on the Conversations stack")
          XCTAssertEqual(nav.tab, .coordinator)
          nav.push(ItemRoute(id: "it_1").pathValue, on: .coordinator)
          XCTAssertEqual(nav.coordinatorPath, ["!child:s", "item/it_1"])
      }

      func test_deepLink_leavesTheCoordinatorStackAlone() {
          let nav = AppShellNavigation()
          nav.tab = .coordinator
          nav.coordinatorPath = ["!child:s"]
          nav.openChat("!r:s")
          XCTAssertEqual(nav.tab, .conversations)
          XCTAssertEqual(nav.coordinatorPath, ["!child:s"])
      }
  ```
  In `AppShellViewTests.test_shell_showsTwoTabs_atTheRoot` rename to `test_shell_showsThreeTabs_atTheRoot` and expect `bar.items?.count == 3`. Create `MatronTests/CoordinatorTabViewTests.swift`:
  ```swift
  import XCTest
  @testable import Matron

  /// App shell (spec §3): the Coordinator tab's root depends only on the
  /// setting — setup view without one, the chat with one.
  final class CoordinatorTabViewTests: XCTestCase {
      func test_root_isSetupWithoutASetting_andTheChatWithOne() {
          XCTAssertEqual(CoordinatorTabView.root(for: nil), .setup)
          XCTAssertEqual(CoordinatorTabView.root(for: ""), .setup, "an empty stored value is no coordinator")
          XCTAssertEqual(CoordinatorTabView.root(for: "cv_1"), .chat("cv_1"))
      }
  }
  ```
  `xcodegen generate`; iOS test command → `type 'AppTab' has no member 'coordinator'`, `cannot find 'CoordinatorTabView' in scope`.

- [ ] **Step 2: Extend the navigation state**

  In `AppShellNavigation.swift` make the enum `case coordinator, conversations, decisions` (in that order, with a doc line `/// Left to right in the bar; the app opens on Conversations.`), add `var coordinatorPath: [String] = []` after `decisionsPath` with the doc `/// Coordinator tab stack: sub-chats and items opened from the coordinator push here, so back returns to it.`, and add:
  ```swift
      /// Push onto a specific tab's stack without changing the selection.
      /// Decisions takes an `ItemRoute.pathValue` and decodes it.
      func push(_ value: String, on tab: AppTab) {
          switch tab {
          case .conversations: chatPath.append(value)
          case .coordinator: coordinatorPath.append(value)
          case .decisions: if let route = ItemRoute(pathValue: value) { decisionsPath.append(route) }
          }
      }
  ```

- [ ] **Step 3: `CoordinatorTabView`**

  Create `Matron/Features/Coordinator/CoordinatorTabView.swift`:
  ```swift
  import SwiftUI
  import MatronChat
  import MatronModels
  import MatronViewModels

  /// The Coordinator tab (app shell, spec §3): its own `NavigationStack`
  /// whose root is the coordinator conversation's chat — full screen, the
  /// chat's own title, no back button — or `CoordinatorSetupView` when none
  /// is set. Pushes from the coordinator (sub-chats via the strip, item
  /// detail via `ItemRoute`, origin links) land on `path`, so back returns
  /// to the coordinator. The tab bar stays visible at this root (there is
  /// no other way out of the tab); pushed chats and items hide it as usual.
  struct CoordinatorTabView: View {
      enum Root: Equatable {
          case setup
          case chat(String)
      }

      let session: UserSession
      let deps: AppDependencies
      let chatListVM: ChatListViewModel
      let vmCache: ChatVMCache
      @Binding var path: [String]
      @Binding var convoID: String?

      @State private var showingChooser = false

      static func root(for convoID: String?) -> Root {
          guard let convoID, !convoID.isEmpty else { return .setup }
          return .chat(convoID)
      }

      private func summary(for id: String) -> ChatSummary? {
          chatListVM.groups.flatMap(\.summaries).first { $0.id == id }
      }

      var body: some View {
          NavigationStack(path: $path) {
              Group {
                  switch Self.root(for: convoID) {
                  case .setup:
                      CoordinatorSetupView(onChoose: { showingChooser = true })
                          .navigationTitle("Coordinator")
                  case .chat(let id):
                      ChatDestinationView(id: id, summary: summary(for: id), vmCache: vmCache, hidesTabBar: false)
                          .navigationBarBackButtonHidden(true)
                  }
              }
              .navigationDestination(for: String.self) { value in
                  if let route = ItemRoute(pathValue: value) {
                      ItemDetailHost(itemID: route.id, session: session, currentConvoID: convoID,
                                     onOpenConversation: { target in
                                         guard target != convoID else { return }
                                         path.append(target)
                                     })
                  } else {
                      ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
                  }
              }
          }
          .environment(\.chatNavigationPath, $path)
          .sheet(isPresented: $showingChooser) {
              CoordinatorChooserSheet(deps: deps, session: session) { id in
                  convoID = id
                  showingChooser = false
              }
          }
      }
  }
  ```

- [ ] **Step 4: Mount it in `AppShellView`**

  In `AppShellView.swift`:
  1. Add the stored setting after `originTitles`:
     ```swift
         /// The coordinator conversation (spec §5b), live through `@AppStorage`
         /// on the per-user key so Settings' Change/Clear flip the tab at once.
         @AppStorage private var coordinatorConvoID: String?
     ```
     and in `init` add `_coordinatorConvoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))`. Add `import MatronChat` at the top (for `ChatSummary`).
  2. Insert the Coordinator tab FIRST inside `TabView`:
     ```swift
             coordinatorTab
                 .tabItem { Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark") }
                 // The chat-list unread rule as a dot: any unread activity in
                 // that conversation.
                 .badge(coordinatorHasUnread ? "•" : nil as String?)
                 .tag(AppTab.coordinator)
     ```
  3. Add:
     ```swift
         private var coordinatorHasUnread: Bool {
             guard let id = coordinatorConvoID else { return false }
             return (chatListVM.groups.flatMap(\.summaries).first { $0.id == id }?.unreadCount ?? 0) > 0
         }

         private var coordinatorTab: some View {
             CoordinatorTabView(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                                path: $nav.coordinatorPath, convoID: $coordinatorConvoID)
         }
     ```
  4. The Conversations tab needs the list VM running even while another tab shows (the badge and the coordinator title read it): add `.task { chatListVM.start() }` on the `TabView` — `ChatListViewModel.start()` is idempotent per `ChatListView`'s own `.task { viewModel.start() }` (verify by reading `ChatListViewModel.start()`: it cancels any prior `observationTask` before subscribing). Add `.onDisappear { chatListVM.cancel() }` alongside `decisionsVM.stop()`.

- [ ] **Step 5: Run** `xcodegen generate`; iOS test command → `Executed N tests, with 0 failures` (N = previous + 3). Run on the simulator: no setting → setup view with the chooser; pick a chat → the tab shows it with the tab bar; open a subagent from its strip → pushes within the tab and back returns to the coordinator; Settings → Clear → the tab returns to setup.

- [ ] **Step 6: Commit**

  ```
  git add Matron/Features/Coordinator/CoordinatorTabView.swift Matron/App/AppShellNavigation.swift Matron/App/AppShellView.swift MatronTests/AppShellNavigationTests.swift MatronTests/AppShellViewTests.swift MatronTests/CoordinatorTabViewTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "ios: Coordinator tab — the designated conversation on its own stack, setup view otherwise" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```

### Task 17: Mac Coordinator content, chooser, and the Settings row

**Files:**
- Create: `MatronMac/Features/Coordinator/MacCoordinatorChooserSheet.swift`, `MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift`
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (coordinator detail branch from Task 13; state; `MacChatRow` visibility line 651), `MatronMac/Features/Settings/MacDeviceSettingsView.swift` (properties lines 22–27; form before the Appearance section), `MatronMac/App/MatronMacApp.swift` (line 270)
- Test: `MatronMacTests/MacCoordinatorChooserSheetTests.swift` (create)

**Interfaces:**
- Consumes: `MacNewChatSheet(deps:session:windowSize:onCreated:)`, `MacChatRow` (made internal), `CoordinatorSetting`, `chatDetail(for:)`.
- Produces:
  ```swift
  struct MacCoordinatorChooserSheet: View {
      init(deps: AppDependencies, session: UserSession, onPick: @escaping (String) -> Void)
      static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary]
  }
  struct MacCoordinatorSettingRow: View { init(session: UserSession, deps: AppDependencies) }
  // MacDeviceSettingsView gains `var deps: AppDependencies? = nil`
  ```

- [ ] **Step 1: Failing test**

  Create `MatronMacTests/MacCoordinatorChooserSheetTests.swift`:
  ```swift
  #if os(macOS)
  import XCTest
  import MatronChat
  import MatronModels
  @testable import MatronMac

  /// App shell (spec §5b), Mac chooser: same filter contract as iOS and an
  /// invocable `onPick`.
  @MainActor
  final class MacCoordinatorChooserSheetTests: XCTestCase {
      func test_filter_matchesTitle_caseInsensitively() {
          let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
          let chats = [
              ChatSummary(id: "!1:s", title: "Auth refactor", bot: bot, lastActivity: .now, unreadCount: 0),
              ChatSummary(id: "!2:s", title: "Release notes", bot: bot, lastActivity: .now, unreadCount: 0),
          ]
          XCTAssertEqual(MacCoordinatorChooserSheet.filtered(chats, query: "").count, 2)
          XCTAssertEqual(MacCoordinatorChooserSheet.filtered(chats, query: "release").map(\.id), ["!2:s"])
      }

      func test_onPick_isInvocable() {
          let deps = AppDependencies()
          let session = UserSession(userID: "@a:s", deviceID: "D",
                                    homeserverURL: URL(string: "https://s")!, accessToken: "t")
          var picked: String?
          let sheet = MacCoordinatorChooserSheet(deps: deps, session: session) { picked = $0 }
          XCTAssertNotNil(sheet.body)
          sheet.onPick("!2:s")
          XCTAssertEqual(picked, "!2:s")
      }
  }
  #endif
  ```
  `xcodegen generate`; Mac test command → `cannot find 'MacCoordinatorChooserSheet' in scope`.

- [ ] **Step 2: Implement the chooser and the row**

  Change `private struct MacChatRow` (`MacChatListView.swift` line 651) to `struct MacChatRow`. Create `MatronMac/Features/Coordinator/MacCoordinatorChooserSheet.swift`:
  ```swift
  import SwiftUI
  import AppKit
  import MatronChat
  import MatronModels
  import MatronViewModels

  /// Mac chooser for the coordinator conversation (app shell, spec §5b):
  /// the chat-list rows with a search field on top, plus "New coordinator
  /// chat…" which runs the existing New Chat sheet and stores the result.
  /// Owns its own `ChatListViewModel` so Settings (a separate scene with no
  /// list) can present it.
  struct MacCoordinatorChooserSheet: View {
      let deps: AppDependencies
      let session: UserSession
      let onPick: (String) -> Void

      @Environment(\.dismiss) private var dismiss
      @State private var viewModel: ChatListViewModel
      @State private var query = ""
      @State private var showingNewChat = false

      init(deps: AppDependencies, session: UserSession, onPick: @escaping (String) -> Void) {
          self.deps = deps
          self.session = session
          self.onPick = onPick
          _viewModel = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
      }

      static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary] {
          let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !q.isEmpty else { return chats }
          return chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
      }

      private var chats: [ChatSummary] {
          Self.filtered(viewModel.groups.flatMap(\.summaries), query: query)
      }

      var body: some View {
          VStack(spacing: 12) {
              Text("Choose the coordinator conversation").font(.headline)
              TextField("Search conversations", text: $query)
                  .textFieldStyle(.roundedBorder)
              List {
                  Button {
                      showingNewChat = true
                  } label: {
                      Label("New coordinator chat…", systemImage: "square.and.pencil")
                  }
                  .buttonStyle(.plain)
                  if viewModel.isLoading {
                      ProgressView().controlSize(.small)
                  }
                  ForEach(chats) { summary in
                      Button { onPick(summary.id) } label: { MacChatRow(summary: summary) }
                          .buttonStyle(.plain)
                  }
              }
              .listStyle(.inset)
              .frame(minHeight: 280)
              HStack {
                  Spacer()
                  Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
              }
          }
          .padding(16)
          .frame(width: 480, height: 460)
          .task { viewModel.start() }
          .onDisappear { viewModel.cancel() }
          .sheet(isPresented: $showingNewChat) {
              MacNewChatSheet(deps: deps, session: session,
                              windowSize: NSApp.keyWindow?.contentLayoutRect.size) { convoID in
                  showingNewChat = false
                  onPick(convoID)
              }
          }
      }
  }
  ```
  Create `MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift`:
  ```swift
  import SwiftUI
  import MatronModels

  /// Settings → General → Coordinator (app shell, spec §5b): current chat's
  /// title with Change and Clear, through `@AppStorage` on the per-user key.
  struct MacCoordinatorSettingRow: View {
      let session: UserSession
      let deps: AppDependencies
      @AppStorage private var convoID: String?
      @State private var showingChooser = false

      init(session: UserSession, deps: AppDependencies) {
          self.session = session
          self.deps = deps
          _convoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
      }

      private var title: String? {
          guard let convoID else { return nil }
          let stored = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
          return (stored?.isEmpty == false) ? stored : convoID
      }

      var body: some View {
          Section("Coordinator") {
              if let title {
                  LabeledContent("Conversation", value: title)
                  HStack {
                      Button("Change…") { showingChooser = true }
                      Button("Clear", role: .destructive) { convoID = nil }
                  }
              } else {
                  Text("No coordinator conversation yet.").foregroundStyle(.secondary)
                  Button("Choose…") { showingChooser = true }
              }
          }
          .sheet(isPresented: $showingChooser) {
              MacCoordinatorChooserSheet(deps: deps, session: session) { id in
                  convoID = id
                  showingChooser = false
              }
          }
      }
  }
  ```
  In `MacDeviceSettingsView.swift` add after `var onSignOut: (() -> Void)? = nil`:
  ```swift
      /// App shell (spec §5b): the Coordinator row's chooser and title lookup.
      /// Optional so previews/tests render without it.
      var deps: AppDependencies? = nil
  ```
  and, before `Section("Appearance")`:
  ```swift
              if let deps {
                  MacCoordinatorSettingRow(session: session, deps: deps)
              }
  ```
  Bump the frame height on that view from 560 to 640. In `MatronMacApp.swift` line 270 pass `deps: dependencies` to `MacDeviceSettingsView(session: session, deps: dependencies, onSignOut: …)`.

- [ ] **Step 3: Coordinator content in `MacChatListView`**

  1. Add state after `decisionsOriginTitles`:
     ```swift
         /// The coordinator conversation (spec §5b). `session` arrives through
         /// the environment, so this can't be an `@AppStorage` with a per-user
         /// key; it mirrors the defaults key instead and refreshes on every
         /// `UserDefaults` change (Settings' Change/Clear).
         @State private var coordinatorConvoID: String?
         @State private var showingCoordinatorChooser = false
     ```
  2. Add listeners next to the ⌘1/2/3 ones:
     ```swift
         .task(id: session?.userID) {
             coordinatorConvoID = session.map { CoordinatorSetting(userID: $0.userID).convoID } ?? nil
         }
         .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
             coordinatorConvoID = session.map { CoordinatorSetting(userID: $0.userID).convoID } ?? nil
         }
         .sheet(isPresented: $showingCoordinatorChooser) {
             if let deps, let session {
                 MacCoordinatorChooserSheet(deps: deps, session: session) { id in
                     CoordinatorSetting(userID: session.userID).convoID = id
                     coordinatorConvoID = id
                     showingCoordinatorChooser = false
                 }
             }
         }
     ```
  3. Replace the `.coordinator` detail branch's `ContentUnavailableView` (Task 13) with:
     ```swift
             case .coordinator:
                 if let id = coordinatorConvoID, !id.isEmpty {
                     // The coordinator is an ordinary chat in its own slot; its
                     // sub-chats open in this column exactly as from the list.
                     chatDetail(for: id)
                 } else {
                     ContentUnavailableView {
                         Label("Coordinator", systemImage: MacNav.coordinator.symbol)
                     } description: {
                         Text("Pick one conversation to act as your coordinator. It keeps its own place here; everything else about it stays the same.")
                     } actions: {
                         Button("Choose a conversation…") { showingCoordinatorChooser = true }
                             .buttonStyle(.borderedProminent)
                     }
                 }
     ```

- [ ] **Step 4: Run** `xcodegen generate`; Mac test command → `Executed N tests, with 0 failures` (N = previous + 2). Launch the app: ⌘1 shows the setup placeholder; choose a chat; the coordinator chat renders in the detail column with the sidebar collapsed to the nav column; Settings → General → Clear returns the placeholder without relaunch.

- [ ] **Step 5: Commit and open PR 5**

  ```
  git add MatronMac/Features/Coordinator/MacCoordinatorChooserSheet.swift MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift MatronMac/Features/ChatList/MacChatListView.swift MatronMac/Features/Settings/MacDeviceSettingsView.swift MatronMac/App/MatronMacApp.swift MatronMacTests/MacCoordinatorChooserSheetTests.swift
  git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "mac: Coordinator entry shows the designated conversation; chooser and Settings row" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
  ```
  Push; open PR `Coordinator tab and setting` (base: `mac-nav-column`). Add the device-only checks from spec §8 (swipe to tasks and back; leading-edge back swipe on page 0 still pops; keyboard drops on page change; VoiceOver reads the page change; tab bar absent inside a chat and back at the list) to `manual-tests.md` in this PR if that file has a matching section, otherwise list them in the PR body for Dan.

---

## Spec coverage map

| Spec section | Task(s) |
|---|---|
| §1 view model all-mode, `awaitingYou`, factories | 3, 4 |
| §2 `DecisionsListView` | 5 |
| §3 iOS shell tabs, Decisions tab, badge, tab bar hidden, `AppShellView` | 6, 7, 8 (Coordinator tab: 16) |
| §4 tasks pager, `ItemRoute`, drawer deleted | 9, 10 |
| §5 Mac nav column, ⌘1/2/3, Decisions column + detail, widths | 11, 12, 13 (Coordinator content: 17) |
| §5a remove Make task pill | 1, 2 |
| §5b `CoordinatorSetting`, chooser, settings rows, one Decisions VM per session | 14, 15, 16, 17 (VM: 7, 13) |
| §7 error handling (unsupported, offline alert, missing item) | 5, 7, 10, 13 |
| §8 tests | every task's Step 1 |
