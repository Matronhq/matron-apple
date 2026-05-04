#!/usr/bin/env node
/**
 * Scriptable Matrix partner client for Matron integration tests.
 *
 * Mirrors `claude-matrix-bridge/add-bot.mjs`'s patterns: matrix-js-sdk +
 * matrix-sdk-crypto-wasm, with `bootstrapSecretStorage` + `bootstrapCrossSigning`
 * to establish the partner as a trust anchor, and a verifier event listener
 * to auto-confirm SAS when Matron initiates a verification.
 *
 * Sub-commands:
 *   register            — register a fresh user via the registration-token flow
 *   bootstrap-anchor    — login + bootstrap SSSS + cross-signing, prints recovery key
 *   wait-verify         — accept incoming verification + auto-confirm SAS
 *   send-message        — send a test message into a room
 *   create-dm           — create a DM with a target user (encryption on)
 *
 * Each command emits one JSON object on stdout per state transition so the
 * shell harness can assert without parsing free-form logs.
 */

import * as sdk from "matrix-js-sdk";
import {
  VerificationPhase,
  VerificationRequestEvent,
  VerifierEvent,
} from "matrix-js-sdk/lib/crypto-api/verification.js";
import { writeFileSync, readFileSync, existsSync, mkdirSync } from "fs";

// Quiet matrix-js-sdk's chatty default logging — keep only flow-relevant lines.
const noisy = /matrix_sdk_crypto|FetchHttpApi|key backup|push rule|Olm|crypto-sdk|CryptoStore|outgoing request|^\[Perf\]|receiveSyncChanges|^Sync|saved sync|queued to-device|client options|^Getting|^Got |^Prepare|^Sending|^Storing|^Resuming|^Attempting|^Fetched|^Adding default|cross signing|Secret storage|^INFO |^Checking|^Completed|^bootstrap|^Downloading|^Token no|^\/sync error|^Failed to proc/;
const origLog = console.log;
console.warn = (...a) => { if (!noisy.test(String(a[0]))) origLog(...a); };
console.log = (...a) => { if (!noisy.test(String(a[0]))) origLog(...a); };
console.debug = () => {};

const emit = (obj) => origLog(JSON.stringify(obj));

function parseArgs(argv) {
  const command = argv[0];
  const out = { command };
  for (let i = 1; i < argv.length; i++) {
    const k = argv[i];
    if (k.startsWith("--")) out[k.slice(2)] = argv[++i];
  }
  return out;
}

// --- register ---
async function cmdRegister(args) {
  const { homeserver, user, password, token, "device-name": deviceName = "matron-test-partner" } = args;
  const url = `${homeserver.replace(/\/$/, "")}/_matrix/client/v3/register`;
  const body = { username: user, password, initial_device_display_name: deviceName };
  // First call: tells us the auth flow / session id.
  let resp = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  let data = await resp.json();
  if (resp.status === 200) {
    emit({ ok: true, user_id: data.user_id, device_id: data.device_id });
    return 0;
  }
  if (!data.session) { emit({ ok: false, error: "no session id", raw: data }); return 1; }
  // Second call: pass registration token.
  body.auth = { type: "m.login.registration_token", token, session: data.session };
  resp = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  data = await resp.json();
  if (resp.status === 200) {
    emit({ ok: true, user_id: data.user_id, device_id: data.device_id });
    return 0;
  }
  emit({ ok: false, status: resp.status, raw: data });
  return 1;
}

// --- shared session helpers ---
async function loginAndStartClient(homeserver, user, password, deviceName = "matron-test-partner") {
  const loginResp = await fetch(`${homeserver.replace(/\/$/, "")}/_matrix/client/v3/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      type: "m.login.password",
      identifier: { type: "m.id.user", user },
      password,
      initial_device_display_name: deviceName,
    }),
  });
  const loginData = await loginResp.json();
  if (!loginData.access_token) throw new Error("login failed: " + JSON.stringify(loginData));

  const secretKey = { privateKey: null };
  let recoveryKey;
  const client = sdk.createClient({
    baseUrl: homeserver,
    accessToken: loginData.access_token,
    userId: loginData.user_id,
    deviceId: loginData.device_id,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const keyId = Object.keys(keys)[0];
        return [keyId, secretKey.privateKey];
      },
    },
  });
  await client.initRustCrypto({ useIndexedDB: false });

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("sync timeout")), 30_000);
    client.once(sdk.ClientEvent.Sync, (state) => {
      clearTimeout(timeout);
      if (state === "PREPARED" || state === "SYNCING") resolve();
      else reject(new Error("sync state: " + state));
    });
    client.startClient({ initialSyncLimit: 0 });
  });
  // Brief pause so the initial /sync settles before we start touching crypto state.
  await new Promise((r) => setTimeout(r, 1500));

  return {
    client,
    cryptoApi: client.getCrypto(),
    loginData,
    secretKey,
    recoveryKeyRef: () => recoveryKey,
    setRecoveryKey: (k) => { recoveryKey = k; },
  };
}

async function bootstrap(session, password) {
  // Create SSSS + recovery key. This produces the recovery key used elsewhere.
  await session.cryptoApi.bootstrapSecretStorage({
    createSecretStorageKey: async () => {
      const keyInfo = await session.cryptoApi.createRecoveryKeyFromPassphrase();
      session.setRecoveryKey(keyInfo.encodedPrivateKey);
      session.secretKey.privateKey = keyInfo.privateKey;
      return keyInfo;
    },
    setupNewSecretStorage: true,
    setupNewKeyBackup: true,
  });
  // Cross-signing — uploads master / self-signing / user-signing keys to the homeserver.
  await session.cryptoApi.bootstrapCrossSigning({
    authUploadDeviceSigningKeys: async (makeRequest) => makeRequest({
      type: "m.login.password",
      identifier: { type: "m.id.user", user: session.loginData.user_id },
      password,
    }),
  });
}

// --- bootstrap-anchor ---
async function cmdBootstrapAnchor(args) {
  const { homeserver, user, password, "store-file": storeFile, "device-name": deviceName } = args;
  if (!storeFile) { emit({ ok: false, error: "--store-file required" }); return 1; }
  const session = await loginAndStartClient(homeserver, user, password, deviceName);
  try {
    await bootstrap(session, password);
    const recoveryKey = session.recoveryKeyRef();
    if (!recoveryKey) throw new Error("bootstrap did not yield a recovery key");
    // Persist credentials + recovery key for downstream commands.
    const dir = storeFile.replace(/[^/]+$/, "");
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(storeFile, JSON.stringify({
      homeserver,
      user_id: session.loginData.user_id,
      device_id: session.loginData.device_id,
      access_token: session.loginData.access_token,
      password,
      recovery_key: recoveryKey,
    }, null, 2));
    emit({ ok: true, user_id: session.loginData.user_id, device_id: session.loginData.device_id, recovery_key: recoveryKey });
    return 0;
  } finally {
    session.client.stopClient();
  }
}

function loadStore(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

async function resumeSession(storeFile) {
  const data = loadStore(storeFile);
  // We re-login (matrix-js-sdk's restoreFromCredentials path is finicky with
  // rust-crypto). Same access token is fine; the store file's password is the
  // SSSS unlock secret elsewhere.
  const secretKey = { privateKey: null };
  const client = sdk.createClient({
    baseUrl: data.homeserver,
    accessToken: data.access_token,
    userId: data.user_id,
    deviceId: data.device_id,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const keyId = Object.keys(keys)[0];
        return [keyId, secretKey.privateKey];
      },
    },
  });
  await client.initRustCrypto({ useIndexedDB: false });
  await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("sync timeout")), 30_000);
    client.once(sdk.ClientEvent.Sync, (state) => {
      clearTimeout(t);
      if (state === "PREPARED" || state === "SYNCING") resolve();
      else reject(new Error("sync state: " + state));
    });
    client.startClient({ initialSyncLimit: 0 });
  });
  await new Promise((r) => setTimeout(r, 1500));
  return { client, cryptoApi: client.getCrypto(), creds: data, secretKey };
}

// --- wait-verify ---
async function cmdWaitVerify(args) {
  const { "store-file": storeFile, timeout = "60" } = args;
  const timeoutMs = parseInt(timeout, 10) * 1000;
  const session = await resumeSession(storeFile);
  emit({ event: "ready", waiting_for: "incoming verification request" });
  const start = Date.now();
  let resolved = false;
  return new Promise((resolve) => {
    const finish = (payload, code) => {
      if (resolved) return;
      resolved = true;
      emit(payload);
      session.client.stopClient();
      resolve(code);
    };
    const interval = setInterval(() => {
      if (Date.now() - start > timeoutMs) {
        clearInterval(interval);
        finish({ ok: false, error: "timeout" }, 3);
      }
    }, 1000);

    session.client.on("crypto.verificationRequestReceived", (request) => {
      emit({ event: "request_received", from: request.otherUserId });
      // Accept right away — the security boundary is the SAS confirm,
      // not the accept.
      request.accept().catch((e) => emit({ event: "accept_error", error: String(e) }));

      let verifierBound = false;
      request.on(VerificationRequestEvent.Change, () => {
        const phase = request.phase;
        emit({ event: "phase_change", phase });
        if (phase === VerificationPhase.Done) {
          clearInterval(interval);
          finish({ ok: true, verified: true }, 0);
          return;
        }
        if (phase === VerificationPhase.Cancelled) {
          clearInterval(interval);
          finish({ ok: false, error: "cancelled", code: request.cancellationCode }, 2);
          return;
        }
        if (request.verifier && !verifierBound) {
          verifierBound = true;
          request.verifier.on(VerifierEvent.ShowSas, async (sas) => {
            emit({ event: "show_sas", method: sas.sasEvent?.method ?? "emoji" });
            try {
              await sas.confirm();
              emit({ event: "sas_confirmed" });
            } catch (e) {
              emit({ event: "sas_confirm_error", error: String(e) });
            }
          });
          request.verifier.verify().catch((e) => {
            const msg = String(e?.message ?? e);
            if (!msg.toLowerCase().includes("cancel")) {
              emit({ event: "verifier_error", error: msg });
            }
          });
        }
      });
    });
  });
}

// --- send-message ---
async function cmdSendMessage(args) {
  const { "store-file": storeFile, room, body } = args;
  const session = await resumeSession(storeFile);
  try {
    const eventId = await session.client.sendMessage(room, { msgtype: "m.text", body });
    emit({ ok: true, event_id: eventId.event_id ?? eventId });
    return 0;
  } finally {
    session.client.stopClient();
  }
}

// --- create-dm ---
async function cmdCreateDm(args) {
  const { "store-file": storeFile, "target-user": target } = args;
  const session = await resumeSession(storeFile);
  try {
    const created = await session.client.createRoom({
      is_direct: true,
      invite: [target],
      preset: "trusted_private_chat",
      initial_state: [{
        type: "m.room.encryption",
        state_key: "",
        content: { algorithm: "m.megolm.v1.aes-sha2" },
      }],
    });
    emit({ ok: true, room_id: created.room_id });
    return 0;
  } finally {
    session.client.stopClient();
  }
}

const commands = {
  register: cmdRegister,
  "bootstrap-anchor": cmdBootstrapAnchor,
  "wait-verify": cmdWaitVerify,
  "send-message": cmdSendMessage,
  "create-dm": cmdCreateDm,
};

const argv = parseArgs(process.argv.slice(2));
if (!argv.command || !commands[argv.command]) {
  console.error("Usage: partner.mjs <command> [--key value …]");
  console.error("Commands: " + Object.keys(commands).join(", "));
  process.exit(1);
}
commands[argv.command](argv).then((code) => process.exit(code ?? 0)).catch((e) => {
  emit({ ok: false, error: String(e?.message ?? e) });
  process.exit(1);
});
