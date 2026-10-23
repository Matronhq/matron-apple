// Coordinator rig — seeds a Coordinator conversation and a link to it
// from "Fix the flaky upload test", for CoordinatorBackUITests. The
// Coordinator setting itself is written by rebuild-rig.sh (RIG_COORDINATOR=1).
//
// Run: cd /tmp/matron-demo && node seed-coordinator.mjs
import WebSocket from 'ws';
import fs from 'node:fs';

const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const ws = await new Promise((resolve, reject) => {
  const w = new WebSocket('ws://127.0.0.1:9810/ws');
  w.on('open', () => w.send(JSON.stringify({ op: 'hello', token: macToken, cursor: null })));
  w.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.op === 'hello_ok') resolve(w);
    else if (msg.op === 'error') console.error('error:', msg);
  });
  w.on('error', reject);
});

let n = 0;
async function frame(obj) {
  ws.send(JSON.stringify(obj));
  n++;
  await sleep(150);
}
const pub = (convo_id, body) => frame({ op: 'publish', convo_id, type: 'text', payload: { body }, idem_key: `coord-${convo_id}-${n}` });

await frame({ op: 'convo_upsert', convo_id: 'demo-coordinator', title: 'Coordinator', session_state: 'running' });
await pub('demo-coordinator', 'Morning. Two PRs are green and waiting on you; the nightly build passed.');
await pub('demo-fix-flaky-upload', 'I asked the [Coordinator](matron://convo/demo-coordinator) to schedule the merge.');
await sleep(500);
ws.close();
console.log('seeded coordinator');
