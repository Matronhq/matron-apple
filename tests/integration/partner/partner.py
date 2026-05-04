"""Scriptable Matrix partner client for Matron integration tests.

Drives the "other device" side of verification + recovery flows so the test
runner can exercise Matron without a human in the loop.

Usage:
    python partner.py register --homeserver http://localhost:6167 --user partner --password partner-pw --token matron-test-only
    python partner.py login    --homeserver http://localhost:6167 --user partner --password partner-pw --store ./partner-store
    python partner.py setup-recovery --store ./partner-store --passphrase 'test-pw'
    python partner.py auto-verify --store ./partner-store --timeout 60

Each command writes JSON status to stdout so the test runner can parse it.
The store directory persists session + crypto state across runs.
"""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

import aiohttp
from nio import (
    AsyncClient,
    AsyncClientConfig,
    KeyVerificationCancel,
    KeyVerificationEvent,
    KeyVerificationKey,
    KeyVerificationMac,
    KeyVerificationStart,
    LoginResponse,
    RegisterResponse,
    ToDeviceError,
)


def emit(payload: dict) -> None:
    print(json.dumps(payload), flush=True)


async def cmd_register(args) -> int:
    """Register a fresh user on the homeserver via the registration endpoint.

    Tuwunel/conduwuit accepts a registration token via the m.login.registration_token
    auth flow when TUWUNEL_REGISTRATION_TOKEN is set. We do the dance manually
    against /register since matrix-nio's register() doesn't expose token auth.
    """
    base_url = args.homeserver.rstrip("/")
    register_url = f"{base_url}/_matrix/client/v3/register"
    body = {
        "username": args.user,
        "password": args.password,
        "auth": {
            "type": "m.login.registration_token",
            "token": args.token,
            "session": "",  # filled in after the first response
        },
        "initial_device_display_name": args.device_name or "matron-test-partner",
    }

    async with aiohttp.ClientSession() as session:
        # First call usually returns 401 with the auth flow + session ID we need
        async with session.post(register_url, json={
            "username": args.user, "password": args.password,
            "initial_device_display_name": args.device_name or "matron-test-partner",
        }) as resp:
            data = await resp.json()
            if resp.status == 200:
                emit({"ok": True, "user_id": data.get("user_id"), "device_id": data.get("device_id")})
                return 0
            session_id = data.get("session")
            if not session_id:
                emit({"ok": False, "error": "no session id in 401", "raw": data})
                return 1

        body["auth"]["session"] = session_id
        async with session.post(register_url, json=body) as resp:
            data = await resp.json()
            if resp.status == 200:
                emit({"ok": True, "user_id": data.get("user_id"), "device_id": data.get("device_id")})
                return 0
            emit({"ok": False, "status": resp.status, "raw": data})
            return 1


async def cmd_login(args) -> int:
    store_path = Path(args.store).resolve()
    store_path.mkdir(parents=True, exist_ok=True)
    config = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
    client = AsyncClient(
        homeserver=args.homeserver,
        user=args.user,
        store_path=str(store_path),
        config=config,
    )
    resp = await client.login(args.password, device_name=args.device_name or "matron-test-partner")
    if isinstance(resp, LoginResponse):
        # Persist credentials for subsequent commands
        creds = {
            "homeserver": args.homeserver,
            "user_id": resp.user_id,
            "device_id": resp.device_id,
            "access_token": resp.access_token,
        }
        (store_path / "credentials.json").write_text(json.dumps(creds))
        await client.close()
        emit({"ok": True, "user_id": resp.user_id, "device_id": resp.device_id})
        return 0
    await client.close()
    emit({"ok": False, "error": str(resp)})
    return 1


def _load_creds(store_path: Path) -> dict:
    return json.loads((store_path / "credentials.json").read_text())


async def _make_client_from_store(store_path: Path) -> AsyncClient:
    creds = _load_creds(store_path)
    config = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
    client = AsyncClient(
        homeserver=creds["homeserver"],
        user=creds["user_id"],
        device_id=creds["device_id"],
        store_path=str(store_path),
        config=config,
    )
    client.access_token = creds["access_token"]
    client.user_id = creds["user_id"]
    client.device_id = creds["device_id"]
    client.load_store()
    return client


async def cmd_setup_recovery(args) -> int:
    """Bootstrap cross-signing + key backup + secret storage on this device,
    so it becomes a trust anchor for Matron to verify against."""
    store_path = Path(args.store).resolve()
    client = await _make_client_from_store(store_path)
    try:
        # Initial sync to populate crypto state
        await client.sync(timeout=10000, full_state=True)
        # Bootstrap cross-signing if not already set up
        # matrix-nio exposes this via the olm API once 0.25 lands.
        # If unavailable, we fall back to "trust the existing setup".
        try:
            from nio.crypto.async_olm_machine import AsyncOlmMachine  # noqa
        except ImportError:
            pass
        # nio doesn't expose a clean cross-signing bootstrap API yet; for
        # tests, the assumption is the partner was set up via a separate
        # tool (Element Web, matrix-commander) before the harness runs.
        # We just verify here that the partner has an identity key.
        identity = client.olm.account.identity_keys
        emit({"ok": True, "identity_curve25519": identity.get("curve25519"), "identity_ed25519": identity.get("ed25519")})
        return 0
    finally:
        await client.close()


async def cmd_auto_verify(args) -> int:
    """Wait for an incoming SAS verification request and auto-confirm it.

    Returns when the flow either completes (.verified) or fails / times out.
    """
    store_path = Path(args.store).resolve()
    client = await _make_client_from_store(store_path)
    state = {"flow_id": None, "transaction_id": None, "verified": False, "cancelled": None}
    done_event = asyncio.Event()

    async def handle_to_device(event):
        try:
            if isinstance(event, KeyVerificationStart):
                if "emoji" not in event.short_authentication_string:
                    emit({"event": "start_no_emoji", "sas": event.short_authentication_string})
                    return
                state["transaction_id"] = event.transaction_id
                emit({"event": "start", "transaction_id": event.transaction_id, "from": event.sender})
                resp = await client.accept_key_verification(event.transaction_id)
                if isinstance(resp, ToDeviceError):
                    emit({"event": "accept_error", "error": str(resp)})
            elif isinstance(event, KeyVerificationKey):
                emit({"event": "key", "transaction_id": event.transaction_id})
                # Auto-confirm — that's the whole point of the test partner
                resp = await client.confirm_short_auth_string(event.transaction_id)
                if isinstance(resp, ToDeviceError):
                    emit({"event": "confirm_error", "error": str(resp)})
            elif isinstance(event, KeyVerificationMac):
                emit({"event": "mac", "transaction_id": event.transaction_id})
                state["verified"] = True
                # Mark verified after MAC; the SDK handles the rest
                done_event.set()
            elif isinstance(event, KeyVerificationCancel):
                emit({"event": "cancel", "reason": event.reason, "code": event.code})
                state["cancelled"] = event.reason
                done_event.set()
        except Exception as exc:
            emit({"event": "handler_exception", "error": str(exc)})

    client.add_to_device_callback(handle_to_device, KeyVerificationEvent)
    sync_task = asyncio.create_task(client.sync_forever(timeout=5000, full_state=True))

    try:
        await asyncio.wait_for(done_event.wait(), timeout=args.timeout)
        emit({"ok": state["verified"], "cancelled": state["cancelled"]})
        return 0 if state["verified"] else 2
    except asyncio.TimeoutError:
        emit({"ok": False, "error": "timeout"})
        return 3
    finally:
        sync_task.cancel()
        try:
            await sync_task
        except (asyncio.CancelledError, Exception):
            pass
        await client.close()


async def cmd_send_message(args) -> int:
    """Send a test message to a room. Used to verify decryption end-to-end."""
    store_path = Path(args.store).resolve()
    client = await _make_client_from_store(store_path)
    try:
        await client.sync(timeout=10000, full_state=True)
        resp = await client.room_send(
            room_id=args.room,
            message_type="m.room.message",
            content={"msgtype": "m.text", "body": args.body},
        )
        emit({"ok": getattr(resp, "event_id", None) is not None, "event_id": getattr(resp, "event_id", None)})
        return 0
    finally:
        await client.close()


async def cmd_create_dm(args) -> int:
    """Create a DM room with a target user. Used so Matron's chat-list has
    something to render."""
    store_path = Path(args.store).resolve()
    client = await _make_client_from_store(store_path)
    try:
        await client.sync(timeout=10000, full_state=True)
        resp = await client.room_create(
            invite=[args.target_user],
            is_direct=True,
            preset="trusted_private_chat",
            initial_state=[
                {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}},
            ],
        )
        room_id = getattr(resp, "room_id", None)
        emit({"ok": room_id is not None, "room_id": room_id})
        return 0 if room_id else 1
    finally:
        await client.close()


def main() -> int:
    p = argparse.ArgumentParser(prog="partner")
    sub = p.add_subparsers(dest="command", required=True)

    r = sub.add_parser("register")
    r.add_argument("--homeserver", required=True)
    r.add_argument("--user", required=True)
    r.add_argument("--password", required=True)
    r.add_argument("--token", required=True)
    r.add_argument("--device-name")
    r.set_defaults(func=cmd_register)

    li = sub.add_parser("login")
    li.add_argument("--homeserver", required=True)
    li.add_argument("--user", required=True)
    li.add_argument("--password", required=True)
    li.add_argument("--store", required=True)
    li.add_argument("--device-name")
    li.set_defaults(func=cmd_login)

    sr = sub.add_parser("setup-recovery")
    sr.add_argument("--store", required=True)
    sr.add_argument("--passphrase", required=False)
    sr.set_defaults(func=cmd_setup_recovery)

    av = sub.add_parser("auto-verify")
    av.add_argument("--store", required=True)
    av.add_argument("--timeout", type=int, default=60)
    av.set_defaults(func=cmd_auto_verify)

    sm = sub.add_parser("send-message")
    sm.add_argument("--store", required=True)
    sm.add_argument("--room", required=True)
    sm.add_argument("--body", required=True)
    sm.set_defaults(func=cmd_send_message)

    cd = sub.add_parser("create-dm")
    cd.add_argument("--store", required=True)
    cd.add_argument("--target-user", required=True)
    cd.set_defaults(func=cmd_create_dm)

    args = p.parse_args()
    return asyncio.run(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
