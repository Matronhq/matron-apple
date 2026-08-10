# Agent Box Rename + Live Box Chip — Design

**Date:** 2026-08-10
**Status:** Approved by Dan (chip placement + B/C healing strategy confirmed in chat)
**Repos touched:** matron-journal, matron-bridge, matron-apple (Android + web follow up separately)

## Problem

Conversation titles bake in the bridge's `SERVER_LABEL` (`label:xx Fix the thing`),
derived from the hostname. Hostnames that don't end in digits collapse to the same
4-char prefix — Zahra's `dev-y` and `dev-z` boxes both show as `DEV-`. Users cannot
rename the label at all: it is not the journal device name (chosen at pairing, shown
in Settings → Devices), and no rename affordance exists for either.

Two disconnected naming systems today:

1. **Journal device name** — user-chosen at pairing, stored in `devices.name`,
   used by agent-chat room titles. No rename endpoint.
2. **Bridge `SERVER_LABEL`** — hostname-derived, baked into every conversation
   title by the title seed, the first-user-message fallback, the Gemini title
   pass, and resumed-session titles. Shown nowhere in Settings.

## Decision (Dan: "b and c")

- **C:** Stop baking the label into title strings entirely. The box identity is
  data (`conversations.agent_device_id`, which the journal already records) and
  is rendered client-side as a live chip resolved from the device roster.
- **B:** Heal existing baked titles with a one-time journal migration.
- Renaming = renaming the journal device, from Settings → Devices. One name,
  one place, applies everywhere (chips, agent-chat room titles, roster).

## 1. Journal (matron-journal)

### 1.1 Rename endpoint

`POST /devices/:id/rename`, body `{ "name": "dev-y" }`.

- Shape mirrors `POST /devices/:id/revoke` (same route-matching style,
  same ownership check: the device must belong to the caller's user).
- Client-gated (`who.kind === 'client'`), same as `/devices` — an agent must
  not rename devices.
- Validation: trim; reject empty; cap at 40 chars (reject, don't truncate);
  the existing `deviceName()` newline/control sieve applies on every read
  path already, but store the sanitised form anyway. Duplicate names are
  allowed (pairing already merely warns about duplicates).
- Any device kind may be renamed (client or agent) — the name is cosmetic
  and the code is identical.
- Response: `{ ok: true, device: { device_id, name } }`.

### 1.2 Snapshot carries box identity

`snapshot()` (`src/journal.js`) grows:

- `agent_device_id` in each conversation row (already selected by `/roster`;
  add to the client snapshot's SELECT).
- A top-level `agents` array: `[{ device_id, name }]` for the user's
  `kind='agent'` devices, so clients resolve id → name from the snapshot
  alone. Names pass through `deviceName()`. Private-device filtering follows
  the existing `/snapshot` rules (clients see everything; the agent-caller
  case keeps its current filter).

### 1.3 Live events

- `convo_meta` (WS fan-out on conversation upsert) adds `agent_device_id`
  to its payload, so a brand-new conversation gets its chip without a
  snapshot round-trip. Included whenever meta changes, same trigger as today.
- New `device_meta` fan-out on rename: `{ kind: 'device_meta', device_id,
  name }` to all of the user's **client** connections. Fired only by the
  rename endpoint. Clients update their local agent table; no re-snapshot.

### 1.4 One-time healing migration (option B)

A schema-version-gated migration (same mechanism as existing journal
migrations) rewrites `conversations.title` once:

- Strip `^X:hh ` where `X` is 1–12 non-space chars and `hh` is exactly two
  `[0-9a-zA-Z]` chars — the fallback/Gemini form (`DEV-:a3 Fix the thing`;
  the suffix comes from a UUID or a Matrix room-id localpart, hence the
  mixed-case charset).
- Strip `^X: ` (label + colon + space) **only when the remainder contains no
  spaces** — the workdir-seed form (`DEV-: matron-apple`). The no-spaces
  guard keeps organic titles like `Fix: parser bug` untouched.
- Log every rewrite (`old → new`, convo id) at info level — BYOS users run
  this unattended and deserve an audit trail. No dry-run gate: the patterns
  are tight enough, and titles are cosmetic and Gemini-refreshed on the next
  active turn anyway.

## 2. Bridge (matron-bridge)

Stop embedding the label in titles, all four sites:

- `lib/journal-title-seed.js` `seedTitleFor` → workdir basename only
  (`matron-apple`, not `DEV-: matron-apple`). The seed-clobber-protection
  comparisons keep working since both sides use the new form; keep the old
  prefixed forms in the "still a seed, fair game to replace" check so
  pre-upgrade seeds still get upgraded by the fallback.
- `applyFallbackTitle` → first-user-message text only. The `label:xx `
  prefix **and** the two-char session suffix both go — the chip plus
  timestamps now disambiguate sessions in the same workdir.
- Gemini title pass (`index.js` ~4994) → `parsed.title` alone.
- Resumed-session titles (`index.js` ~5597) → drop the `${SERVER_LABEL}: `
  prefix.

Matrix room names follow along (the bridge has a single title pipeline via
`updateRoomName`; splitting Matrix-vs-journal naming isn't worth it).
`SERVER_LABEL` itself stays for `/help` text and logs.

**Deploy order:** bridges before the journal migration — an old bridge's
Gemini pass re-bakes the prefix onto healed titles. If that happens anyway
the damage is cosmetic and the migration can be re-run (it is idempotent:
healed titles no longer match the patterns).

## 3. Apple apps (matron-apple)

### 3.1 Data layer

- `ConvoSummaryDTO` + `ConversationRecord` gain `agentDeviceID: Int64?`;
  GRDB migration adds the column to `conversation`.
- New GRDB table `agent` (`id INTEGER PRIMARY KEY`, `name TEXT NOT NULL`),
  replaced wholesale on each snapshot apply and patched by `device_meta`.
- `convo_meta` handling stores `agent_device_id` when present.
- `ChatSummary` gains `agentName: String?`, resolved by joining
  `conversation.agent_device_id` → `agent.name` in the list query.

### 3.2 Chip UI

- Rendered **only when the user has ≥2 agent boxes** (count of `agent`
  rows); single-box users see no change.
- Conversation list rows (Mac `MacChatRow` + iOS equivalent): small
  capsule chip with the box name, next to the title line, matching the
  existing secondary-text styling.
- Chat header (Mac toolbar subtitle area / iOS nav subtitle): the box name
  appears with the workdir, same ≥2 gate.
- Unknown `agent_device_id` (revoked device): no chip. Nil: no chip.

### 3.3 Rename UI

Settings → Devices (`DevicesViewModel`): a Rename action on each device row
(swipe/menu on iOS, hover button on Mac) opening a text-field alert
pre-filled with the current name. `DevicesProviding` gains
`renameDevice(id:name:) async throws -> DeviceDTO`; on success the roster
refreshes. Journal-side `device_meta` fans the change to other devices.

## 4. Out of scope

- Android + web ports (follow-up phase, same pattern as prior features).
- Per-conversation label overrides.
- Bridge awareness of its own display name (agent-chat already fetches it
  from the roster where needed).
- Stripping prefixes client-side (server data is healed instead).

## Testing

- **Journal:** unit tests for rename validation (empty, >40, sanitisation,
  wrong owner, agent-token 403), `device_meta` fan-out, snapshot shape
  (`agents` array + `agent_device_id`), and migration cases: fallback form,
  seed form, `Fix: parser bug` untouched, idempotency on re-run.
- **Bridge:** existing title-seed tests updated to the unprefixed forms;
  a test that a pre-upgrade prefixed seed is still recognised as
  replaceable by the fallback.
- **Apple:** `swift test` in MatronShared for DTO parsing, GRDB migration,
  chip name resolution join, and the ≥2-boxes gate; snapshot tests for the
  chip row states (`MATRON_SKIP_SNAPSHOT_TESTS=1` locally, never run
  MatronMacTests without `MATRON_APP_SUPPORT_OVERRIDE`).
