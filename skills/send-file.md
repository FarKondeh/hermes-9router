---
name: send-file
description: Send a local file back to the operator in-chat (Bale/Telegram) when they ask "send me the file" / "بفرستش" / "فایل رو بده". Uses the platform bot API via scripts/send_file.py — never say "I can't send files".
published: true
---

# Send a File Back to the Operator

When the operator asks you to send a file ("فایل رو بفرست", "بفرستش", "send me the file",
"give me the zip"), **you CAN and MUST deliver it in-chat**. Do NOT say "I can't send files"
or "I don't have a file tool" — a working sender is bundled.

## How to send

Use the bundled helper (no extra deps; uses urllib + the same bot API the adapter uses):

```bash
python3 /app/scripts/send_file.py <absolute-path-to-file> [chat_id]
```

- Credentials and target chat come from the environment automatically:
  `BALE_BOT_TOKEN` + `BALE_HOME_CHANNEL` (Bale), or
  `TELEGRAM_BOT_TOKEN` + `TELEGRAM_HOME_CHANNEL` (Telegram).
- If `chat_id` is omitted, it falls back to the platform's HOME_CHANNEL (the operator's current chat).
- If both platforms are configured, Bale is preferred, then Telegram.

## Steps
1. Confirm the file exists (`ls -la <path>`). If the operator gave only a name, locate it first
   (e.g. under `/data/.hermes/exports/`, `/data/workspace/`, or the workspace).
2. Run: `python3 /app/scripts/send_file.py /abs/path/to/file`
3. The helper prints `OK sent '...' to <platform> chat <id> (msg N)`. Report that back.
4. If it errors, read the message — usually a missing token/env. Never silently give up; tell the
   operator what's missing.

## Gotchas
- This is the file-send path. Do NOT fall back to `send_message` (text only) for files.
- The file is sent from the running Space's filesystem. Make sure the path is the real on-disk file
  (the one you created/downloaded), not a description of it.
- Large files: Bale/Telegram bots cap document size (~50MB). For bigger artifacts, tell the operator
  and offer an alternative (external link, or split).
- Never log the bot token. The helper reads it from env and never prints it.
