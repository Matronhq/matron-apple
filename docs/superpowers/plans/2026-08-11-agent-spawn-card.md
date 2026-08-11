# Agent-Spawn Consent Card Implementation Plan (matron-apple)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agent-spawn consent card on iPhone + Mac with journal-derived resolution and Open deep-link. Requirements source: `docs/superpowers/specs/2026-08-11-agent-spawn-card-design.md` (read it first — wire shapes and state machine live there).

**Architecture:** Mirror the agent-chat card stack; resolution derived from `spawn_outcome` timeline events instead of UserDefaults.

**Tech Stack:** Swift 5.10 SPM package `MatronShared` (XCTest) + XcodeGen app targets. **No local build on this box** — CI (`.github/workflows/ci.yml`, macos-15: `swift test` then iOS/Mac `xcodebuild test`) is the only gate, so tasks are commit-sized but verification is one push at the end.

## Global Constraints

- Wire shapes, state machine, copy strings: exactly as the spec — payload literals in tests copied from its Wire contract section.
- No UserDefaults/persistence writes for spawn answered-state.
- Answer body EXACTLY `{request_id, decision}` — pinned by a `JournalAPITests` invariant test like the agent-chat one (`JournalAPITests.swift:427-430`).
- Composables/views stay logic-free; every decision testable in MatronShared.
- Naming/test style mirrors the agent-chat originals (`AgentChatRequest.swift`, `ChatViewModelAgentChatTests.swift` etc.); newer `func test_lowerCamelSentence` naming.
- Commits: `feat(spawn): …`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

### Task 1: MatronShared logic (Events + Chat + Journal + ViewModels + DesignSystem)

**Files:**
- Create: `MatronShared/Sources/Events/AgentSpawnRequest.swift`, `Events/SpawnOutcome.swift`, `MatronShared/Sources/DesignSystem/AgentSpawnRequestCard.swift`
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift`, `Chat/JournalTimelineMapper.swift`, `MatronShared/Sources/Journal/WireModels.swift` (event type constant if one is required for mapper dispatch), `Journal/JournalAPI.swift`, `Journal/JournalStore.swift` (snippet), `MatronShared/Sources/ViewModels/ChatViewModel.swift`, `ViewModels/AgentChatViewModel.swift`-adjacent protocol slice file (add `AgentSpawnAnswering`)
- Test: `MatronShared/Tests/EventsTests/AgentSpawnRequestTests.swift`, `EventsTests/SpawnOutcomeTests.swift`, extend `ChatTests/JournalTimelineMapperTests.swift`, create `ViewModelTests/ChatViewModelAgentSpawnTests.swift`, extend `JournalTests/JournalAPITests.swift`, extend `JournalTests/JournalStoreTests.swift`

**Interfaces:** exactly the spec's Design section — `AgentSpawnRequest.parse(payload:)`, `SpawnOutcome.parse(payload:)` + `displayLine`, `AgentSpawnCardState`, `TimelineItem` cases `agentSpawnRequest`/`spawnOutcomeRow`, `JournalAPI.answerAgentSpawn(requestID:decision:)`, `ChatViewModel.agentSpawnState(_:request:)` + `answerAgentSpawn(...)` + derived `spawnOutcomes`.

- [ ] Write the full test suite first (it cannot run locally — write it to fail meaningfully on CI if the impl were missing), then the implementation, keeping every file compiling by inspection.
- [ ] Commit: `feat(spawn): agent-spawn card model, mapper, API, and view-model resolution`

### Task 2: App-target wiring (iOS + Mac)

**Files:**
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift` (dispatch + closure props ~:46-53, ~:257-271; `shouldRender` default check ~:348-370), `Matron/Features/Chat/ChatView.swift` (host wiring ~:1031-1039, row gate struct ~:976-986, Open navigation via the sub-chat `NavigationLink(value:)` precedent ~:992-1008), `MatronMac/Features/Chat/MacTimelineItemView.swift` (~:36, :227-243), `MatronMac/Features/Chat/MacChatView.swift` (~:893-899, :948-956, Open via `onOpenSubChat`-style callback), both `AppDependencies.swift` if a service accessor is needed (mirror `agentChatService(for:)`)
- Test: extend `MatronTests/TimelineItemViewTests.swift` (shouldRender binding)

- [ ] Wire both platforms; `prepareConversation` before navigating on Open.
- [ ] Commit: `feat(spawn): render and answer spawn cards on iPhone and Mac`

### Task 3: CI gate

- [ ] Push branch; watch all three CI jobs (`gh run watch` / `gh pr checks`). Fix-forward until green. The shared-package job failing = logic bugs (fast signal); app jobs failing = wiring.
- [ ] Commit fixes as `fix(spawn): …`.
