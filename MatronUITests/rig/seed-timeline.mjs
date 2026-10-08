// Timeline rig — seeds `perf-timeline` ("Timeline perf rig"): 220 long
// markdown messages (links, lists, code, tables, quotes), own messages at
// 060 and 180, a conversation link at 215 and an item link at 216. It is
// the spec §1 workload for the UIKit timeline's UI tests and perf gate.
// Markers PERF-001…PERF-220 let tests find rows.
//
// Run by rebuild-rig.sh when RIG_TIMELINE=1 (after seed.mjs). Needs the
// same ./node_modules providing 'ws' as seed.mjs.
import WebSocket from 'ws';
import fs from 'node:fs';

const URL_WS = 'ws://127.0.0.1:9810/ws';
const CONVO = 'perf-timeline';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync('/tmp/matron-demo/login-client.json', 'utf8'));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL_WS);
    ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.op === 'hello_ok') resolve(ws);
      else if (msg.op === 'error') console.error('error:', msg);
    });
    ws.on('error', reject);
  });
}

const mac = await connect(macToken);
const app = await connect(client.token);
let n = 0;
async function frame(ws, obj) {
  ws.send(JSON.stringify(obj));
  n++;
  await sleep(60); // local server: receipt order == append order across sockets
}

function body(i) {
  const item = (i % 40) + 1;
  let s = `PERF-${String(i).padStart(3, '0')} **Step ${i}** — reviewing [the upload queue](https://example.com/upload/${i}) and [#${item}](matron://item/${item}).\n\n`;
  s += `- first point about retries and backoff for request ${i}\n`;
  s += '- second point with `inline code` and a [doc link](https://developer.apple.com/documentation/uikit)\n';
  s += '- third point that wraps across several lines on a phone because it keeps going with more detail than fits\n\n';
  if (i % 5 === 0) s += '```swift\nlet queue = UploadQueue(maxRetries: 3)\nqueue.start()\n```\n\n';
  if (i % 5 === 1) s += '| Case | Result |\n|:--|--:|\n| retry | ok |\n| timeout | **failed** |\n\n';
  if (i % 5 === 2) s += '> A quoted note that spans a couple of lines to exercise the quote styling in the timeline.\n\n';
  s += `Closing paragraph for message ${i} with one more [link](https://example.com/${i}).`;
  return s;
}

await frame(mac, { op: 'convo_upsert', convo_id: CONVO, title: 'Timeline perf rig', session_state: 'done' });
for (let i = 1; i <= 220; i++) {
  const marker = `PERF-${String(i).padStart(3, '0')}`;
  if (i === 60 || i === 180) {
    await frame(app, { op: 'send', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} (own) Can you check the retry numbers on step ${i}?` },
                       local_id: `timeline-${i}` });
  } else if (i === 215) {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} Related work lives in [Dark mode](matron://convo/demo-dark-mode).` },
                       idem_key: `timeline-${i}` });
  } else if (i === 216) {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} Tracked as [#1](matron://item/1).` }, idem_key: `timeline-${i}` });
  } else {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text', payload: { body: body(i) },
                       idem_key: `timeline-${i}` });
  }
}
await frame(app, { op: 'read_marker', convo_id: CONVO, up_to_seq: null });
console.log(`seeded ${n} timeline frames`);
mac.close(); app.close();
