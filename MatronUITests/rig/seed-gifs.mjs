// Animated GIF rig: one chat and one tracker item, each holding an
// animated GIF, for checking that animations play in the timeline, the
// item thread and the fullscreen viewer.
//
// Run after seed.mjs: cd /tmp/matron-demo && node seed-gifs.mjs
import fs from 'node:fs';
import WebSocket from 'ws';

const BASE = 'http://127.0.0.1:9810';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const CONVO = 'demo-gifs';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// A GIF drawn here, so the rig carries no picture files (as seed-photos.mjs).
// `pixel(frame, x, y)` returns a palette index; the palette has 256 entries.
// The image data is "uncompressed" LZW: a clear code before the code size
// would grow, so every code is 9 bits wide.
function gif(width, height, frames, delayCs, palette, pixel) {
  const out = [];
  const u16 = (n) => [n & 0xff, (n >> 8) & 0xff];
  out.push(...Buffer.from('GIF89a'), ...u16(width), ...u16(height), 0xf7, 0, 0);
  for (let i = 0; i < 256; i++) out.push(...(palette[i] ?? [0, 0, 0]));
  // Loop forever (NETSCAPE2.0 application extension).
  out.push(0x21, 0xff, 0x0b, ...Buffer.from('NETSCAPE2.0'), 0x03, 0x01, 0, 0, 0);
  for (let f = 0; f < frames; f++) {
    out.push(0x21, 0xf9, 0x04, 0x04, ...u16(delayCs), 0, 0);
    out.push(0x2c, 0, 0, 0, 0, ...u16(width), ...u16(height), 0);
    out.push(8);
    const bytes = [];
    let acc = 0, bits = 0, sinceClear = 0;
    const emit = (code) => {
      acc |= code << bits; bits += 9;
      while (bits >= 8) { bytes.push(acc & 0xff); acc >>= 8; bits -= 8; }
    };
    emit(256);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        if (sinceClear === 254) { emit(256); sinceClear = 0; }
        emit(pixel(f, x, y)); sinceClear++;
      }
    }
    emit(257);
    if (bits > 0) bytes.push(acc & 0xff);
    for (let i = 0; i < bytes.length; i += 255) {
      const block = bytes.slice(i, i + 255);
      out.push(block.length, ...block);
    }
    out.push(0);
  }
  out.push(0x3b);
  return Buffer.from(out);
}

// A dot travelling round a ring, on a soft background: plainly moving when
// it plays, plainly still when it doesn't.
function spinner() {
  const size = 200, frames = 16;
  const palette = [[236, 240, 245], [90, 110, 140], [235, 95, 60], [200, 210, 222]];
  return gif(size, size, frames, 6, palette, (f, x, y) => {
    const cx = size / 2, cy = size / 2;
    const angle = (f / frames) * Math.PI * 2;
    const dx = cx + Math.cos(angle) * 60, dy = cy + Math.sin(angle) * 60;
    if ((x - dx) ** 2 + (y - dy) ** 2 < 18 ** 2) return 2;
    const r = Math.hypot(x - cx, y - cy);
    if (Math.abs(r - 60) < 3) return 3;
    if (r < 10) return 1;
    return 0;
  });
}

// Bars that rise and fall in turn, wider than tall.
function bars() {
  const width = 320, height = 180, frames = 12, count = 6;
  const palette = [[24, 28, 36], [80, 170, 120], [70, 140, 220]];
  return gif(width, height, frames, 8, palette, (f, x, y) => {
    const bar = Math.floor(x / (width / count));
    const inBar = x % (width / count) > 8;
    const phase = (f / frames) * Math.PI * 2 + bar * 0.9;
    const top = height - (40 + (Math.sin(phase) + 1) * 55);
    if (inBar && y > top) return bar % 2 ? 1 : 2;
    return 0;
  });
}

async function call(token, path, body) {
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': Buffer.isBuffer(body) ? 'image/gif' : 'application/json' },
    body: Buffer.isBuffer(body) ? body : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

async function upload(name, bytes) {
  const blob = await call(macToken, '/media', bytes);
  return { blob_ref: blob.media_id, mime: 'image/gif', name, size: bytes.length };
}

const ws = new WebSocket('ws://127.0.0.1:9810/ws');
await new Promise((resolve, reject) => {
  ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token: macToken, cursor: null })));
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.op === 'hello_ok') resolve();
    else if (msg.op === 'error') console.error('error:', msg);
  });
  ws.on('error', reject);
});

let n = 0;
async function frame(obj) {
  ws.send(JSON.stringify(obj));
  n++;
  await sleep(150);
}

await frame({ op: 'convo_upsert', convo_id: CONVO, title: 'Loading spinner options', session_state: 'done' });
await frame({ op: 'publish', convo_id: CONVO, type: 'text', payload: { body: 'Two loading animations for the upload screen.' }, idem_key: `gifs-${n}` });
for (const [name, bytes] of [['spinner.gif', spinner()], ['bars.gif', bars()]]) {
  const attachment = await upload(name, bytes);
  await frame({ op: 'publish', convo_id: CONVO, type: 'image', payload: attachment, idem_key: `gifs-${n}` });
}
await frame({ op: 'publish', convo_id: CONVO, type: 'text', payload: { body: 'The spinner reads better on a small screen. I filed the choice in the tracker.' }, idem_key: `gifs-${n}` });

await call(macToken, '/items', {
  kind: 'question', convo_id: CONVO, title: 'Which loading animation for uploads?',
  body: 'Both loop until the upload finishes.',
  actions: ['Spinner', 'Bars'],
  attachments: [await upload('spinner.gif', spinner()), await upload('bars.gif', bars())],
});

await sleep(500);
ws.close();
console.log(`seeded two GIFs in ${CONVO} and one item`);
