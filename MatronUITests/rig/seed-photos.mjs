// Image viewer rig: one chat holding four pictures, for driving the
// fullscreen viewer's swipe between them.
//
// Run after seed.mjs: cd /tmp/matron-demo && node seed-photos.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';
import WebSocket from 'ws';

const BASE = 'http://127.0.0.1:9810';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const CONVO = 'demo-photos';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// A PNG drawn here, so the rig carries no picture files (as seed-item.mjs).
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

await frame({ op: 'convo_upsert', convo_id: CONVO, title: 'Photo swipe check', session_state: 'done' });
await frame({ op: 'publish', convo_id: CONVO, type: 'text', payload: { body: 'Four screenshots from the upload run.' }, idem_key: `photos-${n}` });
const colours = [[200, 60, 60], [60, 160, 60], [60, 90, 200], [200, 170, 40]];
for (const [i, colour] of colours.entries()) {
  const bytes = png(1200, 900, colour);
  const res = await fetch(BASE + '/media', {
    method: 'POST',
    headers: { authorization: `Bearer ${macToken}`, 'content-type': 'image/png' },
    body: bytes,
  });
  if (!res.ok) throw new Error(`/media: ${res.status} ${await res.text()}`);
  const blob = await res.json();
  await frame({
    op: 'publish', convo_id: CONVO, type: 'image',
    payload: { blob_ref: blob.media_id, mime: 'image/png', name: `upload-${i + 1}.png`, size: bytes.length },
    idem_key: `photos-${n}`,
  });
}
await sleep(500);
ws.close();
console.log(`seeded ${colours.length} pictures in ${CONVO}`);
