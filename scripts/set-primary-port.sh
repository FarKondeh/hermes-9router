#!/bin/sh
# Usage:
#   set-primary-port.sh <port>   — make <port> the primary app (served at "/", no prefix)
#   set-primary-port.sh clear    — remove the primary app (falls back to the landing page)
#
# This only changes which port answers bare, non-numeric paths like
# /dashboard or /login. Explicit /<port>/... paths for OTHER ports
# keep working exactly as before, regardless of this setting.
set -e

CONF=/etc/nginx/active_port.conf

if [ "$1" = "clear" ] || [ -z "$1" ]; then
    echo "set \$active_port 1;" > "$CONF"
    echo "Primary port cleared — bare paths now serve the landing page."
else
    case "$1" in
        ''|*[!0-9]*)
            echo "Error: '$1' is not a valid port number." >&2
            exit 1
            ;;
    esac
    if [ "$1" -lt 1024 ] || [ "$1" -gt 65535 ]; then
        echo "Error: port must be between 1024 and 65535." >&2
        exit 1
    fi
    echo "set \$active_port $1;" > "$CONF"
    echo "Primary port set to $1 — bare paths (e.g. /dashboard) now proxy there with no prefix."
fi

nginx -s reload
