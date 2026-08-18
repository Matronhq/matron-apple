// Screenshot rig responder — keeps mac-studio and homelab connected (so the
// machine picker shows them online), publishes the hero conversation's
// session-status frame (server caches it and replays on viewing), and
// answers recent_folders RPCs so the New Chat flow renders.
//
// Run in background: node /tmp/matron-demo/responder.mjs
import WebSocket from 'ws';
import fs from 'node:fs';

const URL_WS = 'ws://127.0.0.1:9810/ws';
const readToken = (p) => fs.readFileSync(p, 'utf8').split('token:')[1].trim().split(/\s/)[0];

const FOLDERS = {
  'mac-studio': [
    { path: '~/dev/api-server', last_used: Date.now() - 6 * 60_000 },
    { path: '~/dev/mobile-app', last_used: Date.now() - 2 * 3_600_000 },
    { path: '~/dev/infra', last_used: Date.now() - 26 * 3_600_000 },
  ],
  'homelab': [
    { path: '~/builds/nightly', last_used: Date.now() - 40 * 60_000 },
    { path: '~/dev/api-server', last_used: Date.now() - 9 * 3_600_000 },
  ],
};

function hourFrom(now, h) { return new Date(now + h * 3_600_000).toISOString(); }

function statusFrame() {
  const now = Date.now();
  return {
    op: 'status',
    convo_id: 'demo-fix-flaky-upload',
    status: {
      model: 'claude-fable-5',
      workdir: '~/dev/api-server',
      context: { tokens: 184_000, window: 1_000_000, pct: 18 },
      limits: [
        { id: 'session', label: 'Session', percent: 34, resets: '6pm (Europe/London)', resets_at: hourFrom(now, 3) },
        { id: 'week_all_models', label: 'Week (all models)', percent: 12, resets: 'Thu 3am (Europe/London)', resets_at: hourFrom(now, 82) },
      ],
    },
  };
}

function run(name, tokenPath) {
  const ws = new WebSocket(URL_WS);
  ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token: readToken(tokenPath), cursor: null })));
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.op === 'hello_ok') {
      console.log(`[${name}] connected`);
      if (name === 'mac-studio') {
        ws.send(JSON.stringify(statusFrame()));
        setInterval(() => ws.send(JSON.stringify(statusFrame())), 60_000);
      }
    } else if (msg.kind === 'rpc' && msg.request) {
      const { request_id, from_device_id, method } = msg.request;
      const reply = (ok, body) => ws.send(JSON.stringify({
        op: 'agent_response', request_id, to_device_id: from_device_id, ok, ...body,
      }));
      if (method === 'recent_folders') reply(true, { result: { folders: FOLDERS[name] } });
      else reply(false, { error: { code: 'unknown_method' } });
      console.log(`[${name}] answered ${method}`);
    } else if (msg.op === 'error') {
      console.error(`[${name}] error:`, msg);
    }
  });
  ws.on('close', () => { console.log(`[${name}] closed, reconnecting in 2s`); setTimeout(() => run(name, tokenPath), 2000); });
  ws.on('error', (e) => console.error(`[${name}]`, e.message));
}

run('mac-studio', '/tmp/matron-demo/agent-mac-studio.txt');
run('homelab', '/tmp/matron-demo/agent-homelab.txt');
