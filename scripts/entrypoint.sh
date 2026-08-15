#!/usr/bin/env bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
export MESSAGING_CWD="${MESSAGING_CWD:-/data/workspace}"

# ── Plugin discovery ────────────────────────────────────────────
echo "[bootstrap] Installing custom plugins into hermes-agent..."
if [ -d "/app/plugins" ]; then
  mkdir -p "${HERMES_HOME}/plugins"
  for plugin_dir in /app/plugins/*/; do
    plugin_name=$(basename "$plugin_dir")
    target="${HERMES_HOME}/plugins/${plugin_name}"
    if [ ! -d "$target" ]; then
      cp -r "$plugin_dir" "$target"
      echo "[bootstrap]   + Installed plugin: ${plugin_name}"
    else
      echo "[bootstrap]   = Plugin already exists: ${plugin_name}"
    fi
  done
fi

echo "═══════════════════════════════════════════════════════"
echo "  🚀 HF Space: Hermes Agent + nginx"
echo "═══════════════════════════════════════════════════════"

mkdir -p "${HERMES_HOME}/logs" "${HERMES_HOME}/sessions" "${HERMES_HOME}/cron" "${HERMES_HOME}/pairing" "${MESSAGING_CWD}"
mkdir -p "${HOME}/.claude"

# ── 9Router auto-provision ───────────────────────────────────────
NINEROUTER_PORT=20128
NINEROUTER_DATA_DIR="${HOME}/.9router"

if [[ -z "${OPENROUTER_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" && -z "${OPENAI_BASE_URL:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[bootstrap] No LLM secret set — initializing secure 9router on 127.0.0.1:${NINEROUTER_PORT}..."
  mkdir -p "${NINEROUTER_DATA_DIR}/db"

  NINEROUTER_SECRETS_FILE="${NINEROUTER_DATA_DIR}/.bootstrap_secrets"
  if [[ -f "$NINEROUTER_SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$NINEROUTER_SECRETS_FILE"
  else
    NINEROUTER_INITIAL_PASSWORD="123456"
    NINEROUTER_JWT_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    NINEROUTER_API_KEY_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    # ساخت کلید رندوم امن
    NINEROUTER_PROVISIONED_KEY="sk-9r-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    {
      echo "NINEROUTER_INITIAL_PASSWORD=${NINEROUTER_INITIAL_PASSWORD}"
      echo "NINEROUTER_JWT_SECRET=${NINEROUTER_JWT_SECRET}"
      echo "NINEROUTER_API_KEY_SECRET=${NINEROUTER_API_KEY_SECRET}"
      echo "NINEROUTER_PROVISIONED_KEY=${NINEROUTER_PROVISIONED_KEY}"
    } > "$NINEROUTER_SECRETS_FILE"
    chmod 600 "$NINEROUTER_SECRETS_FILE"
    echo "[bootstrap] Generated new random secure API Key."
  fi

  export INITIAL_PASSWORD="${NINEROUTER_INITIAL_PASSWORD}"
  export JWT_SECRET="${NINEROUTER_JWT_SECRET}"
  export API_KEY_SECRET="${NINEROUTER_API_KEY_SECRET}"
  export NINEROUTER_KEY="${NINEROUTER_PROVISIONED_KEY}"

  # تزریق مستقیم کلید رندوم به دیتابیس SQLite
  NINEROUTER_DB="${NINEROUTER_DATA_DIR}/db/data.sqlite"
  python3 - <<PYEOF
import sqlite3, time, uuid

db_path = "${NINEROUTER_DB}"
key_val = "${NINEROUTER_KEY}"
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS apiKeys (
            id TEXT PRIMARY KEY,
            name TEXT,
            key TEXT UNIQUE,
            createdAt INTEGER
        )
    """)
    cur.execute("INSERT OR REPLACE INTO apiKeys (id, name, key, createdAt) VALUES (?, ?, ?, ?)",
                ("bootstrap-default-key", "Default Key", key_val, int(time.time() * 1000)))
    con.commit()
    con.close()
    print("[bootstrap] Secure random key injected successfully.")
except Exception as e:
    print(f"[bootstrap] Notice: {e}")
PYEOF

  # تنظیم متغیرهای محیطی کلاینت
  export OPENAI_API_KEY="${NINEROUTER_KEY}"
  export OPENAI_BASE_URL="http://127.0.0.1:${NINEROUTER_PORT}/v1"
  echo "[bootstrap] OPENAI_API_KEY configured (${OPENAI_API_KEY:0:12}...)"
  echo "[bootstrap] OPENAI_BASE_URL=${OPENAI_BASE_URL}"

  # کانفیگ سوپروایزر برای اجرای دائمی 9router منحصراً روی 127.0.0.1
  mkdir -p /etc/supervisor/conf.d /etc/supervisor/extra.d
  cat > /etc/supervisor/conf.d/9router.conf <<EOF
[program:9router]
command=/usr/bin/env DATA_DIR=${NINEROUTER_DATA_DIR} HOSTNAME=127.0.0.1 9router --host 127.0.0.1 --port ${NINEROUTER_PORT} --no-browser --skip-update
directory=/app
environment=DATA_DIR="${NINEROUTER_DATA_DIR}",HOST="127.0.0.1",HOSTNAME="127.0.0.1",INITIAL_PASSWORD="${NINEROUTER_INITIAL_PASSWORD}",JWT_SECRET="${NINEROUTER_JWT_SECRET}",API_KEY_SECRET="${NINEROUTER_API_KEY_SECRET}"
priority=1
autostart=true
autorestart=true
startsecs=5
stdout_logfile=/tmp/9router_stdout.log
stderr_logfile=/tmp/9router_stderr.log
EOF
  cp /etc/supervisor/conf.d/9router.conf /etc/supervisor/extra.d/9router.conf 2>/dev/null || true

  # ثبت در رجیستری پورت
  python3 -c "
import json, datetime
from pathlib import Path
p = Path('${HERMES_HOME}') / 'port_registry.json'
try:
    reg = json.loads(p.read_text())
except Exception:
    reg = {}
reg.setdefault('ports', {})
reg['ports']['${NINEROUTER_PORT}'] = {
    'service': '9router',
    'launched_by': 'pre-existing',
    'cmd': '9router --host 127.0.0.1 --port ${NINEROUTER_PORT}',
    'name_confirmed': True,
    'updated': datetime.datetime.utcnow().isoformat(),
}
p.write_text(json.dumps(reg, indent=2))
" 2>&1 || true

  PRIMARY_MARKER="${HERMES_HOME}/.9router_primary_set"
  if [[ ! -f "$PRIMARY_MARKER" ]]; then
    echo "set \$active_port ${NINEROUTER_PORT};" > /etc/nginx/active_port.conf
    touch "$PRIMARY_MARKER"
    echo "[bootstrap] Primary port set to ${NINEROUTER_PORT} (9router on 127.0.0.1)."
  fi
fi

# ── Validate provider ──────────────────────────────────────────
if [[ -z "${OPENROUTER_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" && -z "${OPENAI_BASE_URL:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[bootstrap] ERROR: Set OPENAI_API_KEY or ANTHROPIC_API_KEY." >&2
  exit 1
fi

# ── Validate platform ──────────────────────────────────────────
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -z "${BALE_BOT_TOKEN:-}" ]]; then
  echo "[bootstrap] ERROR: Set TELEGRAM_BOT_TOKEN or BALE_BOT_TOKEN." >&2
  exit 1
fi

# ── API key ─────────────────────────────────────────────────────
HERMES_API_KEY_FILE="${HERMES_HOME}/.hermes_api_key"
if [[ -z "${HERMES_API_KEY:-}" ]]; then
  if [[ -f "$HERMES_API_KEY_FILE" ]]; then
    export HERMES_API_KEY="$(cat "$HERMES_API_KEY_FILE")"
  else
    export HERMES_API_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    echo "$HERMES_API_KEY" > "$HERMES_API_KEY_FILE"
    chmod 600 "$HERMES_API_KEY_FILE"
  fi
fi

# ── Write .env ──────────────────────────────────────────────────
ENV_FILE="${HERMES_HOME}/.env"
{
  echo "HERMES_HOME=${HERMES_HOME}"
  echo "MESSAGING_CWD=${MESSAGING_CWD}"
  echo "HERMES_API_KEY=${HERMES_API_KEY}"
  for key in \
    OPENROUTER_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY LLM_MODEL \
    TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_ALLOW_ALL_USERS \
    BALE_BOT_TOKEN BALE_ALLOWED_USERS BALE_ALLOW_ALL_USERS \
    BALE_HOME_CHANNEL BALE_HOME_CHANNEL_NAME \
    TELEGRAM_HOME_CHANNEL TELEGRAM_HOME_CHANNEL_NAME \
    GATEWAY_ALLOW_ALL_USERS
  do
    val="${!key:-}"
    [[ -n "$val" ]] && echo "${key}=${val}"
  done
} > "$ENV_FILE"

echo "[bootstrap] .env written"

# ── Inherit Bale users → Telegram for auth ──────────────────────
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -n "${BALE_ALLOWED_USERS:-}" && -z "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
  export TELEGRAM_ALLOWED_USERS="${BALE_ALLOWED_USERS}"
  echo "[bootstrap] Inherited BALE_ALLOWED_USERS → TELEGRAM_ALLOWED_USERS"
fi

# ── Generate/Update config.yaml ─────────────────────────────────
CONFIG_FILE="${HERMES_HOME}/config.yaml"
echo "[bootstrap] Generating config.yaml"

cat > "$CONFIG_FILE" <<EOF
model: ${LLM_MODEL:-openai/gpt-4o-mini}
terminal:
  backend: local
  cwd: /data/workspace
  timeout: 180
compression:
  enabled: true
  threshold: 0.85
platforms:
EOF

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  cat >> "$CONFIG_FILE" <<EOF
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    extra:
      base_url: "https://tel.ali1personaldata.dpdns.org/bot"
      base_file_url: "https://tel.ali1personaldata.dpdns.org/file/bot"
EOF
  if [[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
    echo "    allowed_users: \"${TELEGRAM_ALLOWED_USERS}\"" >> "$CONFIG_FILE"
  fi
  echo "[bootstrap] Telegram configured"
fi

if [[ -n "${BALE_BOT_TOKEN:-}" ]]; then
  cat >> "$CONFIG_FILE" <<EOF
  bale:
    enabled: true
    token: "${BALE_BOT_TOKEN}"
    extra:
      base_url: "https://tapi.bale.ai/"
      base_file_url: "https://tapi.bale.ai/"
EOF
  if [[ -n "${BALE_ALLOWED_USERS:-}" ]]; then
    echo "    allowed_users: \"${BALE_ALLOWED_USERS}\"" >> "$CONFIG_FILE"
  fi
  echo "[bootstrap] Bale configured"
fi

echo "[bootstrap] config.yaml generated"

# ── Plugin discovery ───────────────────────────────────────────
echo "[bootstrap] Discovering plugins..."
python3 -c "
import os, yaml
from pathlib import Path

cfg_file = Path('${HERMES_HOME}') / 'config.yaml'
plugins_root = Path('/app/plugins')

try:
    with cfg_file.open() as f:
        cfg = yaml.safe_load(f) or {}
except:
    cfg = {}

names = []
if plugins_root.exists():
    for p in sorted(plugins_root.glob('*/plugin.yaml')):
        try:
            m = yaml.safe_load(p.read_text()) or {}
        except:
            m = {}
        n = str(m.get('name') or p.parent.name).strip()
        if n and n not in names:
            names.append(n)

print(f'[bootstrap] Found plugins: {names}')

toolsets = cfg.get('toolsets') or []
for n in names:
    if n not in toolsets:
        toolsets.append(n)
cfg['toolsets'] = toolsets

plugins_cfg = cfg.get('plugins') or {}
enabled = plugins_cfg.get('enabled') or []
for n in names:
    if n not in enabled:
        enabled.append(n)
cfg['plugins'] = {'enabled': enabled}

with cfg_file.open('w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print(f'[bootstrap] Toolsets: {toolsets}')
print(f'[bootstrap] Enabled: {enabled}')
" 2>&1 || echo "[bootstrap] WARNING: Plugin discovery failed (non-fatal)"

# ── Start all services via supervisord ──────────────────────────
echo "[bootstrap] Starting services..."
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf