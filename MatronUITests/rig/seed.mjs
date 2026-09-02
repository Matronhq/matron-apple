// Marketing screenshot rig — seeds the local demo journal (127.0.0.1:9810)
// with the conversations the MarketingScreenshots XCUITests navigate by
// title. Rebuild of the July rig, extended with an agent-chat pairing
// request (server-minted consent card via a real agent_invite).
//
// Run: cd /tmp/matron-demo && node seed.mjs
// (needs ./node_modules providing 'ws' — see rig/README.md; NODE_PATH does
// not work here, the ESM resolver ignores it.)
import WebSocket from 'ws';
import fs from 'node:fs';

const URL_WS = 'ws://127.0.0.1:9810/ws';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const homeToken = fs.readFileSync('/tmp/matron-demo/agent-homelab.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync('/tmp/matron-demo/login-client.json', 'utf8'));

// The invite's target device id, resolved by rebuild-rig.sh from the demo
// DB — hardcoding the autoincrement value silently breaks the pairing-card
// capture the moment device creation order changes.
// Validated as a positive-integer STRING, not via Number(): Number('')
// is 0 and Number.isInteger(0) holds, so an empty variable (the sqlite
// lookup returning no row) would sail through and aim the invite at
// device 0 — the exact silent "consent card never rendered" failure this
// guard exists to catch early.
const rawHomelabDeviceID = process.env.HOMELAB_DEVICE_ID ?? '';
if (!/^[1-9][0-9]*$/.test(rawHomelabDeviceID)) {
  throw new Error(`HOMELAB_DEVICE_ID must be a positive integer device id, got ${JSON.stringify(rawHomelabDeviceID)} (rebuild-rig.sh resolves it from the demo DB)`);
}
const HOMELAB_DEVICE_ID = Number(rawHomelabDeviceID);

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function connect(token, label) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL_WS);
    ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.op === 'hello_ok') resolve(ws);
      else if (msg.op === 'error') console.error(`[${label}] error:`, msg);
    });
    ws.on('error', reject);
  });
}

const mac = await connect(macToken, 'mac-studio');
const home = await connect(homeToken, 'homelab');
const app = await connect(client.token, 'client');

let n = 0;
async function frame(ws, obj) {
  ws.send(JSON.stringify(obj));
  n++;
  await sleep(120); // local server: receipt order == append order across sockets
}

const up = (ws, convo_id, extra) => frame(ws, { op: 'convo_upsert', convo_id, ...extra });
const pub = (ws, convo_id, type, payload) => frame(ws, { op: 'publish', convo_id, type, payload, idem_key: `seed-${convo_id}-${n}` });
const send = (convo_id, text) => frame(app, { op: 'send', convo_id, type: 'text', payload: { body: text }, local_id: `seed-${convo_id}-${n}` });
const read = (convo_id) => frame(app, { op: 'read_marker', convo_id, up_to_seq: null });

// ---- E. filler: memory spike (oldest, left unread) ----
await up(mac, 'demo-memory-spike', { title: 'Investigate the API memory spike', session_state: 'done' });
await send('demo-memory-spike', 'Grafana shows api-server RSS climbing about 40MB an hour since the Tuesday deploy. Can you find what changed?');
await pub(mac, 'demo-memory-spike', 'text', { body: 'Bisected it to the response-cache change: entries are keyed by full URL including a cache-busting query param, so nothing ever hits and the map only grows. Capping it with an LRU now, then I’ll re-run the soak test.' });

// ---- D. filler: release notes (unread) ----
await up(mac, 'demo-release-notes', { title: 'Draft the 2.4 release notes', session_state: 'done' });
await send('demo-release-notes', 'Draft release notes for 2.4 from the merged PRs since the 2.3 tag, grouped by area.');
await pub(mac, 'demo-release-notes', 'tool_output', { command: 'git log --oneline v2.3..HEAD --merges', exit_code: 0, snippet: '41 merge commits', truncated: false });
await pub(mac, 'demo-release-notes', 'text', { body: 'Drafted — 27 user-facing changes across upload reliability, the new webhook retries, and dashboard performance. It’s in docs/releases/2.4.md; want me to trim it to the top ten for the blog post?' });

// ---- C. refactor parent + running subagent child ----
await up(mac, 'demo-auth-refactor', { title: 'Refactor auth middleware', session_state: 'running' });
await send('demo-auth-refactor', 'Can you refactor the auth middleware to drop the legacy token path? It should be dead code but I’m not certain.');
await pub(mac, 'demo-auth-refactor', 'text', { body: 'I’ll map every call site first so we know whether anything still reaches the legacy path — spinning up a subagent to sweep the services while I read the middleware itself.' });
await up(mac, 'demo-auth-explore', { title: 'Explore: auth call sites', parent_convo_id: 'demo-auth-refactor', session_state: 'running' });
await pub(mac, 'demo-auth-explore', 'text', { body: 'Sweeping api-server, worker, and admin for authenticate() and X-Legacy-Token usage…' });
await pub(mac, 'demo-auth-explore', 'tool_output', { command: 'rg -n "legacyToken|X-Legacy-Token" --type ts', exit_code: 0, snippet: 'services/api/src/middleware/auth.ts:88\nservices/worker/src/jobs/import.ts:41', truncated: false });
await pub(mac, 'demo-auth-refactor', 'tool_output', { command: 'wc -l services/api/src/middleware/auth.ts', exit_code: 0, snippet: '     214 services/api/src/middleware/auth.ts', truncated: false });
await read('demo-auth-refactor');

// ---- B. dark mode diff chat ----
await up(mac, 'demo-dark-mode', { title: 'Dark mode for settings screen', session_state: 'done' });
await send('demo-dark-mode', 'The settings screen ignores dark mode — every other screen follows the system.');
await pub(mac, 'demo-dark-mode', 'diff', {
  file_path: 'SettingsView.swift',
  diff: '@@ -12,7 +12,7 @@\n-            .background(Color.white)\n+            .background(Color(.systemBackground))\n@@ -27,7 +27,7 @@\n-            .foregroundColor(.black)\n+            .foregroundColor(.primary)',
  added: 2, removed: 2,
});
await pub(mac, 'demo-dark-mode', 'text', { body: 'Fixed — two hard-coded colors were overriding the system appearance. The screen now tracks light and dark like the rest of the app.' });
await read('demo-dark-mode');

// ---- F. homelab-owned convo + pairing room + real consent card ----
await up(home, 'demo-homelab-nightly', { title: 'Nightly build babysitter', session_state: 'done' });
await pub(home, 'demo-homelab-nightly', 'text', { body: 'Nightly run 2214 finished: 1 flaky failure in UploadQueueTests, everything else green.' });
await up(mac, 'demo-pairing-room', { title: 'mac-studio ↔ homelab' });

// ---- A. hero: flaky upload test (seeded last so it sits newest) ----
await up(mac, 'demo-fix-flaky-upload', { title: 'Fix the flaky upload test', session_state: 'waiting' });
await send('demo-fix-flaky-upload', 'The upload test keeps failing on CI but passes locally — can you take a look?');
await pub(mac, 'demo-fix-flaky-upload', 'tool_output', { command: 'swift test --filter UploadQueueTests', exit_code: 1, snippet: "Test Case 'testParallelUploadRetries' failed (3.21s)\nXCTAssertEqual failed: (\"2\") is not equal to (\"3\") — retry count after simulated 503", truncated: false });
await pub(mac, 'demo-fix-flaky-upload', 'text', { body: 'Found it. The mock S3 server binds a fixed port, so parallel CI runs race for it and the loser silently talks to the winner’s instance. Switching it to an ephemeral port and threading the bound URL through.' });
await pub(mac, 'demo-fix-flaky-upload', 'diff', {
  file_path: 'MockS3Server.swift',
  diff: '@@ -14,7 +14,7 @@\n-        listener = try NWListener(using: .tcp, on: 9090)\n+        listener = try NWListener(using: .tcp, on: .any)\n@@ -41,6 +41,9 @@\n+    var boundURL: URL {\n+        URL(string: "http://127.0.0.1:\\(port)")!\n+    }',
  added: 4, removed: 1,
});
await pub(mac, 'demo-fix-flaky-upload', 'tool_output', { command: 'swift test --filter UploadQueueTests', exit_code: 0, snippet: 'Executed 9 tests, with 0 failures (0 unexpected) in 4.87 seconds', truncated: false });
await pub(mac, 'demo-fix-flaky-upload', 'prompt', { question: 'Push the fix and open a PR?', options: ['Yes, push and open a PR', 'Hold off for now'], allows_free_text: true });
await read('demo-fix-flaky-upload');

// The invite names the hero convo, so it must exist first. The server parks
// the request and mints the consent card into the room conversation itself.
await frame(mac, {
  op: 'agent_invite',
  room_id: 'demo-pairing-room',
  target_device_id: HOMELAB_DEVICE_ID,
  topic: 'Verify the flaky-upload fix on the nightly runner',
  justification: 'I fixed the port race in MockS3Server that breaks UploadQueueTests under parallel runs. homelab runs the same suite nightly — I want to hand over the branch so it can verify the fix before I open the PR.',
  from_convo_id: 'demo-fix-flaky-upload',
  target_convo_id: 'demo-homelab-nightly',
});

console.log(`seeded ${n} frames`);
mac.close(); home.close(); app.close();
