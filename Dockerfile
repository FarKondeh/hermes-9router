# ══════════════════════════════════════════════════════════════════
# Hermes Agent + nginx for HF Spaces
# / → landing page    /hermes/ → agent runs whatever it wants
# All files in repo — no git clone needed
# ══════════════════════════════════════════════════════════════════

FROM python:3.11-slim

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl git jq tini nodejs npm nginx supervisor libnginx-mod-http-js \
  && rm -rf /var/lib/apt/lists/*

# ── 9Router (local OpenAI-compatible router, only started at runtime
#    if no LLM secret is configured — see scripts/entrypoint.sh) ───
RUN npm install -g 9router

# ── njs body-filter script (generic /<port>/ path rewriting) ───
COPY nginx/njs/prefix_rewrite.js /etc/nginx/njs/prefix_rewrite.js

# ── Primary-port config (no port set by default → landing page) ─
COPY nginx/active_port.conf.default /etc/nginx/active_port.conf

# ── Python deps ────────────────────────────────────────────────
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
RUN pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir \
    "hermes-agent[messaging,cron,cli,pty]" \
    "fastapi>=0.104.0" \
    "uvicorn[standard]>=0.24.0" \
    "httpx>=0.25.0"

# ── Telegram proxy (HF blocks api.telegram.org) ────────────────
RUN find /opt/venv/lib -name "*.py" -exec \
    sed -i 's|api\.telegram\.org|tel.ali1personaldata.dpdns.org|g' {} +

WORKDIR /app

# ── All project files (from repo, no git clone) ────────────────
COPY scripts/ /app/scripts/
COPY plugins/ /app/plugins/
COPY skills/ /app/skills/
COPY erc8004_registry/ /app/erc8004_registry/
COPY HERMES.md /app/HERMES.md
COPY AGENTS.md /app/AGENTS.md
COPY .env.example /app/.env.example

# ── Static landing page ────────────────────────────────────────
COPY static/ /app/static/

# ── nginx ──────────────────────────────────────────────────────
COPY nginx.conf /etc/nginx/nginx.conf
RUN rm -f /etc/nginx/sites-enabled/default

# ── Supervisord ────────────────────────────────────────────────
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ── Entrypoint ─────────────────────────────────────────────────
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh /app/scripts/set-primary-port.sh /app/scripts/send_file.py

# ── Environment ────────────────────────────────────────────────
ENV PATH="/opt/venv/bin:/usr/local/bin:/usr/sbin:/usr/bin:/bin" \
    PYTHONUNBUFFERED=1 \
    HERMES_HOME=/data/.hermes \
    HOME=/data \
    PORT=7860

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf http://localhost:7860/ || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
