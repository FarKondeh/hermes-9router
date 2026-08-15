import re
import subprocess

SCRIPT = "/app/scripts/set-primary-port.sh"
ACTIVE_PORT_CONF = "/etc/nginx/active_port.conf"


def _run(arg: str) -> str:
    result = subprocess.run(
        [SCRIPT, arg],
        capture_output=True,
        text=True,
    )
    output = (result.stdout or "").strip()
    err = (result.stderr or "").strip()
    if result.returncode != 0:
        return f"Error: {err or output or 'set-primary-port.sh failed'}"
    return output or "OK"


def register(ctx):
    set_schema = {
        "name": "set_primary_port",
        "description": (
            "Make a running local port the 'primary' app: it will be served at the "
            "Space's true root URL (with NO /<port>/ prefix and no path rewriting). "
            "Use this whenever the operator asks (in any language/phrasing) to make a "
            "port 'the main app', 'primary', 'root', or to fix a login/redirect loop "
            "for an app that has its own pages (e.g. /login, /dashboard) or client-side "
            "routing (React Router, Vue Router, Next.js, etc.) — the /<port>/ prefix "
            "breaks those because the app's router doesn't know it's not at '/'. "
            "Only one port can be primary at a time; setting a new one replaces the old "
            "one (the old port keeps running, just no longer reachable at '/'). "
            "This only reloads nginx config (nginx -s reload) — it does NOT restart or "
            "rebuild the Space, and does not interrupt other running processes."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "port": {
                    "type": "integer",
                    "description": "The local port (1024-65535) to serve at the root.",
                }
            },
            "required": ["port"],
        },
    }

    clear_schema = {
        "name": "clear_primary_port",
        "description": (
            "Undo set_primary_port: remove whichever port is currently primary, so bare "
            "paths (/, /login, /dashboard, ...) fall back to serving the static landing "
            "page again. Use this whenever the operator asks (in any language/phrasing) "
            "to 'disable', 'unset', 'remove', 'turn off', or 'clear' the primary/root "
            "port. Ports that were reachable at /<port>/ are unaffected and keep working "
            "exactly as before. This only reloads nginx config — it does NOT restart or "
            "rebuild the Space."
        ),
        "parameters": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    }

    status_schema = {
        "name": "get_primary_port",
        "description": (
            "Report which local port (if any) is currently primary, i.e. served at the "
            "Space's true root with no prefix. Use this to check current state before "
            "changing it, or when the operator asks what's currently set as the main app."
        ),
        "parameters": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    }

    def handle_set(params, **kwargs):
        port = params.get("port")
        try:
            port = int(port)
        except (TypeError, ValueError):
            return f"Error: '{port}' is not a valid port number."
        if port < 1024 or port > 65535:
            return "Error: port must be between 1024 and 65535."
        return _run(str(port))

    def handle_clear(params, **kwargs):
        return _run("clear")

    def handle_status(params, **kwargs):
        try:
            with open(ACTIVE_PORT_CONF, "r", encoding="utf-8") as f:
                content = f.read()
        except OSError as exc:
            return f"Error reading {ACTIVE_PORT_CONF}: {exc}"
        match = re.search(r"set\s+\$active_port\s+(\d+)\s*;", content)
        if not match:
            return "No primary port is currently set (bare paths serve the landing page)."
        port = int(match.group(1))
        if port == 1:
            return "No primary port is currently set (bare paths serve the landing page)."
        return f"Primary port is currently {port} (bare paths proxy there with no prefix)."

    ctx.register_tool(
        name="set_primary_port",
        toolset="primary-port",
        schema=set_schema,
        handler=handle_set,
    )
    ctx.register_tool(
        name="clear_primary_port",
        toolset="primary-port",
        schema=clear_schema,
        handler=handle_clear,
    )
    ctx.register_tool(
        name="get_primary_port",
        toolset="primary-port",
        schema=status_schema,
        handler=handle_status,
    )
