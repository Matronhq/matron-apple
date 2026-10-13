// Seeds the e2e rig's journal with what the smoke tests navigate to:
// a chat, a project holding a mission, an item whose thread carries an
// image, and a queued message waiting on its "Send now" card.
// Run by rig.sh; needs E2E_STATE and E2E_BASE.
import WebSocket from 'ws';
import fs from 'node:fs';
import zlib from 'node:zlib';

const STATE = process.env.E2E_STATE;
const BASE = process.env.E2E_BASE;
const agentToken = fs.readFileSync(`${STATE}/agent.txt`, 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync(`${STATE}/login-client.json`, 'utf8'));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(BASE.replace('http', 'ws') + '/ws');
    ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.op === 'hello_ok') resolve(ws);
      else if (msg.op === 'error') console.error('seed: ws error', msg);
    });
    ws.on('error', reject);
  });
}

async function http(token, method, path, body, contentType = 'application/json') {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': contentType },
    body: body === undefined ? undefined : contentType === 'application/json' ? JSON.stringify(body) : body,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status} ${text}`);
  return JSON.parse(text);
}

// A 240x160 PNG in two bands, built by hand so the seed needs no image tools.
function png() {
  const w = 240, h = 160;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (w * 3 + 1) + 1 + x * 3;
      const top = y < h / 2;
      raw[o] = top ? 0xe8 : 0x2b; raw[o + 1] = top ? 0x5d : 0x6c; raw[o + 2] = top ? 0x3f : 0xd9;
    }
  }
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

const agent = await connect(agentToken);
const app = await connect(client.token);
let n = 0;
async function frame(ws, obj) { ws.send(JSON.stringify(obj)); n++; await sleep(150); }
const up = (convo_id, extra) => frame(agent, { op: 'convo_upsert', convo_id, ...extra });
const pub = (convo_id, type, payload) => frame(agent, { op: 'publish', convo_id, type, payload, idem_key: `e2e-${convo_id}-${n}` });
const send = (convo_id, text) => frame(app, { op: 'send', convo_id, type: 'text', payload: { body: text }, local_id: `e2e-${convo_id}-${n}` });

// A plain chat.
await up('e2e-chat', { title: 'E2E smoke chat', session_state: 'waiting' });
await send('e2e-chat', 'Is the smoke rig up?');
await pub('e2e-chat', 'text', { body: 'Yes, the smoke rig is up and seeded.' });

// A busy session holding one queued message behind its Send now card
// (the shape lib/busy-queue.js in matron-bridge publishes).
await up('e2e-queue', { title: 'E2E queued message', session_state: 'running' });
await pub('e2e-queue', 'text', { body: 'Working on the long task now.' });
await send('e2e-queue', 'Also check the release notes');
const promptId = 'pr_e2e_queue';
const actions = [{ id: 'send', label: '⚡ Send now', intent: 'primary' }, { id: 'cancel', label: '✕ Cancel', intent: 'neutral' }];
await pub('e2e-queue', 'prompt', {
  kind: 'queued_release', prompt_id: promptId,
  question: 'Send this queued message now, or cancel it?',
  items: [{ id: `${promptId}::0`, text: 'Also check the release notes' }],
  actions, options: actions.map(({ id, label }) => ({ id, label, value: id })),
  mode: 'pick_one', body: '📨 Queued (1): Also check the release notes',
});

// A project holding a mission, and an item on it whose thread has an image.
const { project } = await http(client.token, 'POST', '/projects', { title: 'E2E Project', body: 'Seeded by the e2e rig.' });
const { mission } = await http(agentToken, 'POST', '/missions', { title: 'E2E Mission', body: 'Smoke-test mission.', convo_id: 'e2e-chat', project: project.id });
await http(agentToken, 'POST', '/milestones', { kind: 'progress', title: 'Rig seeded', convo_id: 'e2e-chat', mission: mission.id });
const { item } = await http(agentToken, 'POST', '/items', { kind: 'question', title: 'E2E item with image', body: 'Does the screenshot below look right?', convo_id: 'e2e-chat' });
const media = await http(agentToken, 'POST', '/media', png(), 'image/png');
await http(agentToken, 'POST', `/items/${item.id}/comments`, {
  body: 'Here is the screenshot.',
  attachments: [{ blob_ref: media.media_id, mime: 'image/png', name: 'e2e-screenshot.png', size: media.size }],
});

agent.close(); app.close();
console.log(`seeded: project #${project.num}, mission #${mission.num}, item #${item.num}`);
