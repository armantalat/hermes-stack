#!/bin/sh
# Mirrors the HF kit's svc-omnirouter.sh: write .env in the data dir,
# warm up the Qwen guest headers once, then exec the router.
set -eu

D=/data
mkdir -p "$D"
cd "$D"

{
    echo "PORT=${PORT:-8080}"
    echo "ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}"
    echo "AGENT_MODE=${AGENT_MODE:-1}"
    if [ -n "${ROUTER_KEY:-}" ]; then echo "ROUTER_KEY=${ROUTER_KEY}"; fi
    if [ -n "${AUTO_CHAIN:-}" ]; then echo "AUTO_CHAIN=${AUTO_CHAIN}"; fi
} > .env

export QWEN_BX_FILE=qwen-bx.json
if [ ! -f qwen-bx.json ]; then
    echo "[omnirouter] warming up qwen guest headers (one-off, may take a minute)..."
    if timeout 90 /app/qwen-bx >/dev/null 2>&1; then
        echo "[omnirouter] qwen-bx OK"
    else
        echo "[omnirouter] qwen-bx failed (non-fatal, retried on next start)"
    fi
fi

exec /app/omnirouter
