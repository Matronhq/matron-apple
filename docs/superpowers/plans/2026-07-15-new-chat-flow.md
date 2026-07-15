# New Chat flow — implementation plan

> Spec: `docs/superpowers/specs/2026-07-15-new-chat-flow-design.md` (and the
> journal/bridge contract docs it lists — protocol.md §Agent RPC is
> authoritative). Executed inline in-session, TDD per task.

**Goal:** New Chat button → connected-agent picker → recent-folders picker →
`start` RPC → navigate into the new conversation.

**Wire facts (verified against src/ws.js @ journal 4abf7ef):**
- Outbound: `{op:'agent_request', request_id, agent_device_id, method, params}`.
- Response: `{kind:'rpc', response:{request_id, agent_device_id, ok, result?|error:{code, detail?}}}`.
- Correlated errors: `{kind:'control', op:'error', code, ref:'agent_request', request_id, detail?}`
  — codes seen: `not_ready`, `agent_unreachable`, `not_found`, `bad_request`, `forbidden`.
- `GET /devices` rows now carry `connected: Bool`.
- Duplicate responses possible (multicast) — first resume wins.
- `not_ready`: nothing was forwarded; re-send the identical frame (same
  `request_id`) after ~1 s, max 3 attempts.

## Global constraints

- Never commit `Matron/App/Info.plist` / `MatronMac/App/Info.plist`.
- Assert exact test counts ("Executed N tests").
- Testing follows the devices-pairing precedent: SPM decode + VM tests
  against fakes; no snapshot baselines for the sheets.

### Task 1 — `DeviceDTO.connected`
Files: `MatronShared/Sources/Journal/JournalAPI.swift`,
`MatronShared/Tests/JournalTests/JournalAPITests.swift`.
`connected: Bool` decoded from `GET /devices`, defaulting `false` when the
key is absent (older server). Update `device(...)` test helper (new param,
default false).

### Task 2 — WireModels RPC frames
Files: `MatronShared/Sources/Journal/WireModels.swift`,
`MatronShared/Tests/JournalTests/WireModelsTests.swift`.
- New `RPCResponse: Equatable, Sendable` — `requestID: String`,
  `agentDeviceID: Int64`, `ok: Bool`, `resultData: Data?` (raw JSON bytes,
  JournalEvent.payloadData precedent), `errorCode: String?`,
  `errorDetail: String?`.
- `ServerFrame` gains `.rpcResponse(RPCResponse)`; decode `kind == "rpc"`
  with a `response` object (a `request` object on a client is ignored → nil).
- `.error` case gains `requestID: String?` + `detail: String?` associated
  values (control decode reads `request_id`/`detail`).
- `ClientOp.agentRequest(requestID: String, agentDeviceID: Int64,
  method: String, paramsData: Data)` — `encoded()` splices the params JSON
  via `JSONSerialization.jsonObject(with: paramsData)`, degrading to `{}`.

### Task 3 — Engine correlator: `agentRequest`
Files: `MatronShared/Sources/Journal/JournalSyncEngine.swift`,
`MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift` (existing
fake-connection idioms).
```swift
public enum RPCReply: Equatable, Sendable {
    case ok(resultData: Data)
    case failure(code: String, detail: String?)
}
public enum RPCRequestError: Error, Equatable, Sendable {
    case timeout, offline
}
public func agentRequest(
    agentDeviceID: Int64, method: String, paramsData: Data,
    timeout: Duration = .seconds(15),
    notReadyBackoff: Duration = .seconds(1)
) async throws -> RPCReply
```
- Correlator: `[String: CheckedContinuation<RPCReply, Error>]` keyed by
  `request_id` (UUID). Frame-loop routing: `.rpcResponse` resumes + removes
  (duplicate → no-op); `.error` with a known `requestID` resumes
  `.failure(code:detail:)` — except `not_ready`, which re-sends the identical
  op after `notReadyBackoff` (max 3 sends total, then resumes
  `.failure(code:"not_ready", ...)` → VM shows timeout copy).
- Timeout via a deadline task that resumes `.timeout` and removes the key.
- Connection drop (`liveConnection` nil at send) → throw `.offline`;
  in-flight requests fail on socket teardown (resume all with `.offline`
  where the frame loop exits).

### Task 4 — `NewChatViewModel`
Files: `MatronShared/Sources/ViewModels/NewChatViewModel.swift`,
`MatronShared/Tests/ViewModelTests/NewChatViewModelTests.swift`.
```swift
public protocol AgentRPCProviding: Sendable {
    func devices() async throws -> [DeviceDTO]
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply
}
```
(App-side adapter wraps JournalAPI + engine; timeout stays the engine
default.) Phases: `.agents([DeviceDTO])` → `.folders(agent: DeviceDTO,
folders: [RecentFolder], loadError: String?)` → `.starting` →
`.done(convoID: String)`; plus `errorMessage`, `isStarting`,
`browserEnabled`, `customPath`.
- `load()`: fetch devices; agents only; exactly one connected → auto-select.
- `select(agent:)`: fire `recent_folders` (params `{}`), parse
  `{folders:[{path, last_used}]}` (`last_used` null ⇒ "never used", sorts
  last); parse/RPC failure → `loadError` set, free-text row still works.
- `start(workdir: String?)`: guard `!isStarting`; params
  `{workdir?, browser?}` (workdir omitted when nil/empty; browser only when
  true); map errors per the spec's copy table (timeout & `agent_unreachable`
  & exhausted `not_ready` → "The agent didn't answer — is the box awake?";
  `bad_workdir` → "That folder doesn't exist on the box.";
  else "Couldn't start — ⟨detail ?? code⟩.").
- On `.ok`: decode `convo_id` (missing → generic error), phase `.done`.
Tests: auto-skip, folder sort with nulls last, degraded picker, each error
row, double-start ignored, success.

### Task 5 — `JournalStore.ensureConversation`
Files: `MatronShared/Sources/Journal/JournalStore.swift`, store tests.
`ensureConversation(id: String, title: String?)` — INSERT OR IGNORE a
minimal row (running state, now timestamps) so navigation targets exist
before the `convo_meta` arrives; the real upsert/refreshSummaries overwrites.
Test: creates when absent; never clobbers an existing row.

### Task 6 — iOS UI + navigation
Files: `Matron/Features/ChatList/NewChatSheet.swift` (new),
`Matron/Features/ChatList/ChatListView.swift`, `Matron/App/MatronApp.swift`,
`Matron/App/AppDependencies.swift` (adapter).
Compose button (`square.and.pencil`) top-right → sheet; on `.done`:
`ensureConversation`, dismiss, append to `chatPath` **iff not already the
top element** (the `newConversations()` auto-open will also fire when the
`convo_meta` lands — both paths guard on "already showing" so whichever wins
navigates once).

### Task 7 — Mac UI + navigation
Files: `MatronMac/Features/ChatList/MacNewChatSheet.swift` (new),
`MatronMac/Features/ChatList/MacChatListView.swift`,
`MatronMac/App/AppDependencies.swift`.
Sidebar-header compose button + ⌘N (`.keyboardShortcut("n")`); on `.done`:
`ensureConversation`, dismiss, `selectedSummaryID = convoID` (same
already-showing guard on the auto-open path).

### Task 8 — Suite, builds, PR
Full SPM suite (assert exact count), MatronMacTests (ad-hoc signing, 31+),
both app builds, push, PR with spec+plan committed, Bugbot monitor.
