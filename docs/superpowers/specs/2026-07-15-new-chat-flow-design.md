# New Chat flow — design (apps side)

**Date:** 2026-07-15
**Status:** approved by Dan (chat), implementation pending
**Contract (build against, in dependency order):**
- matron-journal `docs/superpowers/specs/2026-07-15-agent-rpc-design.md` — the
  client→agent RPC design, pinned v1 method vocabulary, error codes, and the
  client-side responsibilities.
- matron-journal `docs/protocol.md` § "Agent RPC (client→agent
  request/response)" — exact op shapes; **authoritative if anything drifts**.
- matron-bridge `docs/superpowers/specs/2026-07-15-rpc-consumer-design.md` —
  what the bridge answers (`bad_workdir`, `spawn_failed`, `unsupported_mode`,
  `unknown_method`; `last_used: null` = never-used folder).

## Problem

Starting a new session today means typing `/start ~/dir` into a bridge's
control conversation. The journal now relays structured RPC: the app can ask
a connected agent for its recent folders and to start a session in one, and
navigate straight into the new conversation.

## The flow (one line)

`GET /devices` → offer agents with `connected: true` → optionally
`agent_request {method:'recent_folders'}` for the picker →
`agent_request {method:'start', params:{workdir, browser?}}` → navigate to
the returned `convo_id`.

## UX (as approved)

**Entry points.** iOS: compose button (`square.and.pencil`) top-right of the
chat list. Mac: same button in the sidebar header, plus ⌘N.

**Agent picker.** Lists agent-kind devices from `GET /devices`. Rows with
`connected: true` are tappable; offline agents are shown greyed with their
existing last-seen text. Exactly one connected agent → skip this step and go
straight to the folder step. Zero connected agents → the screen still shows
the (greyed) roster with copy "No agents connected — is the box awake?".

**Folder step.** On entry, fire `recent_folders`. Show folders newest-first;
`last_used: null` entries sort last and read "never used". Below the list: an
"Other folder…" free-text path row (absolute or `~`-relative), and an
off-by-default "Browser tools" toggle (→ `params.browser = true`). Selecting
a folder (or submitting the text row) fires `start`.

**Starting.** Spinner over the folder step; every start affordance disabled
while a request is in flight (contract: no server dedup, the app must not
double-fire a non-idempotent `start`). On success, dismiss and navigate into
the new conversation by `convo_id`.

**Navigation race.** The `convo_upsert` for the new conversation may land
before or after the RPC response. On RPC success the app upserts a local
provisional conversation row (`id = convo_id`, title "New chat", running
state) if the store doesn't have one yet, then navigates normally; the real
`convo_upsert` overwrites the placeholder whenever it arrives. Whichever
channel wins, the user lands in the chat.

## Error handling (copy is normative)

| Failure | Behavior |
|---|---|
| client timeout (15 s, both methods) | "The agent didn't answer — is the box awake?" + Retry |
| `agent_unreachable` | same copy as timeout (it *is* the same situation) |
| `not_ready` | silent auto-retry of the identical frame after 1 s (spec: nothing was forwarded; verbatim re-send is always safe). Max 3 attempts, then treated as timeout. |
| `bad_workdir` | inline under the path row: "That folder doesn't exist on the box." |
| `spawn_failed` / `unsupported_mode` / `internal` / unknown codes | "Couldn't start — ⟨detail or code⟩." |
| `recent_folders` fails (any reason) | folder list shows a one-line error; the free-text row and start still work. The picker degrades, the feature doesn't. |

`request_id` is a fresh UUID per attempt except the `not_ready` retry, which
re-sends the identical frame verbatim per the contract.

## Components

- **`DeviceDTO.connected: Bool`** — decoded from `GET /devices` (defaults to
  `false` when absent, so the DTO stays compatible with older servers).
- **WireModels**: a new inbound ephemeral frame case for
  `{kind:'rpc', response:{request_id, agent_device_id, ok, result?, error?}}`,
  plus routing of `{op:'error', code, detail?, request_id}` frames that carry
  a `request_id` to the RPC correlator instead of the generic error path.
- **`JournalSyncEngine.agentRequest(agentDeviceID:method:params:timeout:)`** —
  sends `agent_request` with a UUID `request_id`, suspends on a continuation
  keyed by `request_id`, resumes on the matching response frame (duplicates
  from response multicast are ignored: first resume wins, key removed),
  correlated error frame, or timeout. `not_ready` retry lives here (it needs
  the verbatim frame). Returns a typed `RPCReply` (`ok` + raw result JSON, or
  `code`/`detail`).
- **`NewChatViewModel`** (MatronShared) — phases
  `agents → folders(agent) → starting → done(convoID)` + `errorMessage`;
  drives both platforms; tested against a fake RPC provider protocol
  (`AgentRPCProviding`: `devices()` + `agentRequest(...)`).
- **iOS `NewChatSheet`** / **Mac `MacNewChatSheet`** — thin SwiftUI over the
  view model, matching each platform's existing sheet idioms (AddAgentSheet
  precedent).
- **Navigation**: iOS appends `convo_id` to the existing `chatPath`; Mac sets
  `selectedSummaryID`. Both after the provisional-row upsert above.

## Non-goals

- Stopping/listing sessions (no v1 methods; `unknown_method` covers).
- Resume-session UX.
- Showing `connected` on the Devices settings screen (cheap follow-up, not
  part of this flow).

## Testing

- `DeviceDTO` decode with/without `connected`.
- Engine correlator: response resumes the right continuation; duplicate
  response ignored; correlated `op:'error'` resumes with the code;
  `not_ready` → verbatim re-send after backoff (test with short injected
  backoff); timeout fires; unknown `request_id` response is dropped without
  crash.
- `NewChatViewModel`: agent filtering/auto-skip; folder sort (nulls last);
  every error row in the table above; start disabled while pending; success
  path yields `convoID`.
- Snapshot tests for both sheets per repo convention.

## Live-testing caveats (from Dan, 2026-07-15)

The journal side (roster `connected`, pairing, relay) is deployed on
chat.yearbooks.be. **Until the dev-2 bridge restarts onto master ≥ `4217b36`
(#132), `start`/`recent_folders` time out** — the running bridge predates the
RPC consumer. Build against the contract; expect timeouts until that restart.
A freshly-opened socket that is still replaying gets retryable `not_ready`;
connecting with `cursor: null` never sees it.
