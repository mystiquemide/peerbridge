#!/usr/bin/env sh
# Installs a root-owned copy of peerbridge-call and its route allowlist into
# /opt/peerbridge, so backend-agent can run it outside its sandbox without
# being able to edit it.
#   sudo bin/install-wrapper.sh <path to Dev A's access.log> [backend port]
# To check every request's sender in Switch, also set, in the environment:
#   PEERBRIDGE_SWITCH_URL, PEERBRIDGE_ROOM_ID, PEERBRIDGE_AGENT_ID,
#   PEERBRIDGE_VERIFIER_EMAIL, PEERBRIDGE_VERIFIER_PASSWORD_FILE
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <access.log path> [port]" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/peerbridge
case "$1" in /*) LOG="$1" ;; *) LOG="$PWD/$1" ;; esac  # kept as given: an agent may see the log under another path
PORT="${2:-8001}"
install -d -o root -g root -m 755 "$DEST" "$DEST/bin"
install -o root -g root -m 755 "$SRC/bin/peerbridge-call" "$DEST/bin/peerbridge-call"
install -o root -g root -m 644 "$SRC/peerbridge.routes" "$DEST/peerbridge.routes"
STATE="${PEERBRIDGE_STATE_DIR:-$(dirname "$LOG")/.peerbridge}"
cat > "$DEST/peerbridge.env" <<CONF
PEERBRIDGE_BACKEND_PORT=$PORT
PEERBRIDGE_ROUTES=$DEST/peerbridge.routes
PEERBRIDGE_ACCESS_LOG=$LOG
PEERBRIDGE_STATE_DIR=$STATE
CONF
for key in PEERBRIDGE_SWITCH_URL PEERBRIDGE_ROOM_ID PEERBRIDGE_AGENT_ID PEERBRIDGE_VERIFIER_EMAIL PEERBRIDGE_VERIFIER_PASSWORD_FILE; do
  eval "value=\${$key:-}"
  [ -n "$value" ] && echo "$key=$value" >> "$DEST/peerbridge.env"
done
chmod 644 "$DEST/peerbridge.env"
if [ -n "${PEERBRIDGE_SWITCH_URL:-}" ]; then MODE="checks senders in Switch room $PEERBRIDGE_ROOM_ID"; else MODE="no sender check"; fi
echo "installed $DEST/bin/peerbridge-call (port $PORT, log $LOG, state $STATE, $MODE)"
