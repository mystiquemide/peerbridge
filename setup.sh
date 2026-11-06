#!/usr/bin/env bash
# Sets up the PeerBridge demo on one machine against a running Switch core:
# two users (Dev A, Dev B), one controller each, Dev A's sample backend and
# wrapper, backend-agent and frontend-agent, the api-sync room, and both
# addressing policies.
#
# Run Switch core first (see README, "Start Switch"), then:
#   SWITCH_DIR=~/switch OPENAI_API_KEY=... ./setup.sh
#
# Settings (environment):
#   SWITCH_DIR       Switch checkout whose .env holds the gateway admin login (required)
#   SWITCH_URL       Switch core URL (default http://127.0.0.1:8000)
#   PEERBRIDGE_WORK  where checkouts, controller data, logs and passwords go (default ~/peerbridge-demo)
#   OPENAI_API_KEY   Codex API key passed to both controllers. Without it, give each
#                    controller a Codex login from Switch Console before using the agents.
#   CODEX_MODEL      model for both agents (default: the provider's default)
#   CONTROLLER_BIN   switch-agent-controller command (default switch-agent-controller)
#   BACKEND_PORT     Dev A's backend port (default 8001)
#   EMAIL_DOMAIN     domain for the two accounts (default switch.local)
#   AGENT_PREFIX     prefix for the agent names, which are unique across the whole
#                    Switch server (default none: backend-agent, frontend-agent)
#   FORCE_WRAPPER=1  replace an existing /opt/peerbridge install that points elsewhere
set -euo pipefail

: "${SWITCH_DIR:?set SWITCH_DIR to your Switch checkout}"
SWITCH_URL="${SWITCH_URL:-http://127.0.0.1:8000}"
WORK="${PEERBRIDGE_WORK:-$HOME/peerbridge-demo}"
CONTROLLER_BIN="${CONTROLLER_BIN:-switch-agent-controller}"
BACKEND_PORT="${BACKEND_PORT:-8001}"
DOMAIN="${EMAIL_DOMAIN:-switch.local}"
BACKEND_NAME="${AGENT_PREFIX:-}backend-agent"
FRONTEND_NAME="${AGENT_PREFIX:-}frontend-agent"
REPO="$(cd "$(dirname "$0")" && pwd)"
API="$SWITCH_URL/gateway"

for tool in curl jq git python3 openssl "$CONTROLLER_BIN"; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null && sudo -v || { echo "installing the wrapper needs root: run as root or with sudo" >&2; exit 1; }
fi
curl -fsS "$SWITCH_URL/health" >/dev/null || { echo "Switch core isn't answering at $SWITCH_URL" >&2; exit 1; }

umask 077
mkdir -p "$WORK/logs" "$WORK/jars"
CREDS="$WORK/credentials.env"
[ -f "$CREDS" ] || touch "$CREDS"
# shellcheck disable=SC1090
. "$CREDS"

step() { printf '\n== %s\n' "$*"; }
trap 'echo "setup.sh stopped. Anything it started is listed in $WORK/*.pid. Stop it with: kill \$(cat $WORK/*.pid)" >&2' ERR
env_value() { grep -E "^$1=" "$SWITCH_DIR/.env" | tail -1 | cut -d= -f2-; }

# api <jar> <method> <path> [json body] prints the body and fails on a non-2xx status.
api() {
  local jar="$1" method="$2" path="$3" body="${4:-}" out code
  out="$(mktemp)"
  code=$(curl -sS -o "$out" -w '%{http_code}' -b "$jar" -c "$jar" -X "$method" \
    -H 'Content-Type: application/json' ${body:+--data "$body"} "$API$path")
  if [ "${code:0:1}" != 2 ]; then
    echo "$method $path -> $code: $(head -c 400 "$out")" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

login() {
  local jar="$WORK/jars/$1"
  rm -f "$jar"
  api "$jar" POST /auth/login "$(jq -n --arg e "$2" --arg p "$3" '{email:$e,password:$p}')" >/dev/null
}

step "Users"
login admin "$(env_value GATEWAY_ADMIN_EMAIL)" "$(env_value GATEWAY_ADMIN_PASSWORD)"
for who in deva devb; do
  var="${who^^}_PASSWORD"
  if [ -z "${!var:-}" ]; then
    pass="$(openssl rand -base64 24 | tr -d '/+=')Aa1!"
    name=$([ "$who" = deva ] && echo "Dev A" || echo "Dev B")
    api "$WORK/jars/admin" POST /users \
      "$(jq -n --arg e "$who@$DOMAIN" --arg n "$name" --arg p "$pass" '{email:$e,name:$n,password:$p}')" >/dev/null
    echo "$var=$pass" >> "$CREDS"
    printf -v "$var" '%s' "$pass"
    echo "created $who@$DOMAIN"
  else
    echo "$who@$DOMAIN exists"
  fi
  login "$who" "$who@$DOMAIN" "${!var}"
done
DEVB_ID=$(api "$WORK/jars/devb" GET /auth/me | jq -r '.id // .user.id')

step "Controllers"
ENV_FILE="$WORK/controller.env"
: > "$ENV_FILE"
[ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$ENV_FILE"
for who in deva devb; do
  data="$WORK/ctrl-$who"
  if [ ! -d "$data" ]; then
    code=$(api "$WORK/jars/$who" POST /management/enrollment-codes | jq -r .code)
    "$CONTROLLER_BIN" enroll --server "$SWITCH_URL" --code "$code" --name "$who-box" \
      --data-dir "$data" --secret-store file >/dev/null
    echo "enrolled $who-box"
  fi
  if ! pgrep -f -- "run --data-dir $data" >/dev/null; then
    nohup "$CONTROLLER_BIN" run --data-dir "$data" --env-file "$ENV_FILE" \
      >> "$WORK/logs/ctrl-$who.log" 2>&1 &
    echo $! > "$WORK/ctrl-$who.pid"
    echo "started $who-box (log $WORK/logs/ctrl-$who.log)"
  fi
done
controller_id() {
  local id state
  for _ in $(seq 60); do
    read -r id state < <(api "$WORK/jars/$1" GET /management/controllers \
      | jq -r --arg n "$1-box" '[.[] | select(.name==$n and .state=="online")][0] | "\(.id) \(.state)"')
    [ "$state" = online ] && { echo "$id"; return; }
    sleep 1
  done
  echo "$1-box didn't come online, see $WORK/logs/ctrl-$1.log" >&2
  return 1
}
DEVA_CTRL=$(controller_id deva)
DEVB_CTRL=$(controller_id devb)
echo "deva-box $DEVA_CTRL online, devb-box $DEVB_CTRL online"

step "Checkouts and Dev A's backend"
for who in deva devb; do
  [ -d "$WORK/$who/peerbridge" ] || git clone -q "$REPO" "$WORK/$who/peerbridge"
done
DEVA_REPO="$WORK/deva/peerbridge"
[ -x "$DEVA_REPO/.venv/bin/python" ] || python3 -m venv "$DEVA_REPO/.venv"
"$DEVA_REPO/.venv/bin/pip" install -q -r "$DEVA_REPO/sample/backend/requirements.txt"
if ! curl -fsS "127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1; then
  (
    cd "$DEVA_REPO"
    umask 002
    PATH="$DEVA_REPO/.venv/bin:$PATH" PEERBRIDGE_BACKEND_PORT="$BACKEND_PORT" \
      nohup sample/backend/run.sh >> "$WORK/logs/backend.log" 2>&1 &
    echo $! > "$WORK/backend.pid"
  )
  for _ in $(seq 30); do curl -fsS "127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
fi
curl -fsS "127.0.0.1:$BACKEND_PORT/health" >/dev/null || { echo "backend didn't start, see $WORK/logs/backend.log" >&2; exit 1; }
echo "backend on 127.0.0.1:$BACKEND_PORT"
SUDO=$([ "$(id -u)" -eq 0 ] && echo "" || echo sudo)
WANT_LOG="PEERBRIDGE_ACCESS_LOG=$DEVA_REPO/sample/backend/access.log"
if [ -f /opt/peerbridge/peerbridge.env ] && ! grep -qxF "$WANT_LOG" /opt/peerbridge/peerbridge.env && [ "${FORCE_WRAPPER:-}" != 1 ]; then
  echo "/opt/peerbridge is installed for another setup. Re-run with FORCE_WRAPPER=1 to replace it." >&2
  exit 1
fi
$SUDO "$DEVA_REPO/bin/install-wrapper.sh" "$DEVA_REPO/sample/backend/access.log" "$BACKEND_PORT"

step "Agents"
make_agent() { # owner name controller instructions-file directory
  local existing ins
  existing=$(api "$WORK/jars/$1" GET /management/agents | jq -r --arg n "$2" '[.[] | select(.name==$n)][0].agent_id // empty')
  if [ -n "$existing" ]; then echo "$existing"; return; fi
  # The instructions mention the agents by their default names.
  ins=$(sed -e "s/@backend-agent/@$BACKEND_NAME/g; s/@frontend-agent/@$FRONTEND_NAME/g" "$4")
  api "$WORK/jars/$1" POST /management/agents "$(jq -n \
    --arg name "$2" --arg ctrl "$3" --arg ins "$ins" --arg dir "$5" --arg model "${CODEX_MODEL:-}" \
    '{name:$name, description:"PeerBridge \($name)", controller_id:$ctrl, desired_state:"running",
      definition:({provider:"codex", instructions:$ins, directory:$dir}
                  + (if $model == "" then {} else {model:$model} end))}')" | jq -r .agent_id \
    || { echo "Couldn't create $2. Agent names are unique across the Switch server: if another account already has one, set AGENT_PREFIX." >&2; return 1; }
}
BACKEND_AGENT=$(make_agent deva "$BACKEND_NAME" "$DEVA_CTRL" "$DEVA_REPO/template/instructions/backend-agent.md" "$DEVA_REPO")
FRONTEND_AGENT=$(make_agent devb "$FRONTEND_NAME" "$DEVB_CTRL" "$WORK/devb/peerbridge/template/instructions/frontend-agent.md" "$WORK/devb/peerbridge")
echo "$BACKEND_NAME $BACKEND_AGENT, $FRONTEND_NAME $FRONTEND_AGENT"

step "Room and addressing"
ROOM=$(api "$WORK/jars/deva" GET /chats | jq -r '[.chats[] | select(.name=="api-sync")][0].roomId // empty')
if [ -z "$ROOM" ]; then
  ROOM=$(api "$WORK/jars/deva" POST /chats "$(jq -n --arg a "$BACKEND_AGENT" --arg b "$DEVB_ID" --arg r "$(python3 -c 'import uuid;print(uuid.uuid4())')" \
    '{name:"api-sync", agentIds:[$a], memberUserIds:[$b], requestId:$r}')" | jq -r .chat.roomId)
fi
# Every rule names users and agents explicitly: a missing dimension means anyone.
api "$WORK/jars/deva" PUT "/agents/$BACKEND_AGENT/addressing-policy" "$(jq -n --arg r "$ROOM" \
  '{policy:{rules:[{owner:true,users:[],agents:[]},{rooms:[$r],users:[],agents:"*"}]}}')" >/dev/null
# Dev B's agent lets the room's humans address it in api-sync only, so Dev A, the room's manager, can add it.
api "$WORK/jars/devb" PUT "/agents/$FRONTEND_AGENT/addressing-policy" "$(jq -n --arg r "$ROOM" \
  '{policy:{rules:[{owner:true,users:[],agents:[]},{rooms:[$r],users:"*",agents:[]}]}}')" >/dev/null
api "$WORK/jars/deva" POST "/chats/$ROOM/agents" "$(jq -n --arg a "$FRONTEND_AGENT" '{agentId:$a}')" >/dev/null 2>&1 \
  || echo "frontend-agent already in api-sync"
echo "api-sync $ROOM ready"

cat <<DONE

PeerBridge is set up. Sign in to Switch as Dev A and Dev B (passwords in $CREDS).
In api-sync:
  1. Dev A grants access once:
     @$BACKEND_NAME you can run allowlisted requests from agents in this room against my local backend for this session.
  2. Dev B asks:
     @$FRONTEND_NAME check POST /v2/checkout against Dev A
$([ -z "${OPENAI_API_KEY:-}" ] && echo "No OPENAI_API_KEY was set: give deva-box and devb-box a Codex login from Switch Console first.")
Allow backend-agent's Codex sandbox to escalate exactly /opt/peerbridge/bin/peerbridge-call.
Stop everything with: kill \$(cat $WORK/*.pid)
DONE
