# Agent `send_attachment` MCP Tool Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give agents an MCP tool that sends an on-disk file (screenshot, PDF, plot, log) into their Matron chat as a real image/file attachment event.

**Architecture:** A new pure-logic module `lib/send-attachment.js` (content-type classification + an injectable HTTP-agnostic handler factory) is mounted as a `POST /send-attachment` route on the bridge's existing loopback API server (port 9802), and exposed to the agent as a `send_attachment` tool in the existing `ask-user.js` MCP server. The handler uploads the file with the journal publisher's existing agent-token `uploadMedia`, then publishes an `image` or `file` journal event — the same payload shape the user-media mirror already emits, which the journal server's agent publish whitelist and the apps' renderer both already accept (spec: `docs/superpowers/specs/2026-08-06-agent-to-agent-chat-design.md`).

**Tech Stack:** Node ESM, vitest, zod (MCP schema), existing `lib/journal-publisher.js` + `lib/file-link-guard.js`.

**Repo:** `Matronhq/matron-bridge` (`claude-matrix-bridge` remote name). Work from a **fresh worktree off `origin/master`** — `~/Dev/matron-bridge`'s working tree is parked on someone's WIP branch (`feat/sensitive-file-download`, uncommitted changes) and must not be branch-switched. `git -C ~/Dev/matron-bridge fetch origin && git -C ~/Dev/matron-bridge worktree add /tmp/send-attachment-wt origin/master -b feat/agent-send-attachment && ln -s ~/Dev/matron-bridge/node_modules /tmp/send-attachment-wt/node_modules`.

## Global Constraints

- `npm run ci` = `eslint . --max-warnings=0` + `node --check` list + `vitest run` + `npm audit --audit-level=high` — all must pass.
- Every new entry-point file must be added to the `check` script's `node --check` chain in `package.json`.
- No new npm dependencies.
- Journal publisher contract: publisher methods fail open (never throw). `uploadMedia` returns `{media_id, content_type, size}` or `null` on any failure. `publishImage(convoId, payload)` / `publishFile(convoId, payload)` are durable/queued, return nothing.
- Attachment payload shape (must match `journalMirrorUserMedia`, `index.js:999-1015`, and the apps' mapper `JournalTimelineMapper.swift:68-86`): `{blob_ref, content_type, name, size, caption?}` — `caption` key omitted entirely when empty; no `from` key (that marks user-mirrored media).
- Size cap 50 MB (journal server's per-file `POST /media` cap) — reject client-side before upload.
- Path safety: reuse `checkFileLink(absPath, absWorkdir)` from `lib/file-link-guard.js` (returns `{ok}` or `{ok: false, reason: 'relative-path'|'sensitive'|'outside-workdir'}`). Sensitive files (keys, .env, etc.) must be refused — agents must use `share_sensitive_data` for those.
- Phase 1 sends only to the calling session's own conversation. No `room_id` parameter yet (shared rooms are Phase 3; write tightening is Phase 2).

---

### Task 1: `classifyContentType` helper

**Files:**
- Create: `lib/send-attachment.js`
- Test: `test/send-attachment.test.js`
- Modify: `package.json` (add `node --check lib/send-attachment.js` to the `check` script chain)

**Interfaces:**
- Produces: `classifyContentType(fileName: string) -> {contentType: string, isImage: boolean}` (named export). Extension-based, case-insensitive; unknown → `application/octet-stream`.

- [ ] **Step 1: Write the failing test**

```js
// test/send-attachment.test.js
import { describe, it, expect } from 'vitest';
import { classifyContentType } from '../lib/send-attachment.js';

describe('classifyContentType', () => {
  it('classifies common image extensions as images', () => {
    expect(classifyContentType('shot.png')).toEqual({ contentType: 'image/png', isImage: true });
    expect(classifyContentType('IMG_001.JPG')).toEqual({ contentType: 'image/jpeg', isImage: true });
    expect(classifyContentType('anim.gif')).toEqual({ contentType: 'image/gif', isImage: true });
    expect(classifyContentType('pic.webp')).toEqual({ contentType: 'image/webp', isImage: true });
    expect(classifyContentType('photo.heic')).toEqual({ contentType: 'image/heic', isImage: true });
  });

  it('classifies documents and text as non-image files', () => {
    expect(classifyContentType('report.pdf')).toEqual({ contentType: 'application/pdf', isImage: false });
    expect(classifyContentType('build.log')).toEqual({ contentType: 'text/plain', isImage: false });
    expect(classifyContentType('notes.txt')).toEqual({ contentType: 'text/plain', isImage: false });
    expect(classifyContentType('README.md')).toEqual({ contentType: 'text/markdown', isImage: false });
    expect(classifyContentType('data.json')).toEqual({ contentType: 'application/json', isImage: false });
    expect(classifyContentType('data.csv')).toEqual({ contentType: 'text/csv', isImage: false });
  });

  it('falls back to octet-stream for unknown or missing extensions', () => {
    expect(classifyContentType('mystery.bin')).toEqual({ contentType: 'application/octet-stream', isImage: false });
    expect(classifyContentType('Makefile')).toEqual({ contentType: 'application/octet-stream', isImage: false });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/send-attachment-wt && npx vitest run test/send-attachment.test.js`
Expected: FAIL — `Cannot find module '../lib/send-attachment.js'`

- [ ] **Step 3: Write minimal implementation**

```js
// lib/send-attachment.js
import path from 'path';

// Agent-outbound attachment support for the send_attachment MCP tool.
// classifyContentType is extension-based: the agent is sending a file it
// just produced (screenshot, plot, PDF), so the extension is trustworthy
// enough and avoids a content-sniffing dependency.

const EXT_CONTENT_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.svg': 'image/svg+xml',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.log': 'text/plain',
  '.md': 'text/markdown',
  '.json': 'application/json',
  '.csv': 'text/csv',
  '.html': 'text/html',
  '.zip': 'application/zip',
};

export function classifyContentType(fileName) {
  const ext = path.extname(String(fileName)).toLowerCase();
  const contentType = EXT_CONTENT_TYPES[ext] || 'application/octet-stream';
  return { contentType, isImage: contentType.startsWith('image/') };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/send-attachment.test.js`
Expected: PASS (3 tests)

- [ ] **Step 5: Add the file to the `node --check` chain**

In `package.json`, in the `check` script, append `&& node --check lib/send-attachment.js` at the end of the existing chain.

- [ ] **Step 6: Commit**

```bash
git add lib/send-attachment.js test/send-attachment.test.js package.json
git commit -m "feat: content-type classification for agent-sent attachments"
```

---

### Task 2: `createSendAttachmentHandler` factory

**Files:**
- Modify: `lib/send-attachment.js`
- Test: `test/send-attachment.test.js`

**Interfaces:**
- Consumes: `classifyContentType` (Task 1); `checkFileLink(absPath, absWorkdir)` from `lib/file-link-guard.js`; publisher methods `uploadMedia({filePath, contentType, name}) -> {media_id, content_type, size} | null`, `publishImage(convoId, payload)`, `publishFile(convoId, payload)`.
- Produces: `createSendAttachmentHandler({sessions, publisher, journalConvoIdFor, maxBytes?}) -> async (data) -> {status: number, body: object}`. `data` is the parsed POST body `{roomId, path, caption?}`. Success body: `{ok: true, kind: 'image'|'file', name, size}`. Error body: `{error: string}`. HTTP-agnostic so it is fully unit-testable; `index.js` mounts it as a thin adapter (Task 3).

- [ ] **Step 1: Write the failing tests**

Append to `test/send-attachment.test.js`:

```js
import { mkdtempSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';
import { createSendAttachmentHandler } from '../lib/send-attachment.js';

function makeFixture() {
  const workdir = mkdtempSync(path.join(tmpdir(), 'send-attach-'));
  writeFileSync(path.join(workdir, 'shot.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  writeFileSync(path.join(workdir, 'report.pdf'), 'pdf-bytes');
  const published = [];
  const uploads = [];
  const publisher = {
    uploadMedia: async ({ filePath, contentType, name }) => {
      uploads.push({ filePath, contentType, name });
      return { media_id: 'blob-123', content_type: contentType, size: 4 };
    },
    publishImage: (convoId, payload) => published.push({ kind: 'image', convoId, payload }),
    publishFile: (convoId, payload) => published.push({ kind: 'file', convoId, payload }),
  };
  const sessions = new Map([['!room1', { workdir }]]);
  const handler = createSendAttachmentHandler({
    sessions, publisher, journalConvoIdFor: () => 'convo-abc',
  });
  return { workdir, publisher, published, uploads, sessions, handler };
}

describe('createSendAttachmentHandler', () => {
  it('uploads and publishes an image event with caption', async () => {
    const { handler, published, workdir } = makeFixture();
    const res = await handler({ roomId: '!room1', path: 'shot.png', caption: 'the bug' });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, kind: 'image', name: 'shot.png', size: 4 });
    expect(published).toEqual([{
      kind: 'image',
      convoId: 'convo-abc',
      payload: { blob_ref: 'blob-123', content_type: 'image/png', name: 'shot.png', size: 4, caption: 'the bug' },
    }]);
    expect(published[0].payload.name).toBe('shot.png');
    void workdir;
  });

  it('publishes non-images as file events and omits empty caption', async () => {
    const { handler, published } = makeFixture();
    const res = await handler({ roomId: '!room1', path: 'report.pdf', caption: '' });
    expect(res.status).toBe(200);
    expect(published[0].kind).toBe('file');
    expect('caption' in published[0].payload).toBe(false);
  });

  it('resolves relative paths against the session workdir and passes filePath to uploadMedia', async () => {
    const { handler, workdir, uploads } = makeFixture();
    const res = await handler({ roomId: '!room1', path: 'report.pdf' });
    expect(res.status).toBe(200);
    expect(uploads).toEqual([{
      filePath: path.join(workdir, 'report.pdf'),
      contentType: 'application/pdf',
      name: 'report.pdf',
    }]);
  });

  it('rejects an unknown roomId', async () => {
    const { handler } = makeFixture();
    const res = await handler({ roomId: '!nope', path: 'shot.png' });
    expect(res.status).toBe(404);
    expect(res.body.error).toMatch(/no active session/i);
  });

  it('rejects when the journal conversation is not established', async () => {
    const { sessions, publisher } = makeFixture();
    const handler = createSendAttachmentHandler({ sessions, publisher, journalConvoIdFor: () => null });
    const res = await handler({ roomId: '!room1', path: 'shot.png' });
    expect(res.status).toBe(409);
    expect(res.body.error).toMatch(/journal conversation/i);
  });

  it('refuses sensitive paths with guidance to share_sensitive_data', async () => {
    const { handler, workdir } = makeFixture();
    writeFileSync(path.join(workdir, '.env'), 'SECRET=1');
    const res = await handler({ roomId: '!room1', path: '.env' });
    expect(res.status).toBe(403);
    expect(res.body.error).toMatch(/share_sensitive_data/);
  });

  it('refuses paths outside the session workdir', async () => {
    const { handler } = makeFixture();
    const res = await handler({ roomId: '!room1', path: '/etc/hosts' });
    expect(res.status).toBe(403);
    expect(res.body.error).toMatch(/outside/i);
  });

  it('rejects missing files', async () => {
    const { handler } = makeFixture();
    const res = await handler({ roomId: '!room1', path: 'no-such.png' });
    expect(res.status).toBe(404);
    expect(res.body.error).toMatch(/not found/i);
  });

  it('rejects files over the size cap', async () => {
    const { workdir, sessions, publisher } = makeFixture();
    writeFileSync(path.join(workdir, 'big.bin'), Buffer.alloc(32));
    const handler = createSendAttachmentHandler({
      sessions, publisher, journalConvoIdFor: () => 'convo-abc', maxBytes: 16,
    });
    const res = await handler({ roomId: '!room1', path: 'big.bin' });
    expect(res.status).toBe(413);
    expect(res.body.error).toMatch(/50 MB|too large/i);
  });

  it('surfaces upload failure when uploadMedia fails open with null', async () => {
    const { workdir, sessions } = makeFixture();
    const publisher = {
      uploadMedia: async () => null,
      publishImage: () => { throw new Error('must not publish'); },
      publishFile: () => { throw new Error('must not publish'); },
    };
    const handler = createSendAttachmentHandler({ sessions, publisher, journalConvoIdFor: () => 'convo-abc' });
    const res = await handler({ roomId: '!room1', path: 'shot.png' });
    expect(res.status).toBe(502);
    expect(res.body.error).toMatch(/upload failed/i);
    void workdir;
  });

  it('rejects missing params', async () => {
    const { handler } = makeFixture();
    expect((await handler({ path: 'x.png' })).status).toBe(400);
    expect((await handler({ roomId: '!room1' })).status).toBe(400);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run test/send-attachment.test.js`
Expected: FAIL — `createSendAttachmentHandler` is not exported.

- [ ] **Step 3: Implement the handler**

Append to `lib/send-attachment.js`:

```js
import { stat } from 'fs/promises';
import { checkFileLink } from './file-link-guard.js';

// Journal server's POST /media per-file cap. Enforced client-side so the
// agent gets a crisp error instead of a failed-open null from uploadMedia.
const MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;

const GUARD_ERRORS = {
  sensitive: 'Refused: that file looks sensitive (keys/credentials/env). Use share_sensitive_data instead.',
  'outside-workdir': 'Refused: path is outside the session workdir.',
  'relative-path': 'Refused: could not resolve the path to an absolute location.',
};

// HTTP-agnostic so it is fully unit-testable; index.js mounts it as a thin
// adapter on the loopback API server. Same shape as the other loopback
// routes: takes the parsed POST body, returns {status, body}.
export function createSendAttachmentHandler({ sessions, publisher, journalConvoIdFor, maxBytes = MAX_ATTACHMENT_BYTES }) {
  return async function handleSendAttachment(data) {
    const { roomId, path: reqPath, caption } = data || {};
    if (!roomId || !reqPath) return { status: 400, body: { error: 'roomId and path are required' } };

    const session = sessions.get(roomId);
    if (!session) return { status: 404, body: { error: `no active session for chat ${roomId}` } };

    const convoId = journalConvoIdFor(session);
    if (!convoId) return { status: 409, body: { error: 'journal conversation not established yet — try again shortly' } };

    const absWorkdir = session.workdir ? path.resolve(session.workdir) : null;
    const absTarget = path.isAbsolute(reqPath)
      ? path.resolve(reqPath)
      : (absWorkdir ? path.resolve(absWorkdir, reqPath) : null);
    if (!absTarget) return { status: 400, body: { error: 'relative path given but the session has no workdir' } };

    const gate = checkFileLink(absTarget, absWorkdir);
    if (!gate.ok) return { status: 403, body: { error: GUARD_ERRORS[gate.reason] || `Refused: ${gate.reason}` } };

    let info;
    try {
      info = await stat(absTarget);
    } catch {
      return { status: 404, body: { error: `file not found: ${absTarget}` } };
    }
    if (!info.isFile()) return { status: 400, body: { error: `not a regular file: ${absTarget}` } };
    if (info.size > maxBytes) {
      return { status: 413, body: { error: `file too large (${info.size} bytes; the journal caps attachments at 50 MB)` } };
    }

    const name = path.basename(absTarget);
    const { contentType, isImage } = classifyContentType(name);

    const media = await publisher.uploadMedia({ filePath: absTarget, contentType, name });
    if (!media) return { status: 502, body: { error: 'upload failed — journal unreachable or rejected the file' } };

    const payload = {
      blob_ref: media.media_id,
      content_type: media.content_type || contentType,
      name,
      size: media.size ?? info.size,
    };
    if (caption) payload.caption = caption;

    if (isImage) publisher.publishImage(convoId, payload);
    else publisher.publishFile(convoId, payload);

    return { status: 200, body: { ok: true, kind: isImage ? 'image' : 'file', name, size: payload.size } };
  };
}
```

(Note: `import path from 'path'` already exists from Task 1; merge the `fs/promises` and `file-link-guard` imports at the top of the file.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run test/send-attachment.test.js`
Expected: PASS (all Task 1 + Task 2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/send-attachment.js test/send-attachment.test.js
git commit -m "feat: send-attachment handler — guard, cap, upload, publish"
```

---

### Task 3: Mount the loopback route in `index.js`

**Files:**
- Modify: `index.js` (two places: imports; the loopback API server's POST-body dispatch, near the `/secret` route around `index.js:7110`)

**Interfaces:**
- Consumes: `createSendAttachmentHandler` (Task 2); existing `sessions` map (keyed by roomId), `journalPublisher`, `journalConvoIdFor(session)`.
- Produces: `POST http://127.0.0.1:9802/send-attachment` with JSON `{roomId, path, caption?}` → JSON `{ok, kind, name, size}` or `{error}` with matching HTTP status. This is the endpoint the MCP tool (Task 4) calls.

- [ ] **Step 1: Add the import**

Alongside the other `./lib/` imports at the top of `index.js`:

```js
import { createSendAttachmentHandler } from './lib/send-attachment.js';
```

- [ ] **Step 2: Instantiate the handler**

Immediately above the `const apiServer = createServer(...)` line (after `journalPublisher` and `sessions` both exist):

```js
const handleSendAttachment = createSendAttachmentHandler({
  sessions,
  publisher: journalPublisher,
  journalConvoIdFor,
});
```

- [ ] **Step 3: Add the route**

Inside the POST-body dispatch (the `req.on('end', ...)` handler where `url.pathname === '/secret'` is matched), add as a sibling branch:

```js
if (url.pathname === '/send-attachment') {
  const { status, body: resBody } = await handleSendAttachment(data);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(resBody));
  return;
}
```

- [ ] **Step 4: Syntax-check and run the full suite**

Run: `node --check index.js && npx vitest run`
Expected: check passes; full suite green (no existing test covers the monolith route dispatch — the handler logic itself is covered by Task 2).

- [ ] **Step 5: Commit**

```bash
git add index.js
git commit -m "feat: POST /send-attachment loopback route"
```

---

### Task 4: `send_attachment` MCP tool

**Files:**
- Modify: `ask-user.js` (add a fourth `server.tool(...)` block before the transport connect)

**Interfaces:**
- Consumes: `POST ${BRIDGE_API}/send-attachment` (Task 3); existing `BRIDGE_API` and `ROOM_ID` constants in `ask-user.js`.
- Produces: agent-visible tool `send_attachment(path, caption?)`.

- [ ] **Step 1: Add the tool**

```js
server.tool(
  'send_attachment',
  'Send a file from disk into the Matron chat as a real attachment: images (png/jpg/gif/webp/heic) render inline; PDFs, logs, and other files appear as tappable file attachments. Use this for screenshots, plots, generated documents, and build artifacts instead of describing them or pasting their contents. Do NOT use for secrets or credential files — use share_sensitive_data for those. Keep it purposeful: send the artifact the user needs, not every intermediate file.',
  {
    path: z.string().describe('Path to the file — absolute, or relative to the session working directory'),
    caption: z.string().optional().describe('Optional caption rendered with the attachment, like a message body'),
  },
  async ({ path, caption }) => {
    try {
      const postRes = await fetch(`${BRIDGE_API}/send-attachment`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ roomId: ROOM_ID, path, caption }),
      });
      const data = await postRes.json().catch(() => ({}));
      if (!postRes.ok) {
        return { content: [{ type: 'text', text: `send_attachment failed: ${data.error || `HTTP ${postRes.status}`}` }] };
      }
      return { content: [{ type: 'text', text: `Sent ${data.kind} "${data.name}" (${data.size} bytes) into the chat.` }] };
    } catch (err) {
      return { content: [{ type: 'text', text: `Error: ${err.message}` }] };
    }
  }
);
```

- [ ] **Step 2: Syntax-check**

Run: `node --check ask-user.js`
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git add ask-user.js
git commit -m "feat: send_attachment MCP tool"
```

---

### Task 5: Full CI, manual end-to-end, PR

**Files:** none new.

- [ ] **Step 1: Run the full CI gate**

Run: `cd /tmp/send-attachment-wt && npm run ci`
Expected: lint, check, vitest, audit all pass. Fix anything red before proceeding.

- [ ] **Step 2: Manual end-to-end verification (live box, Dan's session)**

After the PR merges and deploys (deploy is `deploy.sh` on the box — not part of this plan's worktree): in any Matron chat, ask the agent to run its `send_attachment` tool on a small PNG in its workdir and confirm (a) the image renders inline in the app with its caption, (b) a `.env` path is refused with the share_sensitive_data message, (c) a >50 MB file is refused with the size message. Record results in the PR.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/agent-send-attachment
gh pr create --repo Matronhq/claude-matrix-bridge \
  --title "Agent send_attachment MCP tool (agent-to-agent chat Phase 1)" \
  --body "Phase 1 of the agent-to-agent chat design (matron-apple docs/superpowers/specs/2026-08-06-agent-to-agent-chat-design.md): agents can send images/PDFs/files from disk into their Matron chat as real attachment events. New lib/send-attachment.js (classification + injectable handler, fully unit-tested), POST /send-attachment loopback route, send_attachment tool in ask-user.js. Reuses file-link-guard (sensitive-path + workdir containment) and the fail-open journal publisher; payload shape matches the existing user-media mirror so the apps render it with zero changes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: Clean up the worktree after merge**

```bash
git -C ~/Dev/matron-bridge worktree remove /tmp/send-attachment-wt
```
