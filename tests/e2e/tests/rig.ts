// Test-side access to the rig rig/rig.sh built: its journal database (to
// check what the app actually sent) and the signed-in session it injects.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const STATE = process.env.E2E_STATE ?? path.join(os.homedir(), 'Library/Caches/matron-e2e/rig');
export const BASE = `http://127.0.0.1:${process.env.E2E_PORT ?? '9820'}`;
export const USERNAME = 'e2e';
export const PASSWORD = 'matron-e2e-2026';

const udid = () => fs.readFileSync(path.join(STATE, 'udid'), 'utf8').trim();

function sessionFile(): string {
  const groups = execFileSync('xcrun', ['simctl', 'get_app_container', udid(), 'chat.matron.app', 'groups'], { encoding: 'utf8' });
  const line = groups.split('\n').find((l) => l.startsWith('group.chat.matron'));
  if (line === undefined) throw new Error('rig: no group.chat.matron container (was the app installed signed?)');
  return path.join(line.split(/\s+/)[1], 'sessions', 'matron.journal.session.json');
}

export function isSignedIn(): boolean {
  return fs.existsSync(sessionFile());
}

/** Writes the rig's seed session so the next launch starts signed in. */
export function injectSession(): void {
  const login = JSON.parse(fs.readFileSync(path.join(STATE, 'login-client.json'), 'utf8'));
  const file = sessionFile();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ userID: USERNAME, deviceID: String(login.device_id), homeserverURL: BASE, accessToken: login.token }));
}

export function removeSession(): void {
  fs.rmSync(sessionFile(), { force: true });
}

/** Rows from the rig journal's database, for checks on what reached the server. */
export function query(sql: string): string[] {
  const out = execFileSync('sqlite3', [path.join(STATE, 'matron.db'), sql], { encoding: 'utf8' });
  return out.split('\n').filter((l) => l !== '');
}

export async function eventually<T>(read: () => T | undefined, what: string, timeout = 20_000): Promise<T> {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = read();
    if (value !== undefined) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 500));
  }
}
