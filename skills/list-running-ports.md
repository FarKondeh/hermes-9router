---
name: list-running-ports
description: Track which service runs on which port in this Space. The agent records every port it is asked to run (and updates it if the port changes). Ports 7860 (nginx gateway) and 9001 (hermes-agent) are the Space's own pre-existing fixtures, and 20128 (9router) is one too whenever it's active. One-shot reporting, no per-port probing.
published: true
---

# Running Ports — Persistent Tracker

The agent must keep a **persistent map** of `port → what's running there`,
so the operator (or the agent later) never has to rediscover it by probing
ports one by one.

## Pre-existing ports (the Space's own infrastructure)

Only these are alive **before the agent even starts** and are NOT
something the agent launched:

| port   | service        | how to identify                             |
|--------|----------------|----------------------------------------------|
| 7860   | nginx-gateway  | cmdline has `nginx`                          |
| 9001   | hermes-agent   | cmdline has `scripts.agent_server.main:app`  |
| 20128  | 9router        | cmdline has `9router` — **only present if the Space auto-provisioned an LLM key at boot** (no `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/etc. secret was set). If a secret was set, port 20128 does not exist and should not be assumed. |

`entrypoint.sh` already seeds `port_registry.json` with the 20128 entry
itself when it starts 9router, so the agent doesn't need to add it —
just read it like any other pre-existing entry if it's there. Seed the
state file with 7860 and 9001 (plus 20128 if `entrypoint.sh` already
added it) on first use. **Never hardcode any other port** (no example
tied to a specific app) — every other port is learned at runtime from
the operator.

## Ask for the service name

When the operator asks to run something on a port, **do NOT guess the
service name**. Always confirm the label:

- If the operator already named it (e.g. *"run the API on 3000"*,
  *"سرویس رو روی ۳۰۰۰ بزن"*), use that name.
- If they did NOT name it (e.g. *"run this on 4000"* with only a file),
  **ask**: *"این سرویس چی اسمشه تا ذخیره کنم؟"* / *"What should I call
  this service for the port registry?"* — then record their answer.
- Default fallback only if they refuse to name it: use the filename or
  `app-on-<port>` (e.g. `app-on-4000`), and note `name_confirmed: false`.

Never invent a descriptive name like "my-secret-panel" on your own —
that was a mistake; the operator owns the naming.

## State file

Path: `$HERMES_HOME/port_registry.json` (fallback `/data/.hermes/port_registry.json`)

Schema:
```json
{
  "ports": {
    "7860": {"service": "nginx-gateway", "launched_by": "pre-existing", "cmd": "nginx -g daemon off;", "name_confirmed": true, "updated": "2026-08-13T19:00:00"},
    "9001": {"service": "hermes-agent", "launched_by": "pre-existing", "cmd": "uvicorn scripts.agent_server.main:app --port 9001", "name_confirmed": true, "updated": "2026-08-13T19:00:00"}
  }
}
```

Per-port fields:
- `service`: the operator-provided (or confirmed) name.
- `launched_by`: `"pre-existing"` for 7860/9001/20128, else an operator note
  (e.g. `"operator: run X on 3000"`) or `"agent"`.
- `cmd`: exact launch command.
- `name_confirmed`: true if the name came from the operator, false if guessed.
- `updated`: ISO timestamp of last change.

## Rules

### When the operator says "run X on port N" (or "start this on N")
1. **Get the name first** (see "Ask for the service name" above).
2. Launch it (background process, bound to 0.0.0.0:N or 127.0.0.1:N).
3. **Record it**: write/update the state file entry for port N with the
   confirmed name, cmd, `launched_by`, `name_confirmed`, `updated=now`.
4. If port N already exists with a *different* cmd, overwrite it (reused /
   changed port) — keep only the latest.

### When the operator stops/changes a port
- Move N→M: delete N's entry, add M's (with the same service name).
- Kill it: remove the entry — UNLESS it's 7860, 9001, or 20128 (those always stay
  as pre-existing).

### When the operator asks "what ports are running" / "روی چه پورت‌هایی چی اجرا میشه"
1. Read the state file (don't probe ports individually).
2. Optionally verify each recorded port is still listening (one `ss -tlnp`
   call, just to mark `alive: true/false` — not to discover new ones).
3. Print the table. Mark the **primary** port (from
   `/etc/nginx/active_port.conf`) with `<-- PRIMARY (served at /)`.

### First-run seeding
If the state file doesn't exist, create it pre-filled with **only** 7860
and 9001 (pre-existing). Everything else is added at runtime from the
operator's requests — never hardcode example ports/apps.

## One-shot gather (verify step)
```python
import os, subprocess, re, json, datetime

HERMES_HOME = os.environ.get("HERMES_HOME", "/data/.hermes")
STATE = os.path.join(HERMES_HOME, "port_registry.json")
KNOWN = {
    7860: {"service": "nginx-gateway", "launched_by": "pre-existing"},
    9001: {"service": "hermes-agent", "launched_by": "pre-existing"},
}

out = subprocess.run(['ss','-tlnp'], capture_output=True, text=True).stdout
listening = set()
for line in out.splitlines():
    m = re.search(r':(\d+)\s+.*?pid=(\d+)', line)
    if m: listening.add(int(m.group(1)))

if os.path.exists(STATE):
    reg = json.load(open(STATE))
else:
    reg = {"ports": {}}
    for p, info in KNOWN.items():
        reg["ports"][str(p)] = {**info, "cmd": "", "name_confirmed": True,
                                 "updated": datetime.datetime.utcnow().isoformat()}
    json.dump(reg, open(STATE,'w'), indent=2)

PRIMARY = None
try:
    ap = open('/etc/nginx/active_port.conf').read()
    m = re.search(r'set \$active_port (\d+);', ap)
    PRIMARY = int(m.group(1)) if m else None
except: pass

for port, info in sorted(reg["ports"].items(), key=lambda x: int(x[0])):
    info["alive"] = int(port) in listening
    flag = "  <-- PRIMARY" if PRIMARY and port == str(PRIMARY) else ""
    print(f"{port:<6} {info.get('service','?'):<22} alive={info.get('alive')} ({info.get('launched_by')}){flag}")
```

## Report format
```
Port   Service               Alive  Launched-by
7860   nginx-gateway         true   pre-existing
9001   hermes-agent          true   pre-existing
3000   <operator-named>      true   operator: run X on 3000
---
Primary: <port> (served at /)
```

## Gotchas
- This is read/write of a JSON file + ONE `ss` call — never probe each
  port with separate curls.
- Don't remove 7860/9001/20128 from the registry even if briefly not listening;
  they are permanent fixtures of this Space.
- **Don't hardcode any app-specific port** (no example names) in
  this skill — learn them from the operator at runtime.
- Always confirm the service name with the operator before recording it.
- Keep the file small; overwrite, don't append duplicates.
