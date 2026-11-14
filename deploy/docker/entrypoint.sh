#!/bin/bash
# Container entrypoint for the Nekopass control panel.
# Runs migrations, creates the initial administrator once, optionally seeds the
# public endpoint settings, then starts the panel and the bundled Caddy proxy.
set -euo pipefail

BIN=/opt/nekopass/bin/nekopass
WEB_DIR=${NEKOPASS_WEB_DIR:-/opt/nekopass/web}
HTTP_ADDR=${NEKOPASS_HTTP_ADDR:-127.0.0.1:8080}
GRPC_ADDR=${NEKOPASS_GRPC_ADDR:-127.0.0.1:9443}
CADDY_CONFIG=${NEKOPASS_CADDY_CONFIG:-/etc/caddy/Caddyfile}
ADMIN_NAME=${NEKOPASS_ADMIN_USERNAME:-admin}
DB_ATTEMPTS=${NEKOPASS_DB_ATTEMPTS:-30}

log() { printf 'nekopass: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

[ -n "${NEKOPASS_DATABASE_URL:-}" ] || die 'NEKOPASS_DATABASE_URL is required'

attempt=1
until "$BIN" -mode migrate; do
    [ "$attempt" -lt "$DB_ATTEMPTS" ] || die 'database is not ready, giving up'
    log "database not ready (attempt $attempt/$DB_ATTEMPTS), retrying in 2s"
    attempt=$((attempt + 1))
    sleep 2
done

first_boot=0
if [ "${NEKOPASS_SKIP_BOOTSTRAP:-0}" != "1" ]; then
    set -- -mode bootstrap -admin-name "$ADMIN_NAME"
    [ -n "${NEKOPASS_ADMIN_PASSWORD:-}" ] || set -- "$@" -random-password
    if output=$("$BIN" "$@" 2>&1); then
        first_boot=1
        printf '%s\n' "$output" >&2
    else
        log "administrator not created (already exists or invalid): $output"
    fi
fi

# Seed the public panel/agent endpoint on the first start so generated node
# install commands already point at the single Caddy port.
if [ "$first_boot" = 1 ] && [ -n "${NEKOPASS_PUBLIC_HOST:-}" ]; then
    host=$NEKOPASS_PUBLIC_HOST
    port=${NEKOPASS_PUBLIC_PORT:-443}
    case "$host" in
        *[!A-Za-z0-9.:-]*) die 'NEKOPASS_PUBLIC_HOST must be a domain or IP address' ;;
    esac
    case "$port" in
        ''|*[!0-9]*) die 'NEKOPASS_PUBLIC_PORT must be a number' ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die 'NEKOPASS_PUBLIC_PORT out of range'
    case "$host" in
        *:*) authority="[$host]" ;;
        *) authority=$host ;;
    esac
    panel_url="https://$authority"
    [ "$port" = 443 ] || panel_url="$panel_url:$port"
    settings=$(printf '{"panel_url":"%s","agent_host":"%s","agent_port":%s,"agent_transport":"tls"}' \
        "$panel_url" "$host" "$port")
    if printf '%s' "$settings" | "$BIN" -mode init-settings; then
        log "public endpoint initialized as $panel_url"
    else
        log 'failed to initialize settings from the environment; configure them in the admin panel'
    fi
fi

# Start the panel on the loopback interface; only Caddy is reachable from
# outside the container.
"$BIN" -mode serve -web "$WEB_DIR" -http "$HTTP_ADDR" -grpc "$GRPC_ADDR" &
PANEL_PID=$!

caddy run --config "$CADDY_CONFIG" --adapter caddyfile &
CADDY_PID=$!

trap 'kill "$PANEL_PID" "$CADDY_PID" 2>/dev/null || true' TERM INT

# Keep the container alive as long as both processes run; exit (and let the
# orchestrator restart) if either one stops.
wait -n "$PANEL_PID" "$CADDY_PID"
EXIT=$?
kill "$PANEL_PID" "$CADDY_PID" 2>/dev/null || true
wait "$PANEL_PID" 2>/dev/null || true
wait "$CADDY_PID" 2>/dev/null || true
exit "$EXIT"
