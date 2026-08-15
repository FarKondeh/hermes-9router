#!/usr/bin/env python3
"""
send_file.py — send a local file to the connected chat (Bale or Telegram).

This is the canonical way for the agent to deliver a file back to the operator
when asked "send me the file" / "بفرستش" / "فایل رو بده". It uses the same
bot API the platform adapter already uses, so no extra deps beyond what the
Docker image ships (curl or urllib). No server-bound logging.

Usage:
    python3 scripts/send_file.py <path-to-file> [chat_id]

It resolves credentials from the environment (set by the running gateway):
  - BALE_BOT_TOKEN   + BALE_HOME_CHANNEL  -> Bale (tapi.bale.ai)
  - TELEGRAM_BOT_TOKEN + TELEGRAM_HOME_CHANNEL -> Telegram (api.telegram.org)
If chat_id is omitted it falls back to the HOME_CHANNEL for the detected platform.
If both platforms are configured, the one matching the operator's current chat wins;
otherwise Bale is preferred, then Telegram.
"""
import os
import sys
import json
import urllib.request
import urllib.error

BALE_BASE = "https://tapi.bale.ai/bot"
TG_BASE = "https://api.telegram.org/bot"


def _env_chat(platform: str):
    if platform == "bale":
        return os.environ.get("BALE_HOME_CHANNEL")
    return os.environ.get("TELEGRAM_HOME_CHANNEL")


def _detect():
    """Return (base_url, token, platform) for the best available platform."""
    bale_tok = os.environ.get("BALE_BOT_TOKEN", "").strip()
    tg_tok = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    # Prefer the platform the operator is actively using: a chat id hint via env.
    if bale_tok:
        return BALE_BASE, bale_tok, "bale"
    if tg_tok:
        return TG_BASE, tg_tok, "telegram"
    raise SystemExit("No BALE_BOT_TOKEN or TELEGRAM_BOT_TOKEN in environment.")


def send_file(path: str, chat_id: str | None = None):
    if not os.path.isfile(path):
        raise SystemExit(f"File not found: {path}")

    base, token, platform = _detect()
    if chat_id is None:
        chat_id = _env_chat(platform)
    if not chat_id:
        raise SystemExit(f"No chat_id given and {platform} HOME_CHANNEL is not set.")

    url = f"{base}{token}/sendDocument"
    boundary = "----hermes_sendfile_boundary"
    fname = os.path.basename(path)
    with open(path, "rb") as f:
        data = f.read()

    body = bytearray()
    # chat_id field
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="chat_id"\r\n\r\n'
    body += str(chat_id).encode() + b"\r\n"
    # document field
    body += f"--{boundary}\r\n".encode()
    body += (
        f'Content-Disposition: form-data; name="document"; filename="{fname}"\r\n'
    ).encode()
    body += b"Content-Type: application/octet-stream\r\n\r\n"
    body += data
    body += f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8", "replace")
        raise SystemExit(f"HTTP {e.code}: {payload[:400]}")
    result = json.loads(payload)
    if not result.get("ok"):
        raise SystemExit(f"API error: {payload[:400]}")
    print(f"OK sent '{fname}' to {platform} chat {chat_id} (msg {result['result'].get('message_id')})")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    chat = sys.argv[2] if len(sys.argv) > 2 else None
    send_file(sys.argv[1], chat)
