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
import { decodeRecoveryKey } from "matrix-js-sdk/lib/crypto-api/recovery-key.js";
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
  // rust-crypto). Decode the persisted recovery_key so the resumed crypto
  // store can unlock SSSS — without it, partner doesn't have access to its
  // own self-signing material and same-user device-verification MAC checks
  // against this peer fail with `m.mismatched_sas`. (add-bot.mjs sidesteps
  // this by bootstrapping + verifying in one process — the privateKey is
  // already in memory then. Our harness splits the two phases.)
  const secretKey = {
    privateKey: data.recovery_key ? decodeRecoveryKey(data.recovery_key) : null,
  };
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

// --- bootstrap-and-wait ---
//
// Mirrors `claude-matrix-bridge/add-bot.mjs` exactly: one long-running
// process bootstraps cross-signing, then immediately listens for an
// incoming verification request and auto-confirms SAS — without
// stopping/restarting the client in between. The split form
// (`bootstrap-anchor` followed later by `wait-verify`) loses all
// post-bootstrap in-memory crypto state when the first process exits,
// even with SSSS unlock on resume — and we have a strong suspicion that
// the missing state is the trigger for the same-user device-verification
// MAC interop failure we keep hitting.
async function cmdBootstrapAndWait(args) {
  const { homeserver, user, password, "device-name": deviceName,
          "store-file": storeFile, "create-room": createRoom,
          timeout = "120" } = args;
  const timeoutMs = parseInt(timeout, 10) * 1000;
  const session = await loginAndStartClient(homeserver, user, password, deviceName);
  await bootstrap(session, password);
  const recoveryKey = session.recoveryKeyRef();
  if (!recoveryKey) throw new Error("bootstrap did not yield a recovery key");

  // Persist creds + recovery key for any downstream consumer that still
  // wants the store file (matches bootstrap-anchor's output shape).
  if (storeFile) {
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
  }

  emit({
    event: "bootstrapped",
    user_id: session.loginData.user_id,
    device_id: session.loginData.device_id,
    recovery_key: recoveryKey,
  });

  // Optionally create an encrypted room before going into wait-mode.
  // Used by the chat-list test to seed a room on the server *before*
  // matron-app signs in, so the test can assert chatSummaries() yields
  // it. Both partner-device and any other matron-device see the room
  // (same Matrix user, all rooms are matron's rooms).
  if (createRoom) {
    try {
      const created = await session.client.createRoom({
        name: createRoom,
        preset: "private_chat",
        initial_state: [{
          type: "m.room.encryption",
          state_key: "",
          content: { algorithm: "m.megolm.v1.aes-sha2" },
        }],
      });
      emit({ event: "room_created", room_id: created.room_id, name: createRoom });
    } catch (e) {
      emit({ event: "room_create_error", error: String(e?.message ?? e) });
    }
  }

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
      emit({ event: "request_received", from: request.otherUserId, device: request.otherDeviceId });
      request.accept().catch((e) => emit({ event: "accept_error", error: String(e) }));

      let verifierBound = false;
      let donePathRun = false;
      request.on(VerificationRequestEvent.Change, async () => {
        const phase = request.phase;
        emit({ event: "phase_change", phase });
        if (phase === VerificationPhase.Done) {
          if (donePathRun) return;  // Change can fire multiple times in Done
          donePathRun = true;
          // After SAS completes, matrix-js-sdk does NOT automatically
          // upload a cross-signature for the verified device — that's
          // a separate `crossSignDevice` call. Without it, matron's
          // `verificationState()` stays `unverified` even though SAS
          // itself succeeded. Mirror what Element Web does after a
          // successful self-verify.
          //
          // `request.otherDeviceId` is null after Done in matrix-js-sdk
          // 41.x, so resolve matron's device by querying user devices
          // and picking the one that isn't ours.
          let otherDeviceId = request.otherDeviceId || request.verifier?.deviceId;
          if (!otherDeviceId) {
            const devices = await session.cryptoApi.getUserDeviceInfo([request.otherUserId]);
            const userDevices = devices.get(request.otherUserId);
            if (userDevices) {
              for (const [id] of userDevices) {
                if (id !== session.loginData.device_id) { otherDeviceId = id; break; }
              }
            }
          }
          if (otherDeviceId) {
            try {
              await session.cryptoApi.crossSignDevice(otherDeviceId);
              emit({ event: "cross_signed", device: otherDeviceId });
            } catch (e) {
              emit({ event: "cross_sign_error", error: String(e?.message ?? e) });
            }
          } else {
            emit({ event: "cross_sign_skipped", reason: "could not resolve matron's device id" });
          }
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

// --- bootstrap-and-initiate-verify ---
//
// Inverse of bootstrap-and-wait: partner is the verification INITIATOR.
// After bootstrapping, polls /keys/query for matron's other device,
// then calls `cryptoApi.requestDeviceVerification` to send a `.request`
// to-device event. matron-app receives it via
// `VerificationServiceLive.incomingRequests()`, calls `acceptIncoming`,
// and drives SAS as the responder. Matron's role transitions through
// `routeAcceptedVerificationRequest` with `.responder` (Wave 7 path).
async function cmdBootstrapAndInitiateVerify(args) {
  const { homeserver, user, password, "device-name": deviceName,
          timeout = "120" } = args;
  const timeoutMs = parseInt(timeout, 10) * 1000;
  const session = await loginAndStartClient(homeserver, user, password, deviceName);
  await bootstrap(session, password);
  const recoveryKey = session.recoveryKeyRef();
  emit({
    event: "bootstrapped",
    user_id: session.loginData.user_id,
    device_id: session.loginData.device_id,
    recovery_key: recoveryKey,
  });
  emit({ event: "ready", waiting_for: "matron's device to appear" });

  // Poll for matron's other device. matron-app must be online + synced
  // for its device key to land in our /keys/query — the test signs in
  // matron AFTER receiving our `ready` event so the timing should
  // resolve within a few sliding-sync ticks.
  const start = Date.now();
  let otherDeviceId;
  while (Date.now() - start < 60_000) {
    const devices = await session.cryptoApi.getUserDeviceInfo(
      [session.loginData.user_id], true /* downloadUncached */);
    const userDevices = devices.get(session.loginData.user_id);
    if (userDevices) {
      for (const [id] of userDevices) {
        if (id !== session.loginData.device_id) { otherDeviceId = id; break; }
      }
    }
    if (otherDeviceId) break;
    await new Promise(r => setTimeout(r, 1000));
  }
  if (!otherDeviceId) {
    emit({ ok: false, error: "could not discover matron's other device within 60s" });
    session.client.stopClient();
    return 4;
  }
  emit({ event: "other_device_seen", device_id: otherDeviceId });

  // Initiate verification — sends `m.key.verification.request` to matron.
  const request = await session.cryptoApi.requestDeviceVerification(
    session.loginData.user_id, otherDeviceId);
  emit({ event: "verify_requested", flow_id: request.transactionId ?? null });

  // Drive verifier to completion. Same shape as bootstrap-and-wait's
  // listener: bind ShowSas, auto-confirm, cross-sign on Done.
  let verifierBound = false;
  let donePathRun = false;
  return new Promise((resolve) => {
    let resolved = false;
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

    request.on(VerificationRequestEvent.Change, async () => {
      const phase = request.phase;
      emit({ event: "phase_change", phase });
      if (phase === VerificationPhase.Done) {
        if (donePathRun) return;
        donePathRun = true;
        try {
          await session.cryptoApi.crossSignDevice(otherDeviceId);
          emit({ event: "cross_signed", device: otherDeviceId });
        } catch (e) {
          emit({ event: "cross_sign_error", error: String(e?.message ?? e) });
        }
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
}

const commands = {
  register: cmdRegister,
  "bootstrap-anchor": cmdBootstrapAnchor,
  "bootstrap-and-wait": cmdBootstrapAndWait,
  "bootstrap-and-initiate-verify": cmdBootstrapAndInitiateVerify,
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
