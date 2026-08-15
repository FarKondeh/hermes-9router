---
name: exposing-services
description: Run any file/service and make it reachable from outside this HF Space, via the numeric-port nginx proxy convention
published: true
---

# Exposing a Service on a Port — Read This Before Running Anything Long-Lived

This Space only publishes one external port (7860), which nginx listens on.
nginx forwards any request whose **first path segment is a number** straight
to `127.0.0.1:<that number>` inside the container. So exposing something
to the outside world is just: **bind it to that port. Nothing else to
configure.**

## The rule

- Pick any port **1024–65535** (ports below 1024 are blocked by nginx on
  purpose — they're reserved for system services like SSH/HTTP/HTTPS).
- Start the process bound to `0.0.0.0:<port>` (or `127.0.0.1:<port>` —
  both work, since nginx proxies from inside the same container).
- It is then reachable at `https://<this-space-url>/<port>/`.
- No nginx.conf edit, no rebuild, no restart of nginx needed — the proxy
  rule is generic and already covers the whole range.

## What "run this file on port X" means in practice

When the operator says something like *"run app.py on port 9005"* or
*"start this on 8123"*:

1. Launch the process so it listens on `0.0.0.0:<port>` (or
   `127.0.0.1:<port>`), e.g.:
   - Flask: `app.run(host="0.0.0.0", port=9005)`
   - FastAPI/uvicorn: `uvicorn app:app --host 0.0.0.0 --port 9005`
   - Node/Express: `app.listen(9005, "0.0.0.0")`
   - a static file server: `python3 -m http.server 9005 --bind 0.0.0.0`
   - anything else: whatever that tool's `--host`/`--port` (or equivalent)
     flags are.
   Redirect its stdout/stderr to a log file (e.g.
   `nohup python3 app.py > /tmp/app_9005.log 2>&1 &`) so a startup error
   is visible without needing to re-attach to the process.
2. Run it as a background/long-lived process (e.g. `nohup ... &`, a
   terminal session that stays open, or a proper process manager) so it
   keeps running after the current turn ends — a foreground command that
   exits when the tool call returns won't stay reachable.
3. Do exactly **one** bounded check, a couple seconds after launch: read
   the last few lines of that log file. This is the only check — not a
   polling loop, not a `curl`, not repeated re-reads.
   - Clean startup (or nothing alarming yet) → report the URL and stop.
   - `ModuleNotFoundError` / `ImportError` / "command not found" for a
     package → install it once and relaunch:
     - if a `requirements.txt` sits next to the file, run
       `pip install -r requirements.txt --break-system-packages` (or the
       project's existing venv/package manager) and relaunch — don't
       install packages one error at a time if a requirements file
       already lists them.
     - otherwise `pip install --break-system-packages <missing-package>`
       for exactly the package(s) named in the error, then relaunch.
     - after this one retry, apply the same single log check again. If
       it's still failing, report the actual error to the operator
       instead of guessing further or retrying repeatedly.
   - Any other error (bad port, syntax error, etc.) → report it as-is;
     don't attempt speculative fixes beyond the missing-dependency case.
4. Report the URL back as `https://<space-url>/<port>/` — **with the
   trailing slash**. Apps that emit relative links/CSS/JS (most web
   frameworks) need the trailing slash so relative paths resolve under
   the `/port/` prefix instead of `/`.

Keep this to the one launch → one log check → (if needed) one dependency
install → one relaunch → one recheck cycle. Do not keep polling the log,
re-`curl`ing the port, or re-verifying something that already looked
fine — that's what burns tokens for no benefit.

## Writing the app's code itself — do this automatically, every time

The app is reachable at `/<port>/...`, not `/`, but the app process itself
has no idea that prefix exists unless you write it that way. Getting this
wrong is the #1 cause of "login works for a second then bounces to a
broken page" or "the page never loads at all" on these numeric-port apps.
Apply these rules to every app you write for this Space, without being
asked, and without explaining them to the operator first:

- **Never hardcode a leading-slash absolute path** for a redirect target,
  a link, a form `action`, an asset (`<script src>`, `<link href>`), a
  fetch/XHR URL, or a custom "secret" login path. This applies just as
  much to an obfuscated path like `/a1b2c3secret` as it does to
  `/login` or `/dashboard` — the leading slash is the problem, not the
  word after it.
- Instead, use one of:
  - **Relative paths with no leading slash** everywhere (`"login"`,
    `"dashboard"`, `"static/app.js"`, `"a1b2c3secret"`) — these
    resolve correctly under whatever prefix the browser is currently on.
  - Or read the incoming `X-Forwarded-Prefix` header (nginx already
    sends it, e.g. `/9005`) and prepend it to every absolute URL/redirect
    you build server-side.
  - For FastAPI/Starlette specifically: start uvicorn with
    `--root-path /<port>` (matching the bound port) so `request.url_for`,
    `RedirectResponse`, and the auto-generated docs already come out
    prefixed correctly.
  - For cookies: don't set an explicit `Path=/`; either omit `Path`
    (the browser scopes it sensibly to the request path) or set it to
    the prefixed path.
- Before reporting the URL back as done, do a final skim of the code you
  just wrote for any string literal starting with `/` that ends up in a
  `Location` header, an `href`/`src`/`action` attribute, a client-side
  `location.href =` / `fetch(...)` call, or a `Set-Cookie` path — fix any
  you find. This check is part of finishing the task, not an optional
  extra pass.
- `nginx.conf` also carries a generic safety net (the njs body-filter in
  `nginx/njs/prefix_rewrite.js`) that rewrites common absolute-path
  patterns in HTML/JS/CSS/JSON responses as a fallback, plus
  `proxy_cookie_path` to fix cookie scoping. Don't rely on it as the
  primary fix — write prefix-safe code first. It only catches
  *structural* patterns (`href=`, `src=`, `action=`, `url(...)`,
  `location.href =`, `fetch(...)`, common JSON redirect keys) — it does
  **not** catch a client-side router (React Router, Vue Router, etc.)
  comparing `window.location.pathname` against its own route table. See
  "Single-page apps with client-side routing" below for that case.
  If you need a new pattern, edit `nginx/njs/prefix_rewrite.js` inside
  the running container (`/etc/nginx/njs/prefix_rewrite.js`), then
  `nginx -t && nginx -s reload` (never trigger a full rebuild for this —
  reload applies it live without restarting anything else running).

## Single-page apps with client-side routing (React/Vue/etc.) — use the primary-port instead

If the app has its own client-side router (React Router, Vue Router,
Next.js client routing, ...), the `/<port>/` prefix breaks it in a way
no proxy-level rewriting can fix: the router reads
`window.location.pathname`, compares it against routes it knows
(`/dashboard`, `/login`, ...), finds no match for `/<port>/dashboard`,
and bounces to its own not-found/login handler — this happens entirely
in the browser via `history.pushState`, with no new HTTP request nginx
could intercept.

For this case, don't fight the prefix — remove it. Make this app the
**primary** app instead, so it's served at true `/` with zero prefix.

Use the `primary-port` plugin tools for this — `set_primary_port`,
`clear_primary_port`, `get_primary_port` — instead of shelling out to
`set-primary-port.sh` directly. Map any operator phrasing (in any
language) that means "make port N the main/root/primary app" to
`set_primary_port(port=N)`, and anything meaning "disable/unset/clear/
turn off the primary port" to `clear_primary_port()`. Both only run
`nginx -s reload` — they never restart or rebuild the Space, and other
running ports/processes are untouched.

This makes any non-numeric path (`/`, `/login`, `/dashboard`, ...) proxy
straight to `<port>` with no rewriting needed, because the app is now
actually at the root the router already assumes. Other ports you run
stay reachable at their own `/<port>/` as before — this only changes
what answers *unprefixed* requests.

- Only one app can be primary at a time. Setting a new one replaces the
  old one; the old port keeps running, just no longer reachable at `/`
  (you'd need to know its own number, if it even was numbered/exposed).
- To undo it (go back to the static landing page at `/`), use
  `clear_primary_port()`.
- Use `get_primary_port()` to check what's currently set before
  changing it, or when the operator asks.
- The underlying script (`/app/scripts/set-primary-port.sh <port>` /
  `... clear`) still works as a fallback if the plugin tool is ever
  unavailable.
- If the operator's app is a React/Vue/similar SPA meant to be the "main"
  app of the Space, make it primary by default — don't make them ask
  twice after hitting this bug once.
- The alternative (correctly configuring the router's `basename`/`base`
  to `/<port>` and reading it dynamically, e.g. from the first path
  segment or `X-Forwarded-Prefix`) also works and lets multiple SPAs
  coexist under different prefixes simultaneously — use that instead if
  the operator specifically needs more than one SPA reachable at once.

## Constraints and gotchas

- Ports 0–1023 will not be reachable through the proxy — pick something
  in 1024–65535 instead. If the operator insists on a low port, tell
  them it's blocked and offer 1024+ instead.
- Two services can't share the same port. If a port is already taken,
  pick a different one and say so.
- This only covers HTTP(S)/WebSocket-style traffic (nginx `proxy_pass`
  with upgrade headers already set). Raw TCP protocols that aren't
  HTTP won't work through this path.
- Because this proxy is wide open on any 1024+ port with no
  authentication, don't casually expose anything sensitive (an open
  shell, an unauthenticated admin panel, secrets in a debug endpoint,
  etc.) on it — treat every port in this range as public.
- `hermes-agent` itself already occupies port 9001 — avoid reusing it
  for something else.
