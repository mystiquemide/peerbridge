#!/usr/bin/env sh
# Installs a root-owned copy of peerbridge-call and its route allowlist into
# /opt/peerbridge, so backend-agent can run it outside its sandbox without
# being able to edit it.
#   sudo bin/install-wrapper.sh <path to Dev A's access.log> [backend port]
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <access.log path> [port]" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/peerbridge
LOG="$(realpath -m "$1")"
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
chmod 644 "$DEST/peerbridge.env"
echo "installed $DEST/bin/peerbridge-call (port $PORT, log $LOG, state $STATE)"
