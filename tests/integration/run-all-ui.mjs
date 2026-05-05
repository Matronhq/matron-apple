#!/usr/bin/env node
// Batched UI scenario runner. Brings Docker up once, registers a fresh
// user per scenario, then runs each scenario sequentially against the
// shared homeserver. Compared with running each scenario through
// `run-harness.sh` standalone, this saves ~60s of Docker bring-up per
// scenario and avoids client-side cross-test contamination by giving
// each scenario its own homeserver user.
//
// The scenarios themselves are still shell scripts in
// `tests/integration/scenarios/*.sh`. They already accept HOMESERVER /
// MATRON_USER / MATRON_PW from env and wipe Mac + iOS app state at
// their start, so this orchestrator's job is purely Docker + user
// provisioning + sequential dispatch + summary.
//
// Usage:
//   node tests/integration/run-all-ui.mjs
//
// Requires: Node 18+ (uses global `fetch`), Docker, npm (for partner
// deps install on first run).

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, openSync, closeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const INT_DIR = join(ROOT, 'tests', 'integration');
const DOCKER_DIR = join(INT_DIR, 'docker');
const PARTNER_DIR = join(INT_DIR, 'partner');
const PARTNER_BIN = join(PARTNER_DIR, 'partner.mjs');
const HOMESERVER = 'http://localhost:6167';
const REG_TOKEN = 'matron-test-only';

const STAMP = new Date().toISOString().replace(/[-T:.]/g, '').slice(0, 15);
const ARTIFACTS_DIR = join(INT_DIR, 'artifacts', `${STAMP}-batch`);
mkdirSync(ARTIFACTS_DIR, { recursive: true });

// Fresh homeserver user per scenario so server-side cross-signing
// state from one scenario doesn't leak into the next. The Mac + iOS
// app state wipe inside each scenario script handles client-side
// isolation.
const SCENARIOS = [
  { script: 'recovery-key-restore-ui.sh', user: 'matron1' },
  { script: 'reverse-direction-ui.sh',    user: 'matron2' },
];

function log(msg) {
  const t = new Date().toISOString().slice(11, 19);
  console.log(`[${t}] ${msg}`);
}

function run(cmd, args, opts = {}) {
  const result = spawnSync(cmd, args, { stdio: 'inherit', ...opts });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

function mustRun(cmd, args, opts) {
  const rc = run(cmd, args, opts);
  if (rc !== 0) throw new Error(`${cmd} ${args.join(' ')} failed (rc=${rc})`);
}

async function waitForHomeserver(timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${HOMESERVER}/_matrix/client/versions`);
      if (res.ok) return;
    } catch {}
    await new Promise(r => setTimeout(r, 1000));
  }
  throw new Error('Homeserver never came up after 60s');
}

let dockerUp = false;
function teardownDocker() {
  if (!dockerUp) return;
  dockerUp = false;
  log('Tearing down homeserver…');
  spawnSync('docker', ['compose', 'down', '-v'], {
    cwd: DOCKER_DIR,
    stdio: 'ignore',
  });
}
process.on('exit', teardownDocker);
process.on('SIGINT',  () => { teardownDocker(); process.exit(130); });
process.on('SIGTERM', () => { teardownDocker(); process.exit(143); });

// --- Pre-flight ---
for (const bin of ['docker', 'node', 'npm']) {
  if (spawnSync('which', [bin], { stdio: 'ignore' }).status !== 0) {
    console.error(`${bin} not found in PATH`);
    process.exit(1);
  }
}

// --- Bring up homeserver ---
log('Bringing up matron-server (tuwunel)…');
spawnSync('docker', ['compose', 'down', '-v'], { cwd: DOCKER_DIR, stdio: 'ignore' });
mustRun('docker', ['compose', 'up', '-d', '--pull', 'always'], { cwd: DOCKER_DIR });
dockerUp = true;

log('Waiting for homeserver /_matrix/client/versions…');
await waitForHomeserver();
log('  Homeserver up.');

if (!existsSync(join(PARTNER_DIR, 'node_modules'))) {
  log('Installing partner Node deps…');
  mustRun('npm', ['install', '--silent'], { cwd: PARTNER_DIR });
}

// --- Register users up-front ---
// Capture the partner.mjs JSON response per user into the artifacts
// dir for post-mortem (matches run-harness.sh's `tee
// register-matron.json` behaviour).
for (const { user } of SCENARIOS) {
  const pw = `${user}-test-pw`;
  log(`Registering @${user}:localhost…`);
  const fd = openSync(join(ARTIFACTS_DIR, `register-${user}.json`), 'w');
  try {
    mustRun('node', [
      PARTNER_BIN, 'register',
      '--homeserver', HOMESERVER,
      '--user', user,
      '--password', pw,
      '--token', REG_TOKEN,
    ], { stdio: ['ignore', fd, 'inherit'] });
  } finally {
    closeSync(fd);
  }
}

// --- Run each scenario sequentially ---
const results = [];
for (const { script, user } of SCENARIOS) {
  const pw = `${user}-test-pw`;
  const scenarioPath = join(INT_DIR, 'scenarios', script);
  if (!existsSync(scenarioPath)) {
    log(`✗ scenario not found: ${scenarioPath}`);
    results.push({ script, user, status: 'MISSING', rc: -1 });
    continue;
  }
  console.log();
  log('================================================================');
  log(`Running scenario: ${script} (user: @${user})`);
  log('================================================================');
  const env = {
    ...process.env,
    HOMESERVER,
    MATRON_USER: user,
    MATRON_PW: pw,
    ARTIFACTS_DIR,
    ROOT,
    PARTNER_CLI: `node ${PARTNER_BIN}`,
  };
  const rc = run('bash', [scenarioPath], { env });
  results.push({
    script, user,
    status: rc === 0 ? 'PASS' : 'FAIL',
    rc,
  });
  if (rc === 0) log(`✓ ${script} PASSED`);
  else          log(`✗ ${script} FAILED (rc=${rc})`);
}

// --- Summary ---
console.log();
log('================================================================');
log('Summary');
log('================================================================');
for (const r of results) {
  const sigil = r.status === 'PASS' ? '✓' : '✗';
  log(`  ${sigil} ${r.status.padEnd(7)} ${r.script.padEnd(40)} (user: @${r.user}, rc=${r.rc})`);
}
log(`Artifacts: ${ARTIFACTS_DIR}`);

process.exit(results.every(r => r.status === 'PASS') ? 0 : 1);
