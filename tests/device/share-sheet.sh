#!/usr/bin/env bash
# Does navigator.share open the system share sheet, and does its promise settle?
#
#   tests/device/share-sheet.sh
#
# Two things make this awkward for run.sh and put it in a script of its own: the
# API is exposed to secure contexts only, and calling it needs a user gesture.
# The first is solved by serving through a reverse tunnel, so the page arrives at
# http://localhost, which is a secure context; the second by revtouch, which taps
# the button and later the sheet's Cancel.
#
# What it proves: the sheet appears (a screenshot, dark where the page was white)
# and cancelling rejects the promise with AbortError, which is what the
# specification asks for.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

PORT=${TEST_PORT:-8903}
SHOTS="$ROOT/tests/device/sweep-shots"
mkdir -p "$SHOTS"
LOG=$(mktemp)

cd "$ROOT/tests/device"
python3 -m http.server "$PORT" --bind 127.0.0.1 >"$LOG" 2>&1 &
SERVER=$!
TUNNEL=
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; [ -n "$TUNNEL" ] && kill "$TUNNEL" 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1

device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
sleep 4

if [ -n "${DEVICE_PASSWORD:-}" ]; then
    sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" -N \
        -R "$PORT:127.0.0.1:$PORT" "root@$DEVICE_HOST" &
else
    ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" -N -R "$PORT:127.0.0.1:$PORT" "root@$DEVICE_HOST" &
fi
TUNNEL=$!
sleep 3

device_run 20 "uiopen 'http://localhost:$PORT/share-sheet.html?run=$RANDOM'" >/dev/null 2>&1
sleep 10
verdict() { grep -o "GET /report?[^ ]*" "$LOG" | tail -1 | sed 's|GET /report?||; s|&r=.*||'; }
echo "on load:   $(python3 -c "import sys,urllib.parse; print(urllib.parse.unquote_plus(sys.argv[1]))" "$(verdict)")"

# The button fills the top of the page area; the sheet's Cancel sits at the bottom.
device_run 20 "/usr/bin/revtouch tap 160 110" >/dev/null 2>&1
sleep 6
device_run 25 shot >/dev/null 2>&1
device_fetch /tmp/screenshot.png "$SHOTS/share-sheet.png" >/dev/null 2>&1

device_run 20 "/usr/bin/revtouch tap 160 438" >/dev/null 2>&1
sleep 6
result=$(python3 -c "import sys,urllib.parse; print(urllib.parse.unquote_plus(sys.argv[1]))" "$(verdict)")
echo "after cancel: $result"
case "$result" in
    "rejected AbortError") exit 0 ;;
    *) exit 1 ;;
esac
