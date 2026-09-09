#!/usr/bin/env bash
# Run the device checks and print their verdicts.
#
#   tests/device/run.sh [HOST_IP]
#
# The pages report themselves by requesting /report?..., and this reads the
# verdicts out of the serving HTTP server's own request log - the device cannot
# be asked for its DOM, and a screenshot is not a measurement.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

HOST=${1:-$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}
PORT=${TEST_PORT:-8899}
LOG=$(mktemp)
SERVER=
# Kill the server itself, not the shell that started it: a subshell's trap left
# the python process holding the port, and the next run then read an empty log
# while the device was happily served by the previous run's server.
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -f "$LOG"' EXIT

cd "$ROOT/tests/device"
python3 -m http.server "$PORT" --bind 0.0.0.0 >"$LOG" 2>&1 &
SERVER=$!
cd "$ROOT"
sleep 1
# A port already in use means the device would be served someone else's files
# and every verdict would go missing, which is not a failure worth debugging
# twice.
if grep -q "Address already in use" "$LOG"; then
    echo "port $PORT is already serving something else; set TEST_PORT" >&2
    exit 2
fi

pages=(text-and-emoji gradients-and-blends image-draw-cost svg-image-filters)
for page in "${pages[@]}"; do
    # A fresh browser per page. Asking a busy Safari to open another URL is
    # unreliable here - the first page always reported and the later ones often
    # did not, which looked like a flaky engine and was a flaky runner.
    device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
    sleep 6
    device_run 20 "uiopen 'http://$HOST:$PORT/$page.html?run=$RANDOM'" >/dev/null 2>&1
    for _ in $(seq 1 22); do
        sleep 2
        grep -q "GET /verdicts?page=$page&results=.*final=1" "$LOG" && break
    done
done

# A page that reported nothing is a failure, not an absence: silence used to
# read as "0 failed".
missing=0
for page in "${pages[@]}"; do
    if ! grep -q "GET /verdicts?page=$page" "$LOG"; then
        echo "MISSING $page reported nothing"
        missing=1
    elif ! grep -q "GET /verdicts?page=$page&results=.*final=1" "$LOG"; then
        echo "PARTIAL $page stopped before its end - the verdicts below are what it reached"
        missing=1
    fi
done

grep -o 'GET /verdicts?[^ ]*' "$LOG" | python3 "$ROOT/tests/device/verdicts.py"
status=$?
[ "$missing" -eq 0 ] && exit "$status"
exit 1
