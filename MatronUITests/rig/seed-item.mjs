// Item thread rig: one long tracker item on the demo journal, for driving
// the native item thread in the real app. The body and comments carry what
// a long thread has: paragraphs, lists (nested and numbered), a table wide
// enough to scroll sideways, a code block, links, pictures, a reply from
// the user and a comment with buttons.
//
// Run after seed.mjs: cd /tmp/matron-demo && node seed-item.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';

const BASE = 'http://127.0.0.1:9810';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync('/tmp/matron-demo/login-client.json', 'utf8'));
const CONVO = 'demo-fix-flaky-upload';

async function call(token, path, body, headers = {}) {
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' || body instanceof Uint8Array ? body : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return JSON.parse(text);
}

// A PNG drawn here, so the rig carries no picture files: diagonal bands
// in two colours, large enough that the thread must scale it down.
function png(width, height, [r, g, b]) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const head = Buffer.alloc(4); head.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const tail = Buffer.alloc(4); tail.writeUInt32BE(crc(body));
    return Buffer.concat([head, body, tail]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2;
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const at = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const band = Math.floor((x + y) / 60) % 2 === 0 ? 1 : 0.8;
      rows[at + 1 + x * 3] = r * band; rows[at + 2 + x * 3] = g * band; rows[at + 3 + x * 3] = b * band;
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(rows)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

async function picture(name, colour) {
  const bytes = png(1600, 900, colour);
  const blob = await call(macToken, '/media', bytes, { 'content-type': 'image/png' });
  return { blob_ref: blob.media_id, mime: 'image/png', name, size: bytes.length };
}

const body = `**The ask:** uploads fail about one time in forty on a slow connection, and the retry queue was written before resumable uploads existed. This compares three ways to replace it.

**What a replacement has to do**

- Resume a part-sent upload instead of starting again.
- Survive the app being closed mid-upload.
  - On a phone that means a background session.
  - On a desktop it means a queue on disk.
- Report progress the interface can show.

**The three options**

| Option | Resumes | Survives a restart | Work | Risk |
| :--- | :---: | :---: | ---: | :--- |
| Patch the current queue | No | Yes | 2 days | Keeps the one-in-forty failure on slow links |
| Chunked uploads with a manifest | Yes | Yes | 6 days | New server endpoint, needs a migration for queued items |
| Hand uploads to the system session | Yes | Yes | 4 days | Progress is coarse, [limits apply](https://example.com/limits) |

**How I would do it**

1. Add the manifest endpoint behind a flag.
2. Move new uploads to chunks.
3. Migrate what is already queued.
4. Remove the old queue once a week passes with no fallback.

The retry rule today:

\`\`\`swift
func nextDelay(after attempt: Int) -> Duration {
    .seconds(min(60, 1 << attempt))
}
\`\`\`

**My recommendation:** chunked uploads with a manifest. It is the only option that removes the failure and not only hides it.`;

const item = (await call(macToken, '/items', {
  kind: 'question', convo_id: CONVO, title: 'Pick a replacement for the upload retry queue',
  body, actions: ['Chunked uploads', 'System session', 'Patch the queue'],
  attachments: [await picture('failures-by-connection.png', [70, 130, 200])],
})).item;

const comment = (token, fields, key) =>
  call(token, `/items/${item.id}/comments`, { convo_id: CONVO, ...fields }, { 'idempotency-key': key });

for (let i = 1; i <= 12; i++) {
  const fields = { body: `**Measurement ${i}.** Sent the 40 MB sample over the throttled link ${i * 5} times.

- Failures with today's queue: ${i}.
- Failures with chunks: 0.

| Run | Link | Sent | Failed | Median |
| :--- | :--- | ---: | ---: | ---: |
| ${i}a | 3G | ${i * 5} | ${i} | ${40 + i} s |
| ${i}b | Slow Wi-Fi | ${i * 5} | 0 | ${20 + i} s |

The second run is the one that matters: the failure only shows when the link drops for more than the retry delay.` };
  if (i % 4 === 0) fields.attachments = [await picture(`run-${i}.png`, [200, 120 + i * 5, 70])];
  await comment(macToken, fields, `seed-item-${i}`);
  if (i === 6) await comment(client.token, { body: 'Does the manifest need a schema change on the server?' }, 'seed-item-user');
}
await comment(macToken, {
  body: 'No schema change: the manifest is a row in the existing uploads table. Shall I start on the endpoint?',
  actions: ['Start', 'Wait'], awaiting: 'user',
}, 'seed-item-ask');
console.log(`item #${item.num} ${item.id}`);
