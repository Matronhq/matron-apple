// Launch timing rig: what happens on the journal while the app is away.
// Comments on RIG_TOUCHED of the open items, RIG_COMMENTS each (defaults 15
// and 4: sixty markers for fifteen items), then files one new question for
// the user, last, titled with the label given, and prints the time it was
// filed.
//
// Run: RIG_DIR=... RIG_PORT=9820 node launch-backlog.mjs <label>
import fs from 'node:fs';

const DIR = process.env.RIG_DIR ?? '/tmp/matron-launch-rig';
const PORT = Number(process.env.RIG_PORT ?? 9820);
const TOUCHED = Number(process.env.RIG_TOUCHED ?? 15);
const COMMENTS = Number(process.env.RIG_COMMENTS ?? 4);
const label = process.argv[2] ?? 'run';
const token = fs.readFileSync(`${DIR}/agent-box-a.txt`, 'utf8').split('token:')[1].trim().split(/\s/)[0];
const open = JSON.parse(fs.readFileSync(`${DIR}/open-items.json`, 'utf8'));

async function call(path, body) {
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return JSON.parse(text);
}

for (let round = 0; round < COMMENTS; round++) {
  for (const id of open.slice(0, TOUCHED)) {
    await call(`/items/${id}/comments`, { body: `Progress note ${round + 1} (${label}).` });
  }
}
await call('/items', { kind: 'question', convo_id: 'rig-upload', title: `Fresh question ${label}`, body: 'Go ahead?', actions: ['Go'] });
console.log(`backlog ${label}: ${TOUCHED * COMMENTS} comments, 1 new question`);
