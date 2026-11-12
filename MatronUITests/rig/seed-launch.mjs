// Launch timing rig: a journal the size of a well-used one. Five
// conversations, RIG_CLOSED closed items (default 5000) and RIG_OPEN items
// that need the user (default 40), with bodies of a few paragraphs.
//
// Run: RIG_DIR=/tmp/matron-launch-rig RIG_PORT=9820 node seed-launch.mjs
import WebSocket from 'ws';
import fs from 'node:fs';

const DIR = process.env.RIG_DIR ?? '/tmp/matron-launch-rig';
const PORT = Number(process.env.RIG_PORT ?? 9820);
const CLOSED = Number(process.env.RIG_CLOSED ?? 5000);
const OPEN = Number(process.env.RIG_OPEN ?? 40);
const BASE = `http://127.0.0.1:${PORT}`;
const token = fs.readFileSync(`${DIR}/agent-box-a.txt`, 'utf8').split('token:')[1].trim().split(/\s/)[0];
const CONVOS = ['rig-upload', 'rig-auth', 'rig-dark-mode', 'rig-release', 'rig-memory'];

const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
await new Promise((resolve, reject) => {
  ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
  ws.on('message', (data) => { if (JSON.parse(data.toString()).op === 'hello_ok') resolve(); });
  ws.on('error', reject);
});
for (const [i, id] of CONVOS.entries()) {
  ws.send(JSON.stringify({ op: 'convo_upsert', convo_id: id, title: `Rig conversation ${i + 1}`, session_state: 'running' }));
  ws.send(JSON.stringify({ op: 'publish', convo_id: id, type: 'text', payload: { body: 'Working on it.' }, idem_key: `seed-${id}` }));
}
await new Promise((r) => setTimeout(r, 500));
ws.close();

async function call(path, body) {
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return JSON.parse(text);
}

const paragraph = 'I looked into this today. It fails about one run in five, and only when the link drops for longer than the retry delay. Option A keeps the design and adds a longer timeout; option B replaces it with resumable chunks.';
const body = (i) => Array.from({ length: 4 + (i % 8) }, () => paragraph).join('\n\n');

async function pool(count, width, work) {
  let next = 0;
  await Promise.all(Array.from({ length: width }, async () => {
    while (next < count) { const i = next++; await work(i); }
  }));
}

await pool(CLOSED, 8, async (i) => {
  const kind = i % 3 === 0 ? 'decision' : 'question';
  const { item } = await call('/items', { kind, convo_id: CONVOS[i % CONVOS.length], title: `Settled matter ${i + 1}`, body: body(i) });
  await call(`/items/${item.id}/close`, { resolution: kind === 'decision' ? 'decided' : 'answered' });
});
const open = [];
await pool(OPEN, 4, async (i) => {
  const { item } = await call('/items', {
    kind: 'question', convo_id: CONVOS[i % CONVOS.length], title: `Decide on matter ${i + 1}`, body: body(i),
    actions: ['Option A', 'Option B'],
  });
  open.push(item.id);
});
fs.writeFileSync(`${DIR}/open-items.json`, JSON.stringify(open));
console.log(`seeded ${CLOSED} closed and ${OPEN} open items`);
