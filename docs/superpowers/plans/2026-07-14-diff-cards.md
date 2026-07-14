# Rich Diff Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain "✏️ Editing path" chat messages with structured journal `diff` events rendered as rich, expandable diff cards with a viewer-linked filename header.

**Architecture:** The bridge computes a unified diff at tool_use time (`lib/edit-diff.js`, jsdiff), publishes it as a journal `diff` event via a new `publishDiff` publisher method, and stops posting the Matrix indicator entirely (main agent AND subagents). The apps gain a `DiffEvent` model, a `.diff` timeline kind mapped from the payload, and a `DiffCard` DesignSystem view rendered on both platforms.

**Tech Stack:** Node (bridge, vitest), `diff` npm package (jsdiff), Swift/SwiftUI SPM packages (XCTest + swift-snapshot-testing).

**Spec:** `docs/superpowers/specs/2026-07-14-diff-cards-design.md`

## Global Constraints

- Two repos: bridge tasks (1–3) in `~/Dev/claude-matrix-bridge` (branch `feat/diff-cards` off `master`); app tasks (4–7) in `~/Dev/matron-apple` (branch `feat/diff-cards`, stacked on `feat/tool-stream-overlay`).
- Diff caps: 400 lines or 64 KB (whichever first), `truncated: true`, counts computed BEFORE truncation.
- Collapsed card shows first 12 lines; expand shows all.
- Journal payload keys exactly: `file_path, display_path, viewer_url, tool, label, diff, added, removed, truncated, new_file`.
- No Matrix message for Edit/Write/MultiEdit — no `isKeyEvent`, no sendHtml/sendCallback; `session.toolCalls` still gets the plain line.
- Bridge journal calls fail open; never touch the Matrix hot path.
- Never commit the local `Info.plist` NSAllowsLocalNetworking edits.
- Bridge `npm test` has 5 PRE-EXISTING failures (interactive-session, pre-trust) — assert no NEW failures, don't chase those.
- App test runs must assert "Executed N tests" per suite — never grep-quiet a pass.

---

### Task 1: Bridge — `lib/edit-diff.js` diff computation

**Files:**
- Create: `~/Dev/claude-matrix-bridge/lib/edit-diff.js`
- Create: `~/Dev/claude-matrix-bridge/test/edit-diff.test.js`
- Modify: `~/Dev/claude-matrix-bridge/package.json` (add `diff` dependency)

**Interfaces:**
- Produces: `computeEditDiff(toolName, input, workdir) -> Promise<{diff: string, added: number, removed: number, truncated: boolean, newFile: boolean} | null>` — null means "nothing publishable" (unknown tool, missing fields, no-op edit).

- [ ] **Step 1: Branch + dependency**

```bash
cd ~/Dev/claude-matrix-bridge && git checkout master && git pull --ff-only && git checkout -b feat/diff-cards
npm install diff@^7
```

- [ ] **Step 2: Write the failing tests**

`test/edit-diff.test.js`:

```javascript
import { describe, it, expect } from 'vitest';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { computeEditDiff } from '../lib/edit-diff.js';

describe('computeEditDiff', () => {
  it('Edit: line diff of old_string -> new_string with hunk header and counts', async () => {
    const r = await computeEditDiff('Edit', {
      file_path: '/tmp/x.swift',
      old_string: 'let a = 1\nlet b = 2\nlet c = 3',
      new_string: 'let a = 1\nlet b = 99\nlet b2 = 100\nlet c = 3',
    }, '/tmp');
    expect(r).not.toBeNull();
    expect(r.diff).toMatch(/^@@ /m);
    expect(r.diff).toContain('-let b = 2');
    expect(r.diff).toContain('+let b = 99');
    expect(r.diff).toContain('+let b2 = 100');
    expect(r.diff).not.toMatch(/^---|^\+\+\+/m); // no file header lines
    expect(r.added).toBe(2);
    expect(r.removed).toBe(1);
    expect(r.truncated).toBe(false);
    expect(r.newFile).toBe(false);
  });

  it('Edit: identical strings (no-op) -> null', async () => {
    const r = await computeEditDiff('Edit', {
      file_path: '/tmp/x', old_string: 'same', new_string: 'same',
    }, '/tmp');
    expect(r).toBeNull();
  });

  it('Write: diffs against existing on-disk content', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'editdiff-'));
    const f = path.join(dir, 'a.txt');
    await fs.writeFile(f, 'one\ntwo\nthree\n');
    const r = await computeEditDiff('Write', { file_path: f, content: 'one\nTWO\nthree\n' }, dir);
    expect(r.newFile).toBe(false);
    expect(r.diff).toContain('-two');
    expect(r.diff).toContain('+TWO');
    expect(r.added).toBe(1);
    expect(r.removed).toBe(1);
  });

  it('Write: absent file -> newFile all-additions', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'editdiff-'));
    const r = await computeEditDiff('Write', {
      file_path: path.join(dir, 'nope.txt'), content: 'hello\nworld\n',
    }, dir);
    expect(r.newFile).toBe(true);
    expect(r.added).toBe(2);
    expect(r.removed).toBe(0);
    expect(r.diff).toContain('+hello');
    expect(r.diff).toContain('+world');
  });

  it('Write: relative file_path resolves against workdir', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'editdiff-'));
    await fs.writeFile(path.join(dir, 'rel.txt'), 'a\n');
    const r = await computeEditDiff('Write', { file_path: 'rel.txt', content: 'b\n' }, dir);
    expect(r.newFile).toBe(false);
    expect(r.diff).toContain('-a');
    expect(r.diff).toContain('+b');
  });

  it('MultiEdit: one hunk per edit, concatenated in order', async () => {
    const r = await computeEditDiff('MultiEdit', {
      file_path: '/tmp/x',
      edits: [
        { old_string: 'foo', new_string: 'bar' },
        { old_string: 'baz\nqux', new_string: 'baz\nQUX' },
      ],
    }, '/tmp');
    expect(r.diff.match(/^@@ /gm).length).toBe(2);
    expect(r.diff.indexOf('+bar')).toBeLessThan(r.diff.indexOf('+QUX'));
    expect(r.added).toBe(2);
    expect(r.removed).toBe(2);
  });

  it('caps at 400 lines with truncated=true and pre-truncation counts', async () => {
    const oldLines = Array.from({ length: 600 }, (_, i) => `old ${i}`).join('\n');
    const newLines = Array.from({ length: 600 }, (_, i) => `new ${i}`).join('\n');
    const r = await computeEditDiff('Edit', {
      file_path: '/tmp/x', old_string: oldLines, new_string: newLines,
    }, '/tmp');
    expect(r.truncated).toBe(true);
    expect(r.diff.split('\n').length).toBeLessThanOrEqual(400);
    expect(r.added).toBe(600);   // counted before the cap
    expect(r.removed).toBe(600);
    expect(r.diff.endsWith('\n')).toBe(false); // whole-line cut, no dangling newline
  });

  it('caps at 64 KB even under 400 lines', async () => {
    const bigLine = 'x'.repeat(2048);
    const oldStr = Array.from({ length: 50 }, () => bigLine).join('\n');
    const r = await computeEditDiff('Edit', {
      file_path: '/tmp/x', old_string: oldStr, new_string: 'tiny',
    }, '/tmp');
    expect(r.truncated).toBe(true);
    expect(Buffer.byteLength(r.diff, 'utf8')).toBeLessThanOrEqual(64 * 1024);
  });

  it('unknown tool / missing fields -> null', async () => {
    expect(await computeEditDiff('Bash', { command: 'ls' }, '/tmp')).toBeNull();
    expect(await computeEditDiff('Edit', { file_path: '/tmp/x' }, '/tmp')).toBeNull();
    expect(await computeEditDiff('Write', { file_path: '/tmp/x' }, '/tmp')).toBeNull();
    expect(await computeEditDiff('MultiEdit', { file_path: '/tmp/x', edits: [] }, '/tmp')).toBeNull();
  });
});
```

- [ ] **Step 3: Run to verify failure**

Run: `cd ~/Dev/claude-matrix-bridge && npx vitest run test/edit-diff.test.js`
Expected: FAIL — cannot resolve `../lib/edit-diff.js`.

- [ ] **Step 4: Implement `lib/edit-diff.js`**

```javascript
// Unified-diff snippets for Edit/Write/MultiEdit tool_use events, published
// as journal `diff` events (spec: matron-apple docs/superpowers/specs/
// 2026-07-14-diff-cards-design.md). The output is a display snippet of
// intent — hunk headers use positions within the tool-input strings, not
// file line numbers, and `replace_all` still diffs one occurrence.
import { structuredPatch } from 'diff';
import fs from 'node:fs/promises';
import path from 'node:path';

const MAX_LINES = 400;
const MAX_BYTES = 64 * 1024;

// Render structuredPatch hunks as unified-diff text WITHOUT ---/+++ file
// headers (the card header carries the filename), counting +/- lines
// before any truncation so the header counts stay honest.
function renderHunks(hunks) {
  const lines = [];
  let added = 0;
  let removed = 0;
  for (const h of hunks) {
    lines.push(`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@`);
    for (const l of h.lines) {
      lines.push(l);
      if (l.startsWith('+')) added += 1;
      else if (l.startsWith('-')) removed += 1;
    }
  }
  return { lines, added, removed };
}

function capText(lines) {
  const out = [];
  let bytes = 0;
  for (const line of lines) {
    const lineBytes = Buffer.byteLength(line, 'utf8') + 1; // + newline
    if (out.length >= MAX_LINES || bytes + lineBytes > MAX_BYTES) {
      return { text: out.join('\n'), truncated: true };
    }
    out.push(line);
    bytes += lineBytes;
  }
  return { text: out.join('\n'), truncated: false };
}

function fromHunks(hunks, newFile) {
  if (!hunks.length) return null; // no-op edit — nothing to show
  const { lines, added, removed } = renderHunks(hunks);
  const { text, truncated } = capText(lines);
  return { diff: text, added, removed, truncated, newFile };
}

function patchHunks(oldStr, newStr) {
  return structuredPatch('a', 'b', oldStr, newStr, '', '', { context: 3 }).hunks;
}

// Returns {diff, added, removed, truncated, newFile} or null when the tool
// input has no usable content (unknown tool, missing fields, no-op edit).
// Never throws — callers fire-and-forget from the Matrix hot path.
export async function computeEditDiff(toolName, input, workdir) {
  try {
    if (!input || typeof input !== 'object') return null;
    if (toolName === 'Edit'
        && typeof input.old_string === 'string' && typeof input.new_string === 'string') {
      return fromHunks(patchHunks(input.old_string, input.new_string), false);
    }
    if (toolName === 'MultiEdit' && Array.isArray(input.edits)) {
      const hunks = [];
      for (const e of input.edits) {
        if (typeof e?.old_string !== 'string' || typeof e?.new_string !== 'string') continue;
        hunks.push(...patchHunks(e.old_string, e.new_string));
      }
      return fromHunks(hunks, false);
    }
    if (toolName === 'Write' && typeof input.content === 'string' && input.file_path) {
      const abs = path.isAbsolute(input.file_path)
        ? input.file_path
        : path.join(workdir || '', input.file_path);
      let old = null;
      try {
        old = await fs.readFile(abs, 'utf8');
      } catch {
        old = null; // absent or unreadable -> treat as new file (fail open)
      }
      return fromHunks(patchHunks(old ?? '', input.content), old === null);
    }
    return null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `npx vitest run test/edit-diff.test.js`
Expected: PASS, 9 tests. If the truncation tests disagree with jsdiff's exact hunk shapes, adjust EXPECTATIONS only where the assertion encodes jsdiff internals (e.g. exact hunk count), never the caps/counts contract.

- [ ] **Step 6: Commit**

```bash
git add lib/edit-diff.js test/edit-diff.test.js package.json package-lock.json
git commit -m "feat(diff): computeEditDiff — unified diff snippets for Edit/Write/MultiEdit"
```

---

### Task 2: Bridge — `publishDiff` on the journal publisher

**Files:**
- Modify: `~/Dev/claude-matrix-bridge/lib/journal-publisher.js` (real method next to `publishText` ~line 497; noop stub next to `publishText() {}` ~line 62)
- Modify: `~/Dev/claude-matrix-bridge/test/journal-publisher.test.js`

**Interfaces:**
- Consumes: existing `safePublish(convoId, type, payload)` internal.
- Produces: `publisher.publishDiff(convoId, payload)` — durable, queued, idem-keyed like every other publish method.

- [ ] **Step 1: Write the failing test** — extend the existing `covers publishPrompt and publishToolOutput with the right types` test (same file, same fake-server pattern) by adding after the `publishToolOutput` call:

```javascript
    pub.publishDiff('convo-2', {
      file_path: '/w/a.swift', display_path: 'a.swift', viewer_url: null,
      tool: 'Edit', label: null, diff: '@@ -1,1 +1,1 @@\n-a\n+b',
      added: 1, removed: 1, truncated: false, new_file: false,
    });
```

and to its assertions (mirroring the neighbouring `toMatchObject` checks):

```javascript
    const diffFrame = fake.received.find(f => f.op === 'publish' && f.type === 'diff');
    expect(diffFrame).toMatchObject({
      convo_id: 'convo-2', type: 'diff',
      payload: { tool: 'Edit', added: 1, removed: 1, new_file: false },
    });
    expect(typeof diffFrame.idem_key).toBe('string');
```

Also add `pub.publishDiff('c1', { diff: 'x' });` inside the existing `disabled mode` test's method sweep.

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run test/journal-publisher.test.js`
Expected: FAIL — `pub.publishDiff is not a function`.

- [ ] **Step 3: Implement** — in the noop-stub block add `publishDiff() {},` after `publishText() {},`; in the real publisher add after `publishText`:

```javascript
    publishDiff(convoId, payload) {
      safePublish(convoId, 'diff', payload);
    },
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run test/journal-publisher.test.js`
Expected: PASS (all existing tests + amended ones).

- [ ] **Step 5: Commit**

```bash
git add lib/journal-publisher.js test/journal-publisher.test.js
git commit -m "feat(journal): publishDiff — durable diff events on the publisher"
```

---

### Task 3: Bridge — wire tool_use paths, kill the Matrix indicator

**Files:**
- Modify: `~/Dev/claude-matrix-bridge/index.js`:
  - import block (top, next to the `tool-stream-pump` import ~line 15)
  - new `publishEditDiff` helper (place directly after `journalActivity`, ~line 505)
  - main-agent `Write`/`Edit` branches (~lines 2228–2253)
  - subagent tool_use loop (~line 1945) + `formatSubagentToolIndicator` (~line 1862)

**Interfaces:**
- Consumes: `computeEditDiff` (Task 1), `publisher.publishDiff` via `journalPublish(session, 'publishDiff', payload)` (Task 2 + existing buffering helper), existing `generateFileLink(absPath)`.
- Produces: journal `diff` events with the spec payload; NO Matrix message for Edit/Write/MultiEdit from either agent path.

- [ ] **Step 1: Add import** (with the other lib imports):

```javascript
import { computeEditDiff } from './lib/edit-diff.js';
```

- [ ] **Step 2: Add the helper** after `journalActivity`:

```javascript
// Compute and publish a structured `diff` journal event for an
// Edit/Write/MultiEdit tool_use — the journal-only replacement for the old
// "✏️ Editing [path](link)" Matrix indicator (Dan, 2026-07-14; spec in
// matron-apple docs/superpowers/specs/2026-07-14-diff-cards-design.md).
// `label` is the subagent label, null for the parent agent. Published at
// tool_use time, same semantics as the old message (a denied edit still
// shows its card). Fire-and-forget async (Write reads the file); every
// failure path is swallowed — journal problems never touch the Matrix
// hot path.
function publishEditDiff(session, toolName, input, label) {
  if (!JOURNAL_ENABLED || !input?.file_path) return;
  const absPath = path.isAbsolute(input.file_path)
    ? input.file_path
    : path.join(session.workdir, input.file_path);
  computeEditDiff(toolName, input, session.workdir).then(result => {
    if (!result) return;
    journalPublish(session, 'publishDiff', {
      file_path: absPath,
      display_path: input.file_path,
      viewer_url: generateFileLink(absPath),
      tool: toolName,
      label: label || null,
      diff: result.diff,
      added: result.added,
      removed: result.removed,
      truncated: result.truncated,
      new_file: result.newFile,
    });
  }).catch(e => {
    debug('publishEditDiff failed: %s', e?.message);
  });
}
```

- [ ] **Step 3: Replace the main-agent branches.** Delete BOTH existing `toolName === 'Write'` and `toolName === 'Edit'` else-if blocks (the ones calling `generateFileLink` and setting `isKeyEvent = true`) and put in their place ONE branch:

```javascript
          } else if ((toolName === 'Write' || toolName === 'Edit' || toolName === 'MultiEdit')
                     && input.file_path) {
            // Journal-only (Dan, 2026-07-14): a structured `diff` event
            // replaces the old "✏️ Editing [path](link)" room message —
            // isKeyEvent stays false, so nothing posts to Matrix and
            // nothing mirrors into the journal as text. session.toolCalls
            // below still gets this plain line for the turn summary.
            const verb = toolName === 'Write' ? 'Writing' : 'Editing';
            indicator = `✏️ ${verb} ${input.file_path}`;
            publishEditDiff(session, toolName, input, null);
          } else if ((toolName === 'Glob' || toolName === 'Grep') && input.pattern) {
```

(The trailing line shows the join point — the Glob/Grep branch already exists; don't duplicate it.)

- [ ] **Step 4: Subagent path.** In the `for (const block of content)` loop in `handleSubagentEvent`'s message handler (~line 1945), insert BEFORE the `formatSubagentToolIndicator` call:

```javascript
      if ((block.name === 'Edit' || block.name === 'Write' || block.name === 'MultiEdit')
          && block.input?.file_path) {
        // Rich diff card instead of the "🔀[label] ✏️ Editing …" line —
        // journal-only, same contract as the parent-agent path.
        publishEditDiff(session, block.name, block.input, label);
        session.lastActivityAt = Date.now();
        continue;
      }
      const formatted = formatSubagentToolIndicator(label, block.name, block.input || {});
```

Then delete the now-unreachable `Edit/Write/MultiEdit` branch at the top of `formatSubagentToolIndicator` (the `verb`/`✏️` block).

- [ ] **Step 5: Full bridge suite**

Run: `npm test 2>&1 | tail -20`
Expected: same 5 pre-existing failures (interactive-session, pre-trust), ZERO new ones. `edit-diff` and `journal-publisher` suites green.

- [ ] **Step 6: Commit + PR**

```bash
git add index.js
git commit -m "feat(diff): publish journal diff events for file edits; retire the Matrix indicator"
git push -u origin feat/diff-cards
gh pr create --title "Rich diff events for file edits (journal-only)" --body "..."
```

PR body: summary of the three commits, spec pointer, note that the apps PR renders these. Do NOT merge or restart the bridge yet — that's Dan's call at the end.

---

### Task 4: Apps — `DiffEvent` model

**Files:**
- Create: `MatronShared/Sources/Events/DiffEvent.swift`
- Create: `MatronShared/Tests/EventsTests/DiffEventTests.swift`

**Interfaces:**
- Produces: `DiffEvent` (Equatable, Sendable) with `filePath/displayPath: String?`, `viewerURL: URL?`, `tool/label: String?`, `diff: String`, `added/removed: Int?`, `truncated/newFile: Bool`; `static func parse(payload: [String: Any]) -> DiffEvent` (total — never nil); `var filename: String?`.

- [ ] **Step 1: Branch check** — matron-apple checkout should be on `feat/diff-cards` (created off `feat/tool-stream-overlay` when the spec was committed). `git branch --show-current` to confirm.

- [ ] **Step 2: Write the failing tests**

`MatronShared/Tests/EventsTests/DiffEventTests.swift`:

```swift
import XCTest
@testable import MatronEvents

final class DiffEventTests: XCTestCase {
    func testParseRichPayload() {
        let evt = DiffEvent.parse(payload: [
            "file_path": "/Users/dan/Dev/x/Sources/A.swift",
            "display_path": "Sources/A.swift",
            "viewer_url": "https://viewer.example/view?token=abc",
            "tool": "Edit",
            "label": "code-reviewer",
            "diff": "@@ -1,1 +1,1 @@\n-a\n+b",
            "added": 1, "removed": 1,
            "truncated": true, "new_file": false,
        ])
        XCTAssertEqual(evt.filePath, "/Users/dan/Dev/x/Sources/A.swift")
        XCTAssertEqual(evt.displayPath, "Sources/A.swift")
        XCTAssertEqual(evt.viewerURL?.host, "viewer.example")
        XCTAssertEqual(evt.tool, "Edit")
        XCTAssertEqual(evt.label, "code-reviewer")
        XCTAssertEqual(evt.diff, "@@ -1,1 +1,1 @@\n-a\n+b")
        XCTAssertEqual(evt.added, 1)
        XCTAssertEqual(evt.removed, 1)
        XCTAssertTrue(evt.truncated)
        XCTAssertFalse(evt.newFile)
        XCTAssertEqual(evt.filename, "A.swift")
    }

    func testParseBareLegacyShape() {
        // Pre-spec payloads carried only a diff string (or `snippet`).
        let evt = DiffEvent.parse(payload: ["diff": "+added line"])
        XCTAssertEqual(evt.diff, "+added line")
        XCTAssertNil(evt.filePath)
        XCTAssertNil(evt.viewerURL)
        XCTAssertNil(evt.added)
        XCTAssertFalse(evt.truncated)
        XCTAssertNil(evt.filename)
    }

    func testParseSnippetFallbackAndEmpty() {
        XCTAssertEqual(DiffEvent.parse(payload: ["snippet": "+x"]).diff, "+x")
        // Total parse: an empty payload yields an empty diff, never nil —
        // the card renders header-only.
        XCTAssertEqual(DiffEvent.parse(payload: [:]).diff, "")
    }

    func testFilenameFallsBackToFilePath() {
        let evt = DiffEvent.parse(payload: ["diff": "x", "file_path": "/a/b/c.txt"])
        XCTAssertEqual(evt.filename, "c.txt")
    }

    func testNonStringViewerURLIgnored() {
        let evt = DiffEvent.parse(payload: ["diff": "x", "viewer_url": 42])
        XCTAssertNil(evt.viewerURL)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd ~/Dev/matron-apple/MatronShared && swift test --filter DiffEventTests 2>&1 | tail -5`
Expected: compile FAILURE — `DiffEvent` unresolved.

- [ ] **Step 4: Implement `DiffEvent.swift`**

```swift
import Foundation

/// Decoded form of a journal `diff` event payload (spec:
/// docs/superpowers/specs/2026-07-14-diff-cards-design.md §2) — a file-edit
/// snippet the bridge publishes at tool_use time, replacing the old
/// "✏️ Editing …" text message. Renders as a `DiffCard`. The pre-spec bare
/// shape (`{diff: "…"}` or `{snippet: "…"}` alone) parses into the same
/// type with nil metadata so there is exactly one render path.
public struct DiffEvent: Equatable, Sendable {
    public let filePath: String?
    public let displayPath: String?
    public let viewerURL: URL?
    public let tool: String?
    /// Subagent label; nil for parent-agent edits.
    public let label: String?
    public let diff: String
    public let added: Int?
    public let removed: Int?
    public let truncated: Bool
    public let newFile: Bool

    public init(filePath: String? = nil, displayPath: String? = nil,
                viewerURL: URL? = nil, tool: String? = nil, label: String? = nil,
                diff: String, added: Int? = nil, removed: Int? = nil,
                truncated: Bool = false, newFile: Bool = false) {
        self.filePath = filePath
        self.displayPath = displayPath
        self.viewerURL = viewerURL
        self.tool = tool
        self.label = label
        self.diff = diff
        self.added = added
        self.removed = removed
        self.truncated = truncated
        self.newFile = newFile
    }

    /// Total parse — every field is optional metadata around the diff text,
    /// and a payload with neither `diff` nor `snippet` yields an empty
    /// string (the card renders header-only). No nil return: the mapper
    /// has already routed on the event TYPE, so there is nothing better to
    /// fall back to.
    public static func parse(payload: [String: Any]) -> DiffEvent {
        DiffEvent(
            filePath: payload["file_path"] as? String,
            displayPath: payload["display_path"] as? String,
            viewerURL: (payload["viewer_url"] as? String).flatMap(URL.init(string:)),
            tool: payload["tool"] as? String,
            label: payload["label"] as? String,
            diff: payload["diff"] as? String ?? payload["snippet"] as? String ?? "",
            added: (payload["added"] as? NSNumber)?.intValue,
            removed: (payload["removed"] as? NSNumber)?.intValue,
            truncated: payload["truncated"] as? Bool ?? false,
            newFile: payload["new_file"] as? Bool ?? false
        )
    }

    /// Header filename: last component of the display path (falling back to
    /// the absolute path); nil when the payload carried no path at all.
    public var filename: String? {
        (displayPath ?? filePath).map { ($0 as NSString).lastPathComponent }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter DiffEventTests 2>&1 | tail -3`
Expected: "Executed 5 tests, with 0 failures".

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Events/DiffEvent.swift MatronShared/Tests/EventsTests/DiffEventTests.swift
git commit -m "feat(events): DiffEvent — journal diff payload model"
```

---

### Task 5: Apps — `.diff` timeline kind + mapper

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift` (Kind enum)
- Modify: `MatronShared/Sources/Chat/TimelineItem+PrettyJSON.swift`
- Modify: `MatronShared/Sources/Chat/JournalTimelineMapper.swift` (`JournalEventType.diff` branch, currently builds a "diff" ToolCallEvent)
- Modify: `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`

**Interfaces:**
- Consumes: `DiffEvent.parse(payload:)` (Task 4).
- Produces: `TimelineItem.Kind.diff(eventID: String, DiffEvent)` — rendered by Task 7.

- [ ] **Step 1: Write the failing tests** (append to `JournalTimelineMapperTests`; use the file's existing `JournalEvent` construction helper/pattern — match how neighbouring tests build events with `type: "diff"`):

```swift
    func testDiffEventMapsToRichDiffKind() throws {
        let event = JournalEvent(
            seq: 42, convoID: "c1", type: "diff", sender: "agent:bridge",
            ts: Date(timeIntervalSince1970: 1_700_000_000),
            payload: [
                "file_path": "/w/Sources/A.swift",
                "display_path": "Sources/A.swift",
                "viewer_url": "https://v.example/view?token=t",
                "tool": "Edit", "label": nil as String? as Any,
                "diff": "@@ -1,1 +1,1 @@\n-a\n+b",
                "added": 1, "removed": 1,
                "truncated": false, "new_file": false,
            ])
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event, ownSender: "user:dan", serverURL: URL(string: "https://j.example")!))
        guard case .diff(let eventID, let evt) = item.kind else {
            return XCTFail("expected .diff, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "42")
        XCTAssertEqual(evt.filename, "A.swift")
        XCTAssertEqual(evt.added, 1)
        XCTAssertFalse(item.isOwn)
    }

    func testBareDiffPayloadStillRenders() throws {
        let event = JournalEvent(
            seq: 43, convoID: "c1", type: "diff", sender: "agent:bridge",
            ts: Date(), payload: ["diff": "+only"])
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event, ownSender: "user:dan", serverURL: URL(string: "https://j.example")!))
        guard case .diff(_, let evt) = item.kind else {
            return XCTFail("expected .diff, got \(item.kind)")
        }
        XCTAssertEqual(evt.diff, "+only")
        XCTAssertNil(evt.filename)
    }
```

(If `JournalEvent`'s memberwise init differs, copy the construction style of the nearest existing mapper test verbatim.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter JournalTimelineMapperTests 2>&1 | tail -5`
Expected: compile FAILURE — `Kind` has no member `diff`.

- [ ] **Step 3: Implement.** `TimelineItem.Kind` — add after `case toolCall`:

```swift
        /// Journal `diff` event — a file-edit snippet the bridge publishes
        /// when the agent edits/writes a file (replaces the old
        /// "✏️ Editing …" text message). Renders as a `DiffCard` with the
        /// filename header linking to the signed viewer URL.
        case diff(eventID: String, DiffEvent)
```

`TimelineItem+PrettyJSON.swift` — add after the `.toolCall` case:

```swift
        case .diff(let eventID, let evt):
            return [
                "type": "diff",
                "eventID": eventID,
                "file": (evt.displayPath ?? evt.filePath).map { $0 as Any } ?? NSNull(),
                "tool": evt.tool ?? NSNull(),
                "label": evt.label ?? NSNull(),
                "added": evt.added.map { NSNumber(value: $0) } ?? NSNull(),
                "removed": evt.removed.map { NSNumber(value: $0) } ?? NSNull(),
                "truncated": evt.truncated,
                "newFile": evt.newFile,
                "diff": evt.diff,
            ]
```

`JournalTimelineMapper.swift` — replace the whole `case JournalEventType.diff:` branch body with:

```swift
        case JournalEventType.diff:
            kind = .diff(eventID: String(event.seq), DiffEvent.parse(payload: payload))
```

- [ ] **Step 4: Fix the exhaustiveness fallout.** Building will surface every `switch item.kind` that must now handle `.diff` — at minimum the two platform item views. For THIS task give them a temporary placeholder so the package compiles (real rendering is Task 7):

In `Matron/Features/Chat/Rendering/TimelineItemView.swift` and `MatronMac/Features/Chat/MacTimelineItemView.swift`, after the `.toolCall` case:

```swift
        case .diff:
            EmptyView() // Task 7 renders DiffCard here
```

(App targets are built in Task 7; `swift test` only compiles MatronShared, whose switches are in PrettyJSON/mapper — already handled.)

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter JournalTimelineMapperTests 2>&1 | tail -3` then the touched suites:
`swift test --filter "DiffEventTests|JournalTimelineMapperTests|JournalTimelineServiceTests" 2>&1 | tail -3`
Expected: "Executed N tests, with 0 failures" — N must match the sum of those suites.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Chat/TimelineItem.swift MatronShared/Sources/Chat/TimelineItem+PrettyJSON.swift MatronShared/Sources/Chat/JournalTimelineMapper.swift MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift Matron/Features/Chat/Rendering/TimelineItemView.swift MatronMac/Features/Chat/MacTimelineItemView.swift
git commit -m "feat(chat): .diff timeline kind mapped from journal diff events"
```

---

### Task 6: Apps — `DiffCard` (DesignSystem) + snapshots

**Files:**
- Create: `MatronShared/Sources/DesignSystem/DiffCard.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift`

**Interfaces:**
- Consumes: `DiffEvent` (Task 4), `Color.matronCodeBg` (existing), `assertVariants` snapshot helper (existing in DesignSystemSnapshotTests).
- Produces: `public struct DiffCard: View`, `init(event: DiffEvent, expanded: Bool = false)`.

- [ ] **Step 1: Write the snapshot tests**

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
import MatronEvents

final class DiffCardSnapshotTests: XCTestCase {
    private func sampleEvent(
        diff: String = "@@ -10,3 +10,4 @@\n context line\n-let b = 2\n+let b = 99\n+let b2 = 100\n context line",
        label: String? = nil, truncated: Bool = false, newFile: Bool = false,
        viewer: String? = "https://v.example/view?token=t"
    ) -> DiffEvent {
        DiffEvent(filePath: "/w/Sources/A.swift", displayPath: "Sources/A.swift",
                  viewerURL: viewer.flatMap(URL.init(string:)), tool: "Edit",
                  label: label, diff: diff, added: 2, removed: 1,
                  truncated: truncated, newFile: newFile)
    }

    func test_collapsed_smallDiff() {
        assertVariants(of: DiffCard(event: sampleEvent()).frame(width: 420),
                       named: "collapsed_small")
    }

    func test_collapsed_longDiff_showsMoreLinesRow() {
        let long = (0..<30).map { "+added line \($0)" }.joined(separator: "\n")
        assertVariants(of: DiffCard(event: sampleEvent(diff: long)).frame(width: 420),
                       named: "collapsed_more_lines")
    }

    func test_expanded_truncated_showsTruncationRow() {
        let long = (0..<20).map { "+added line \($0)" }.joined(separator: "\n")
        assertVariants(of: DiffCard(event: sampleEvent(diff: long, truncated: true),
                                    expanded: true).frame(width: 420),
                       named: "expanded_truncated")
    }

    func test_newFile_badge() {
        assertVariants(of: DiffCard(event: sampleEvent(newFile: true)).frame(width: 420),
                       named: "new_file")
    }

    func test_subagentLabel_inHeader() {
        assertVariants(of: DiffCard(event: sampleEvent(label: "code-reviewer")).frame(width: 420),
                       named: "subagent_label")
    }

    func test_noViewerURL_plainFilename() {
        assertVariants(of: DiffCard(event: sampleEvent(viewer: nil)).frame(width: 420),
                       named: "no_viewer_url")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DiffCardSnapshotTests 2>&1 | tail -5`
Expected: compile FAILURE — `DiffCard` unresolved.

- [ ] **Step 3: Implement `DiffCard.swift`**

```swift
import SwiftUI
import MatronEvents

/// Card for a journal `diff` event — a file-edit snippet with the filename
/// in the header (tappable link to the bridge's signed viewer URL when one
/// was supplied) and prefix-colored unified-diff lines in the body.
/// Collapsed shows the first `collapsedLineCount` lines with a "+N more
/// lines" row; the chevron expands to the full diff (the bridge caps it at
/// 400 lines, so no client-side windowing is needed).
public struct DiffCard: View {
    let event: DiffEvent
    @State private var expanded: Bool

    static let collapsedLineCount = 12

    /// `expanded` defaults to false for the production tap-toggle; snapshot
    /// tests pass true to render the expanded state directly (same pattern
    /// as `ToolCallCard`).
    public init(event: DiffEvent, expanded: Bool = false) {
        self.event = event
        self._expanded = State(initialValue: expanded)
    }

    private var allLines: [Substring] {
        event.diff.isEmpty ? [] : event.diff.split(separator: "\n", omittingEmptySubsequences: false)
    }

    public var body: some View {
        let lines = allLines
        let visible = expanded ? lines : Array(lines.prefix(Self.collapsedLineCount))
        let hidden = lines.count - visible.count

        VStack(alignment: .leading, spacing: 8) {
            header
            if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(rendered(visible))
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                }
                .background(Color.matronDiffInnerBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if hidden > 0 {
                Button { expanded = true } label: {
                    Text("+\(hidden) more line\(hidden == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if expanded && event.truncated {
                Text("… diff truncated")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.matronCodeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: event.newFile ? "doc.badge.plus" : "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            filenameView

            if let label = event.label {
                Text(label).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
            }
            if event.newFile {
                Text("new file")
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
            counts
            Spacer(minLength: 0)
        }
    }

    /// Filename links to the signed viewer URL when the bridge supplied
    /// one; plain text otherwise (viewer unconfigured). Separate hit
    /// target from the expand chevron. Falls back to the tool name when
    /// the payload carried no path (legacy bare shape).
    @ViewBuilder
    private var filenameView: some View {
        let name = event.filename ?? event.tool ?? "diff"
        if let url = event.viewerURL {
            Link(destination: url) {
                Text(name)
                    .font(.system(.callout, design: .monospaced)).bold()
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(name)
                .font(.system(.callout, design: .monospaced)).bold()
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 4) {
            if let added = event.added {
                Text("+\(added)").font(.caption2).bold().foregroundStyle(.green)
            }
            if let removed = event.removed {
                Text("−\(removed)").font(.caption2).bold().foregroundStyle(.red)
            }
        }
    }

    /// One AttributedString for the whole visible block — a per-line Text
    /// stack at 400 lines is exactly the kind of view-count blowup the
    /// blank-chat saga taught us to avoid.
    private func rendered(_ lines: [Substring]) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            var run = AttributedString(String(line))
            if line.hasPrefix("+") {
                run.foregroundColor = .green
            } else if line.hasPrefix("-") {
                run.foregroundColor = .red
            } else if line.hasPrefix("@@") {
                run.foregroundColor = .secondary
            }
            out += run
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    private var accessibilitySummary: String {
        let verb = event.tool == "Write" ? (event.newFile ? "Created" : "Wrote") : "Edited"
        let name = event.filename ?? "file"
        var parts = ["\(verb) \(name)"]
        if let a = event.added { parts.append("\(a) addition\(a == 1 ? "" : "s")") }
        if let r = event.removed { parts.append("\(r) removal\(r == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

private extension Color {
    /// Inner diff-block background — same cross-platform split as
    /// ToolCallCard's `matronCardInnerBg` (which is fileprivate there).
    #if canImport(UIKit) && !os(macOS)
    static let matronDiffInnerBg = Color(.systemBackground)
    #elseif os(macOS)
    static let matronDiffInnerBg = Color(nsColor: .textBackgroundColor)
    #endif
}
```

- [ ] **Step 4: Record + verify snapshots.** First run records baselines (test "fails" while recording); second run must pass:

Run: `swift test --filter DiffCardSnapshotTests 2>&1 | tail -3` (twice)
Expected second run: "Executed 6 tests, with 0 failures".
Then OPEN the recorded PNGs under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/DiffCardSnapshotTests/` with the Read tool and visually verify: green/red coloring, header layout, badge, "+N more lines" row. Colors resolving wrong against dark/light variants is exactly what snapshots exist to catch.

- [ ] **Step 5: Commit (baselines included)**

```bash
git add MatronShared/Sources/DesignSystem/DiffCard.swift MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift "MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/DiffCardSnapshotTests/"
git commit -m "feat(design): DiffCard — prefix-colored diff snippet with viewer-linked filename"
```

---

### Task 7: Apps — render on both platforms, full suite, PRs, install

**Files:**
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift` (replace Task 5 placeholder)
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift` (replace Task 5 placeholder)

**Interfaces:**
- Consumes: `DiffCard(event:)` (Task 6), `Self.accessibilityLabel(for:body:)` (existing on both views).

- [ ] **Step 1: iOS case** — replace the `case .diff: EmptyView()` placeholder in `TimelineItemView.swift` with:

```swift
        case .diff(_, let evt):
            // File-edit diff snippet — bot-aligned, same width cap as the
            // tool cards (Dan, 2026-07-14). DiffCard hugs its content, so
            // a three-line fix stays small.
            HStack {
                DiffCard(event: evt)
                    .frame(maxWidth: 480, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(
                for: item, body: "Edited \(evt.filename ?? "file")"))
```

- [ ] **Step 2: Mac case** — same replacement in `MacTimelineItemView.swift` with `maxWidth: 560`.

- [ ] **Step 3: Full SPM suite**

Run: `cd ~/Dev/matron-apple/MatronShared && swift test 2>&1 | grep -E "Executed .* tests" | tail -5`
Expected: all suites green; total test count = previous total (460) + 13 new (5 DiffEvent + 2 mapper + 6 snapshots) = 473, 0 failures. If untracked `__Snapshots__/AskUserCardSnapshotTests/` strays reappear and fail once by auto-recording, `rm -rf` them and re-run (known artifact of running snapshot suites off #19's lineage).

- [ ] **Step 4: Build both app targets**

```bash
cd ~/Dev/matron-apple && xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS' build 2>&1 | tail -3
xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice.

- [ ] **Step 5: Commit + PR (apps)**

```bash
git add Matron/Features/Chat/Rendering/TimelineItemView.swift MatronMac/Features/Chat/MacTimelineItemView.swift
git commit -m "feat(chat): render DiffCard for journal diff events on iOS and Mac"
git push -u origin feat/diff-cards
gh pr create --base feat/tool-stream-overlay --title "Rich diff cards for file edits" --body "..."
```

- [ ] **Step 6: Live-test build + install.** Refresh the throwaway integration branch and install on both devices per the standing routine:

```bash
git branch -D tmp/live-testing
git checkout -b tmp/live-testing feat/ask-user-instant-buttons
git merge --no-edit feat/diff-cards
# build Debug-iphoneos Matron.app + Debug MatronMac.app from live DerivedData
# (Matron-djxcczdoznrqzzazpztxtbtjtynv), then:
# iPhone: xcrun devicectl device install app --device CA47988A-6782-5DDA-9A5B-A89549ECA908 <Matron.app>
# Mac:    rm -rf /Applications/MatronMac.app && ditto <MatronMac.app> /Applications/MatronMac.app && touch /Applications/MatronMac.app
```
Verify installs by binary mtime/shasum, not Finder dates.

- [ ] **Step 7: Report to Dan.** Both PRs linked (bridge + apps), install confirmation, and the live test: the bridge PR must be merged + bridge restarted before diff cards appear — ask for the merge word, then restart via the detached `nohup bash -c 'sleep 10; ./restart.sh'` pattern so the reply lands first.

---

## Self-review notes

- Spec coverage: §1→Task 1, §2→Tasks 2–3, §3→Task 3, §4→Tasks 4–5, §5→Task 6, §6→Tasks 5 (placeholder) + 7 (real) + tests throughout. Mac hover hint from spec §5 deliberately simplified to a plain Link (underlined filename) — Link provides its own pointer affordance; noted as a conscious deviation, revisit if Dan wants the ToolCallCard hover hint too.
- Type consistency: `computeEditDiff` return keys (`diff/added/removed/truncated/newFile`) match `publishEditDiff`'s payload mapping (`new_file: result.newFile`); `DiffEvent.parse` keys match the payload; `DiffCard(event:expanded:)` matches snapshot tests.
- Known soft spots called out inline: jsdiff hunk-shape assertions (Task 1 Step 5), `JournalEvent` init shape (Task 5 Step 1) — both with explicit fallback instructions.
