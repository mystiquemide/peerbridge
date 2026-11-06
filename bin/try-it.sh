#!/usr/bin/env bash
# The PeerBridge guard in one minute, with no Switch and no agents.
# It starts a temporary copy of Dev A's backend on loopback and sends it the
# requests the agents would, through the same wrapper backend-agent uses:
# the real 422, two refusals, Dev A's fix, then the 200.
#   python3 -m venv .venv && .venv/bin/pip install -r sample/backend/requirements.txt
#   bin/try-it.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-$REPO/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -c "import fastapi, uvicorn" 2>/dev/null || {
  echo "Needs the backend's packages: python3 -m venv .venv && .venv/bin/pip install -r sample/backend/requirements.txt" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
cp -r "$REPO/sample/backend" "$WORK/backend"
export PEERBRIDGE_BACKEND_PORT="$PORT" PEERBRIDGE_ACCESS_LOG="$WORK/access.log" \
       PEERBRIDGE_ROUTES="$REPO/peerbridge.routes" PEERBRIDGE_STATE_DIR="$WORK/state"
unset PEERBRIDGE_SWITCH_URL
(cd "$WORK/backend" && exec "$PY" -m uvicorn app:app --host 127.0.0.1 --port "$PORT" --reload \
  --no-access-log --log-level warning) >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 50); do curl -fsS "127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done

call() { printf '%s' "$1" | "$PY" "$REPO/bin/peerbridge-call" "${@:2}" || true; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ORDER='{"method":"POST","path":"/v2/checkout","body":{"price_cents":4999,"currency":"usd","items":[{"sku":"mug","quantity":1}]}}'

say "1. Dev B's checkout call, as frontend-agent builds it from sample/frontend/src/checkout.ts"
call "$ORDER" --message-id demo-1
say "2. Someone asks for a route that isn't allowlisted"
call '{"method":"DELETE","path":"/users"}'
say "3. Someone tries to send the request to another host"
call '{"method":"GET","path":"/health","host":"10.0.0.5"}'
say "4. Dev A: accept price_cents as an alias for amount_cents (edits the temporary copy only)"
sed -i.bak 's/amount_cents: int = Field(gt=0)/amount_cents: int = Field(gt=0, validation_alias=AliasChoices("amount_cents", "price_cents"))/; s/from pydantic import BaseModel, Field/from pydantic import AliasChoices, BaseModel, Field/' "$WORK/backend/app.py"
diff -u "$WORK/backend/app.py.bak" "$WORK/backend/app.py" | tail -n +3 || true
sleep 2.5
say "5. The same request again, after the fix"
call "$ORDER" --message-id demo-1 --rerun
say "Dev A's access log for /v2/checkout: the 422 and the 200, and nothing from the refused requests"
grep " /v2/checkout " "$WORK/access.log"
