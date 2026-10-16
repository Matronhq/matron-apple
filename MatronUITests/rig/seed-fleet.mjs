// Fleet screenshot seed — projects, a mission with milestones, a For you
// question answered from two boxes, the Coordinator (and so its starter
// routines), a latest briefing and memories. Everything here is made up:
// the shots go on the public site.
//
// Run after seed.mjs: cd /tmp/matron-demo && node seed-fleet.mjs
// (rebuild-rig.sh does this when RIG_FLEET=1.)
import WebSocket from 'ws';
import fs from 'node:fs';

const BASE = 'http://127.0.0.1:9810';
const tokenOf = (f) => fs.readFileSync(`/tmp/matron-demo/${f}`, 'utf8').split('token:')[1].trim().split(/\s/)[0];
const macToken = tokenOf('agent-mac-studio.txt');
const homeToken = tokenOf('agent-homelab.txt');
const clientToken = JSON.parse(fs.readFileSync('/tmp/matron-demo/login-client.json', 'utf8')).token;

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let n = 0;

async function call(token, method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'idempotency-key': `fleet-${n++}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`);
  await sleep(60);
  return text ? JSON.parse(text) : {};
}
const mac = (m, p, b) => call(macToken, m, p, b);
const home = (m, p, b) => call(homeToken, m, p, b);
const user = (m, p, b) => call(clientToken, m, p, b);

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(BASE.replace('http', 'ws') + '/ws');
    ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
    ws.on('message', (d) => { const m = JSON.parse(d.toString()); if (m.op === 'hello_ok') resolve(ws); else if (m.op === 'error') console.error('ws error', m); });
    ws.on('error', reject);
  });
}
const macWs = await connect(macToken);
const homeWs = await connect(homeToken);
const appWs = await connect(clientToken);
const frame = async (ws, obj) => { ws.send(JSON.stringify(obj)); n++; await sleep(120); };
const up = (ws, convo_id, extra) => frame(ws, { op: 'convo_upsert', convo_id, ...extra });
const pub = (ws, convo_id, body) => frame(ws, { op: 'publish', convo_id, type: 'text', payload: { body }, idem_key: `fleet-${convo_id}-${n}` });
const send = (convo_id, body) => frame(appWs, { op: 'send', convo_id, type: 'text', payload: { body }, local_id: `fleet-${convo_id}-${n}` });
const read = (convo_id) => frame(appWs, { op: 'read_marker', convo_id, up_to_seq: null });

// ---- Conversations ----
await up(macWs, 'fleet-coordinator', { title: 'Coordinator', session_state: 'waiting' });
await up(macWs, 'fleet-checkout', { title: 'Ship the one-page checkout', session_state: 'waiting' });
await send('fleet-checkout', 'Collapse the four checkout steps into one page: address, delivery, payment. Keep the old flow behind a flag until it has been on staging for a day.');
await pub(macWs, 'fleet-checkout', 'Address form is done, with postcode lookup and inline validation. Unit and end-to-end tests pass. Ready to merge to staging when you are.');
await up(homeWs, 'fleet-checkout-load', { title: 'Load-test the checkout API', session_state: 'running' });
await pub(homeWs, 'fleet-checkout-load', 'Running 500 virtual users against staging checkout: p95 is 180 ms so far.');
await up(homeWs, 'fleet-ci-cache', { title: 'Cache test dependencies in CI', session_state: 'done' });
await pub(homeWs, 'fleet-ci-cache', 'Dependency cache is live. Median CI run went from 14 to 6 minutes.');
await up(macWs, 'fleet-docs', { title: 'Rewrite the getting-started guide', session_state: 'running' });
await pub(macWs, 'fleet-docs', 'Draft of the new quick start is in docs/start.md; working on the screenshots.');
for (const c of ['fleet-checkout', 'fleet-checkout-load', 'fleet-ci-cache', 'fleet-docs']) await read(c);

// ---- Coordinator (seeds the starter routines) ----
await user('PUT', '/coordinator', { convo_id: 'fleet-coordinator' });

// ---- Projects and missions ----
const proj = async (title, body) => (await user('POST', '/projects', { title, body })).project;
const pCheckout = await proj('New checkout', 'One-page checkout, live for every customer.');
const pCI = await proj('Faster CI', 'Every pull request green in under ten minutes.');
const pDocs = await proj('Docs refresh', 'A new user can go from sign-up to first deploy with the docs alone.');

const mission = async (who, convo_id, project, title, name, body) =>
  (await who('POST', '/missions', { convo_id, project: project.id, title, name, body })).mission;
const mCheckout = await mission(mac, 'fleet-checkout', pCheckout, 'Ship the one-page checkout', 'One-page checkout',
  'Replace the four-step checkout with a single page. Done when it is live on production behind no flag.');
await mission(home, 'fleet-checkout-load', pCheckout, 'Load-test the new checkout API', 'Checkout load test', 'Hold p95 under 300 ms at 500 users.');
await mission(home, 'fleet-ci-cache', pCI, 'Cache test dependencies in CI', 'CI dependency cache', 'Cut the median CI run in half.');
await mission(mac, 'fleet-docs', pDocs, 'Rewrite the getting-started guide', 'Getting-started guide', 'A five-minute quick start with screenshots.');

const ms = (who, convo_id, kind, title, body) => who('POST', '/milestones', { convo_id, kind, title, body });
await ms(mac, 'fleet-checkout', 'user_input', 'Collapse checkout into one page, old flow behind a flag', 'Keep the old flow until the new one has had a day on staging.');
await ms(mac, 'fleet-checkout', 'progress', 'Plan agreed: address, delivery and payment on one page', 'Three sections, one submit, saved progress if the tab closes.');
await ms(mac, 'fleet-checkout', 'progress', 'Delivery options load in parallel with the address form', 'Shaved 400 ms off time to interactive.');
await ms(mac, 'fleet-checkout', 'progress', 'Address form done: postcode lookup and inline validation', 'Unit and end-to-end tests pass.');
await mac('PATCH', `/missions/${mCheckout.id}`, { convo_id: 'fleet-checkout', status: 'Address form is finished and tested. Waiting on the merge to staging, then payment is next. homelab is load-testing the API in parallel.' });
await home('POST', '/milestones', { convo_id: 'fleet-ci-cache', kind: 'progress', title: 'Dependency cache live: median CI run 14 → 6 minutes' });
await home('PATCH', `/missions/${(await home('GET', '/conversations/fleet-ci-cache/missions')).missions?.[0]?.id ?? ''}`, { convo_id: 'fleet-ci-cache', status: 'Cache is live on every branch. Next: split the slowest test shard.' }).catch((e) => console.error('ci status', e.message));

// ---- For you: a question answered from two boxes ----
const q = (await mac('POST', '/items', {
  convo_id: 'fleet-checkout', kind: 'question', title: 'Address form is ready: merge it to staging?',
  body: 'Postcode lookup and inline validation are in, and the tests are green. Merging puts it on staging behind the `one_page_checkout` flag. I recommend merging now so homelab can load-test it tonight.',
  actions: ['Merge', 'Hold for now'],
})).item;
await home('POST', `/items/${q.id}/comments`, { as_convo_id: 'fleet-checkout-load', body: 'Staging API holds p95 at 180 ms with 500 users, so it has room for the new form.' });
await mac('POST', `/items/${q.id}/comments`, { as_convo_id: 'fleet-checkout', body: 'Pull request is open with screenshots of the form on iPhone and desktop. One tap and I merge.' });

// ---- Coordinator chat: the user's question, the round (published as the
// latest briefing, so it is also the Projects card) and an approval ----
await send('fleet-coordinator', 'What happened overnight?');
await mac('POST', '/briefings', {
  convo_id: 'fleet-coordinator',
  body: [
    '**Morning round: 3 projects moving, 1 decision waiting for you.**',
    '',
    '**New checkout**: the address form is ready to merge to staging. Your call on [Address form is ready: merge it to staging?](matron://item/' + q.num + ').',
    '',
    '**Docs refresh**: on track; the quick-start draft is in.',
    '',
    '**Faster CI**: the session stalled on a usage limit, so I moved it to another model and it carried on.',
  ].join('\n'),
});
await pub(macWs, 'fleet-coordinator', 'Approved a spawn on homelab for the Docs refresh mission: it follows your box rules.');
await read('fleet-coordinator');

// ---- Memories ----
const mem = (name, description, body, type = 'feedback', scope) => user('PUT', `/memories/${name}`, { description, body, type, ...(scope ? { scope } : {}) });
await mem('tests-before-merge', 'Run the full test suite before asking to merge. Never merge on a red build.', '**Why:** a red main blocks everyone.\n\n**How to apply:** paste the test summary in the merge question.');
await mem('staging-before-prod', 'Everything goes to staging first and sits there for a day before production.', '**Why:** staging catches what tests miss.');
await mem('screenshots-in-prs', 'Every pull request that changes the UI includes screenshots.', '**Why:** reviews go faster when you can see the change.');
await mem('quiet-hours-deploys', 'Deploy in the evening, when traffic is low. Never on a Friday.', '');
await mem('homelab-runs-load-tests', 'Load tests and long benchmarks run on homelab, not mac-studio.', '**Why:** homelab is idle most of the day.', 'project');
await mem('small-pull-requests', 'Keep pull requests under 400 lines; split bigger changes.', '');

console.log(`fleet seeded (${n} calls/frames)`);
macWs.close(); homeWs.close(); appWs.close();
