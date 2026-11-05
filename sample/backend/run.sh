#!/usr/bin/env sh
# Starts Dev A's backend on loopback with auto-reload, so agent edits take effect.
set -eu
cd "$(dirname "$0")"
PORT="${PEERBRIDGE_BACKEND_PORT:-8001}"
export PEERBRIDGE_ACCESS_LOG="${PEERBRIDGE_ACCESS_LOG:-$PWD/access.log}"
exec python -m uvicorn app:app --host 127.0.0.1 --port "$PORT" --reload --no-access-log
