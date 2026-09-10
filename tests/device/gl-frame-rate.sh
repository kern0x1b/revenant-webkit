#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

HOST=${1:-$(ipconfig getifaddr en0 2>/dev/null)}
PORT=${TEST_PORT:-8899}
LOG=$(mktemp)

cd "$ROOT/tests/device"
python3 -m http.server "$PORT" --bind 0.0.0.0 >"$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1

device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
sleep 6
device_run 20 "uiopen 'http://$HOST:$PORT/gl-frame-rate.html?run=$RANDOM'" >/dev/null 2>&1

for _ in $(seq 1 40); do
    sleep 3
    grep -q "320x480%3D" "$LOG" && break
done

verdict=$(grep -o "GET /report?[^ ]*" "$LOG" | tail -1 | sed 's|GET /report?||; s|&r=.*||' \
    | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote_plus(sys.stdin.read().strip()))")
echo "webgl frame rate: ${verdict:-nothing reported}"

case "$verdict" in
    *320x480=*) exit 0 ;;
    *) exit 1 ;;
esac
