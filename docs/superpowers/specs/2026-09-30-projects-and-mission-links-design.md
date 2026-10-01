# Projects above missions, and conversations that keep every mission they touched: design

Date: 2026-09-30. Status: **approved to build by Dan (30 Sep)**; all nine questions decided. Implementation plans follow. Repos: matron-journal, matron-bridge, matron-apple;
matron-web follows once the Apple design settles.

## Why

Dan, 30 Sep 2026 (voice): the Missions view "still isn't useful. It shows
too much detail, and the useful overall picture is hard to see." He
proposed two things:

1. **A Project object that groups missions.** For example, "Promo launch"
   would group the launch-day mission, the promo branch, SEO phase 2, the
   promo site and blog, and the combined promo branch.
2. **Conversations that belong to more than one mission.** A conversation's
   header links only to its current mission, so any earlier mission it
   worked on is lost. The header should show every mission the
   conversation has touched, and each mission should list all of its
   conversations.

The missions dashboard spec (2026-09-28) made the Missions tab "the answer
to 'what's the status of everything?'". It answers that question for one
mission at a time. At today's scale there are too many missions for that
to add up to an overview.

## 1. Audit of today's screens

Screenshots are in `2026-09-30-projects-assets/audit/`. The real-data Mac
shots are from 29 Sep and come from the matron-web design audit. The iOS
shots and the Mac mission page v2 use the fixtures from the screenshot rig
and the snapshot tests.

### Scale (live journal, 30 Sep 2026 09:20 UTC)

| | Count |
|---|---|
| Open missions | **117** |
| … with a written status | 24 (so 93 have none) |
| … whose last milestone is over 7 days old | about 41 |
| … unassigned, with no conversation and no milestone | 12 |
| Missions at the 200-conversation cap (2407, 2531) | 2; three more are above 160 |

The dashboard shows one mission card per open mission. A 3-column Mac grid
therefore runs to about 40 rows of cards, and each card is 250–450 pt
tall.

### Mac missions dashboard (`audit/mac-dashboard-real-2026-09-29.jpg`)

**Noise:**
- Every card repeats its sessions: up to 4 rows, each with a tag chip, a
  title and a **2-line roster summary**. That is where most of each card's
  height goes. Much of it is the "what's happening now" prose that the
  status paragraph already sums up.
- Each card shows both the status paragraph and a "latest step" line. The
  two usually say the same thing.
- Each card lists up to 3 needs-you item rows. The Decisions tab already
  lists all of them, and the red pill already counts them.
- A mission quiet for three weeks gets the same card as one running now.
  Nothing separates live work from dead work.

**Missing:**
- Any grouping above the mission.
- A sense of which work is live and which has stalled.
- A way to see the next date or blocker across related missions.

### Mac mission page v2 (`audit/mac-mission-page-v2-fixture.png`, `audit/mac-mission-page-real-2026-09-29.jpg`)

This page is in good shape. The status card, latest step, needs-you card,
sessions, open items and milestones paged 20 at a time all belong here.

**Noise:**
- "Latest step" repeats the top milestone directly below it.
- The Milestones card shows a full body under every title. At 20 per page,
  it reads like a log.

**Missing:**
- The project the mission belongs to.
- Sessions that worked on the mission earlier. The page lists only
  conversations whose single `mission_id` is this mission, so a
  conversation that did work here before this mission existed, or that was
  refused a join (see §3), never appears.
- Sub-chats. They inherit the mission and count toward the cap, but are
  not grouped under their parent conversation.

### iOS Missions tab and mission page (`audit/ios-*.png`)

- **The tab** shares the Mac card, so it has the same noise. On a phone
  that becomes one or two missions per screen: 117 missions is roughly
  80 screens of scrolling.
- **The mission page** is behind the Mac page:
  - **It never shows the status paragraph**, even though status is the main
    thing the dashboard was built to show.
  - It has no latest step and no needs-you section.
  - It lists every milestone unpaged, each with a 2-line body.
  - Conversations show a raw state string.

### Conversation header (Mac and iOS)

- The header never names the mission. The title silently becomes a button
  when a mission exists, and nothing tells you it is one.
- The app resolves the mission locally from three sources in turn: the
  mission this conversation created, then the `mission_conversation`
  mirror, then the mission of the newest milestone. It can only ever find
  one mission.

### Web (matron-web)

- There is a row list and a single-column detail inside the Tracker pane,
  with no status and no board.
- The chat header shows nothing about missions.
- The web missions screens are **on hold** (mission 4706) until the Mac
  design settles. This plan is that settling, so the web gets the result
  and not a separate design.

### Root causes in the data model

- **`conversations.mission_id` is a single column, "set once and never
  changed".**
  - `POST /missions/:id/join` on a conversation that already has a mission
    returns **409 `other_mission`**.
  - `mission_start` on such a conversation returns the old mission with
    `existing: true`.
  - So a long-running session that moves on to new work can never be
    linked to it. It either keeps posting milestones to the old mission, or
    the new mission never learns about it.
  - Nothing records history. There is no leave route, and nothing ever
    resets the column to NULL.
- **Sub-chats inherit their parent's mission and count toward
  `CONVOS_MAX = 200`.**
  - Missions 2407 and 2531 are full, so every new sub-chat there silently
    starts with **no** mission (`inheritableMission`, gate 3).
  - That is the other way links get lost.
- **Nothing exists above the mission.** The journal has no grouping entity
  (item labels exist, but only on items).

## 2. Information hierarchy

The rule: **each level shows one sentence about each thing one level
down, and nothing from two levels down.**

| Level | Shows at a glance | Drill-down only |
|---|---|---|
| **Projects home** (replaces the Missions tab) | Project cards, each with: title, needs-you count, **one** status paragraph (2–3 lines), a state bar (running / waiting / quiet), counts, and when it was last updated. Below the cards: missions not in a project, as **slim rows** (dot, number, title, one-line status, needs-you count, age). A "Quiet for over a week (n)" fold. A "Closed (n)" fold. | Sessions, milestones, item rows |
| **Project page** | Title and goal; the status card; missions as rows (one-line status, needs-you, 2 session chips); needs-you items across all missions, each with a mission chip; the latest **5** milestones across missions; session count per box | Each mission's milestones, board and conversations |
| **Mission page** | Breadcrumb Projects › Project › #N; status; needs you; **conversations grouped "On it now" / "Earlier"** with sub-chats folded; the last 5 milestones (more on request); open items; board | Transcript (jump from a milestone) |
| **Conversation header** | Chip showing the current mission plus "+n" for the others | Menu or sheet listing every mission touched, with dates |

The mockups are in `2026-09-30-projects-assets/mockups/`. The HTML sources
sit next to the PNGs. Project names and groupings in the mockups are
illustrative; the missions and statuses are real ones from 30 Sep.

- `01-mac-projects-home.png`: Projects home.
- `02-mac-project-page.png`: the "Promo launch" project page.
- `03-mac-mission-conversations.png`: a mission's conversations, On it now
  and Earlier, beside the conversation header chip and its menu.
- `04-ios.png`: iOS Projects tab, project page, and the chat header's
  missions sheet.

**What the mission card loses**, compared with PR 267:
- the session rows
- the latest-step line
- the needs-you item rows

What stays: the status line, the needs-you count, activity and age.
Sessions remain on the mission page. Needs-you items remain on the project
page and in the Decisions tab.

**Activity state per mission** is computed by the server (§4.2):
- `running`: any linked conversation is running.
- `waiting`: any linked conversation is waiting, or the mission has items
  awaiting Dan.
- `quiet`: no milestone, status update or conversation activity for
  7 days.
- `idle`: none of the above.

Quiet missions fold away on the home screen, and the Coordinator's sweep
proposes closing or filing them.

## 3. Conversation ↔ mission: many-to-many with history

### Semantics (recommended)

- A conversation has any number of **links** to missions. Each link is
  either **active** or **ended**, and records when and how it was made.
- Exactly one active link is **current**, or none is. The current link is
  where `milestone_post` and new items go by default. `conversations.mission_id`
  stays as the pointer to it, so existing readers keep working.
- **`mission_join(N)`:**
  - adds a link, or reactivates an ended one, and makes it current;
  - the previous current mission stays active ("also on"), and is no
    longer refused.
- **`mission_leave(N)`** (new) ends a link. If it was the current one,
  current moves to the most recently joined remaining active link, or to
  none.
- **`milestone_post(mission?)`** may name any mission the conversation has
  an active link to. The default is the current one.
- **Closing a mission** leaves its links in place as history. Clients show
  them under "Earlier" because the mission is closed.
- **Sub-chats** inherit the parent's current mission (how = `inherited`) as
  they do today. They are **not counted** toward `CONVOS_MAX`, which from
  now on counts top-level conversations (`parent_convo_id IS NULL`). The
  mission page folds each sub-chat under its parent.

### Journal schema

```sql
CREATE TABLE IF NOT EXISTS mission_conversations (
  mission_id TEXT NOT NULL,
  convo_id   TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  how        TEXT NOT NULL,      -- origin | joined | spawned | inherited | backfill
  joined_at  INTEGER NOT NULL,
  ended_at   INTEGER,            -- NULL = active
  PRIMARY KEY (mission_id, convo_id)
);
CREATE INDEX IF NOT EXISTS idx_mc_convo ON mission_conversations(convo_id, ended_at);
```

- **`conversations.mission_id`** is kept as the *current* pointer.
  Invariant: when it is non-null, an active link exists for it. It changes
  only through join, leave, spawn or inheritance.
- **Following house style**, there are no foreign keys and ownership is
  checked on write. The migration is a `CREATE … IF NOT EXISTS` in
  `SCHEMA`, placed after the table-rebuild blocks.
- **Backfill** runs once, guarded by an empty table. It inserts one row per
  (mission, conversation) pair found in any of:
  - `conversations.mission_id`: active, how = `origin` if the mission's
    `origin_convo_id` matches, otherwise `joined`;
  - `milestones.convo_id`;
  - items created in a conversation (`items.origin_convo_id` with
    `mission_id`).

  Pairs found only through milestones or items get how = `backfill` and
  `ended_at` = their last milestone or item time. This recovers some of the
  earlier-mission history that is lost today. Pairs that left no trace
  cannot be recovered.

### Routes

| Route | Change |
|---|---|
| `POST /missions/:id/join` | No more 409 `other_mission`. Adds or reactivates a link and makes it current. The cap counts top-level conversations. |
| `POST /missions/:id/leave` `{convo_id}` | **New.** Ends the link and moves `current` as described above. 404 if there is no link. |
| `POST /milestones` | Optional `mission` (id, `#n` or `n`), which must be an active link. Otherwise 409 `not_linked`. |
| `GET /conversations/:id/missions` | **New.** `{missions:[{mission row…, current, active, joined_at, ended_at, how}]}`, current first, then active, then ended newest first. Feeds the header, and gives the bridge's cold-cache lookup one call instead of an O(n) scan. |
| `GET /missions/:id` | `conversations[]` rows gain `current`, `joined_at`, `ended_at`, `how`, `parent_convo_id` and `subchat_count`. Sub-chats are folded into their parent's row by default; `?subchats=1` lists them. |
| Snapshot conversation rows | Gain `mission_id` (current) and `mission_count`, so the header can draw its chip without a fetch. |

The `mission` marker gains the actions `left` and `current_changed`. Each is
appended to the conversation concerned, as `joined` is today.

## 4. Projects

### 4.1 Journal schema

```sql
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,               -- pj_…
  user_id TEXT NOT NULL,
  num INTEGER NOT NULL,              -- shared per-user counter (items/missions/milestones)
  state TEXT NOT NULL DEFAULT 'open',-- open | closed
  title TEXT NOT NULL,
  body TEXT,
  status TEXT, status_by TEXT, status_convo_id TEXT, status_updated_at INTEGER,
  close_summary TEXT, closed_by TEXT, closed_at INTEGER,
  merged_into TEXT,                  -- pj_… when closed by a merge
  origin_convo_id TEXT, created_by TEXT NOT NULL, idem_key TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  UNIQUE(user_id, num), UNIQUE(user_id, idem_key)
);
-- missions gains: project_id TEXT (nullable), index (project_id, state)
```

- A mission belongs to **at most one** project.
- Projects share the `#N` number space, so `/lookup` and the `#N` links
  (mission 3747) resolve them with no extra work.
- The privacy sieve works as for missions: a project status written from a
  private-owned conversation is withheld from ordinary agents.

### 4.2 Routes

| Route | Body / response |
|---|---|
| `POST /projects` | `{title, body?, convo_id?}` plus an idempotency key → 201 `{project}` |
| `GET /projects?state=` | `{projects:[{…, missions:{running, waiting, idle, quiet, closed}, needs_you, open_items, last_activity_at}]}` |
| `GET /projects/:id` | `{project, missions:[list rows], needs_you:[items with mission_num], recent_milestones:[5], sessions_by_box:{box: n}}` |
| `PATCH /projects/:id` | `{title?, body?, status?: string\|null, convo_id?}`. Status rules are copied from mission status (1–600 chars). |
| `POST /projects/:id/close` | `{summary}`. Open missions block it (409 `open_missions`) unless the user closes it; that close is recorded, as for missions. |
| `POST /projects/:id/merge` | `{into}`. Moves every mission to `into`, closes the source with the summary "Merged into #N", and records `merged_into` on it. `/lookup` and `GET /projects/:id` for the old project redirect to the target. Allowed for the user and the Coordinator; other agents get 403 `not_coordinator`. |
| `PATCH /missions/:id` | Gains `project: id\|#n\|n\|null` to file a mission in a project or take it out. |
| `POST /missions` | Gains optional `project`. |
| `GET /missions` | Rows gain `project_id`, `project_num` and `activity`. |

- Project changes need no new marker type. Moving a mission appends the
  existing `mission` `updated` marker with `project_changed: true`.
- Apps refresh `GET /projects` on any mission marker, and while the
  Projects tab is open. That is the same mechanism as `MissionsSync`.

## 5. Bridge

- **New tools** (`ask-user.js` → `/projects/<op>` → `lib/projects-tools.js`,
  cloned from the missions trio):
  - `project_list`, `project_get(num?)`
  - `project_create(title, body?)`
  - `project_update(num, title?, body?)`
  - `project_status(num, status)`
  - `project_close(num, summary)` and `project_merge(num, into)`,
    Coordinator only.
  - Any agent may call `project_create`, as Dan decided on question 3.
    The Coordinator merges any duplicates that result.
- **Changed tools:**
  - `mission_start` and `mission_create` gain `project?`.
  - `mission_update` gains `project` (`#N` or null).
  - `mission_join` no longer reports "already belongs to another mission".
  - `mission_leave(num)` is new.
  - `milestone_post` gains `mission?`.
- **`resolveMission`** uses `GET /conversations/:id/missions` for a cold
  cache, and caches the *current* id as now.
- **Prompts:**
  - `BRIDGE_CLAUDE.md` and `BRIDGE_CODEX.md` get a short missions
    paragraph: join, not refusal, when you move to new work; leave when you
    are done with a mission; name the mission on `milestone_post` when you
    are on several. When you start a mission, run `project_list` and file
    it into the project it belongs to. Create a project only when none
    fits.
  - `BRIDGE_COORDINATOR.md`: the status sweep also writes each project's
    status and merges near-duplicate projects (it reports each merge in its
    reply). It files one question proposing which unfiled missions go into
    which project, and which quiet missions to close. It never moves
    missions between projects, or closes them, without Dan's answer.
  - The word "project" also means a working directory, as in
    `~/.claude/projects`. The prompt defines a Project once, as the
    tracker object, to keep the two apart.

## 6. Apps (matron-apple)

- **Navigation:** the Missions tab and nav entry become **Projects** (⌘2,
  same position; the badge is the needs-you total).
- **Shared layer:**
  - `ProjectsHomeView` replaces `MissionsDashboardView`.
  - It is built from `ProjectCardView`, `MissionRowView` (slim; replaces
    `MissionCardView` on the home screen), the Quiet fold and the Closed
    fold.
  - The "Not on a mission" loose-sessions group moves to the Chats tab.
    **Assumption:** it is session-level detail, so it doesn't belong on
    the overview.
- **Project page:** a two-column Mac layout like the mission page, a
  single `List` on iOS.
- **Mission page:**
  - A project chip and breadcrumb.
  - The Conversations card becomes On it now / Earlier, with sub-chats
    folded.
  - Milestones show 5 at first, then "Show more".
  - iOS gains the status card and a needs-you section, which fixes the
    parity gap.
- **Header:**
  - Mac: a chip in the header accessory shows the current mission and
    "+n". Its menu lists Current / Also on / Earlier and opens each
    mission's page.
  - iOS: the chip sits under the title and opens a sheet with the same
    list.
  - The title stops being a hidden button.
- **Filing:** a "Move to project…" menu on mission rows and on the mission
  page. "New project" appears on the home screen, and "Merge into…" on the
  project page.
- **Data:**
  - GRDB migration: a `project` table; `mission.project_id` and
    `mission.activity`; `mission_conversation` gains `joined_at`,
    `ended_at`, `how`, `is_current` and `parent_convo_id`.
  - `ProjectsSync` is cloned from `MissionsSync`.
  - `JournalStore.missionIDStream` becomes `missionsStream(convoID:)`, fed
    by `GET /conversations/:id/missions` and the snapshot fields.
- **Snapshots:** replace the dashboard and card baselines; add project page
  and header chip baselines, on Mac and iOS widths.

## 7. Rollout and compatibility

The order is journal, then bridge, then apps. Web follows under mission
4706.

- **New journal with an old bridge:** join now succeeds where it used to
  fail with 409. The old bridge treats 200 as success. Nothing else
  changes.
- **New journal with old apps:** they keep reading `conversations.mission_id`
  and the `mission_conversation` mirror they already have. They see no
  projects and no history.
- **New apps with an old journal:** `GET /projects` returns 404, so the tab
  falls back to today's missions dashboard (the same route-probe as the
  mission status fallback).
- **Seeding after ship:** the Coordinator files one question with a
  proposed grouping of the open missions, starting with Dan's "Promo
  launch" (4907, 4791, 4905, 2407, 4083). Dan approves or edits it, then
  the Coordinator applies it.

## 8. Questions for Dan

Each one is filed as a tracker question with options and a recommendation.

1. **Name.** **Decided (Dan):** "Project", with the prompt definition that
   separates it from a working-directory project.
2. **How many projects per mission.** **Decided (Dan):** one or none.
3. **Who creates projects and files missions.** **Decided (Dan): any
   agent**, because not everyone uses a Coordinator and creating every
   project by hand would be tedious. The Coordinator (or Dan in the apps)
   merges duplicates with `project_merge`.
4. **Where a project's status comes from.** **Decided (Dan):** a paragraph
   written by the Coordinator, plus server-derived counts.
5. **Home density.** **Decided (Dan):** slim project cards and slim mission
   rows, with a 7-day quiet fold. No sessions on the home screen.
6. **Conversation↔mission semantics.** **Decided (Dan):** many active links
   with one current, plus leave and history.
7. **Sub-chats and the 200 cap.** **Decided (Dan):** fold sub-chats under
   their parent and count only top-level conversations.
8. **Tab.** **Decided (Dan):** rename Missions to Projects, with unfiled
   missions below the project cards.
9. **Backfill.** **Decided (Dan):** backfill links from milestones and items.

## 9. Out of scope

- Projects shared with colleagues.
- Project boards.
- Due dates as a field (dates stay in the status text).
- Nesting projects.
- Web screens, until the Apple design is built and settled.
- Automatic filing of missions without Dan's answer.
