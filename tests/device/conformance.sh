#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

TESTS_ROOT=${WEBGL_TESTS:-$HOME/Git/tools/webgl-conformance/sdk/tests}
if [ ! -d "$TESTS_ROOT/conformance" ]; then
    echo "no conformance suite at $TESTS_ROOT - see the header of this script" >&2
    exit 2
fi
[ $# -gt 0 ] || { echo "name at least one test, e.g. conformance/rendering/culling.html" >&2; exit 2; }

HOST=${HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null)}
PORT=${TEST_PORT:-8905}
LOG=$(mktemp)
list=$(printf '%s,' "$@" | sed 's/,$//')

cp "$ROOT/tests/device/conformance-runner.html" "$TESTS_ROOT/conformance-runner.html"
cd "$TESTS_ROOT"
python3 -m http.server "$PORT" --bind 0.0.0.0 >"$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; rm -f "$LOG" "$TESTS_ROOT/conformance-runner.html"' EXIT
sleep 1

device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
sleep 5
device_run 20 "uiopen 'http://$HOST:$PORT/conformance-runner.html?tests=$list&run=$RANDOM'" >/dev/null 2>&1

for _ in $(seq 1 90); do
    sleep 5
    grep -q "RUNNER%20DONE" "$LOG" && break
done

grep -o "GET /report?[^ ]*" "$LOG" | sed 's|GET /report?||; s|&r=.*||' \
    | python3 -c "import sys, urllib.parse; [print(urllib.parse.unquote_plus(line.strip())) for line in sys.stdin]"
