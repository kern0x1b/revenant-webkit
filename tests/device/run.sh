#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

HOST=${1:-$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}
PORT=${TEST_PORT:-8899}
LOG=$(mktemp)
SERVER=
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -f "$LOG"' EXIT

cd "$ROOT/tests/device"
python3 -m http.server "$PORT" --bind 0.0.0.0 >"$LOG" 2>&1 &
SERVER=$!
cd "$ROOT"
sleep 1
if grep -q "Address already in use" "$LOG"; then
    echo "port $PORT is already serving something else; set TEST_PORT" >&2
    exit 2
fi

pages=(text-and-emoji gradients-and-blends image-draw-cost svg-image-filters web-platform)
token=0
ensure_bridge() {
    for attempt in 1 2 3; do
        token=$((token + 1))
        device_run 20 "uiopen 'http://$HOST:$PORT/warmup.html?token=$token'" >/dev/null 2>&1
        for _ in $(seq 1 8); do
            sleep 2
            grep -q "GET /warm-up-state?bridge=yes&token=$token" "$LOG" && return 0
        done
        echo "the tweak is not in this Safari; restarting it (attempt $attempt)" >&2
        device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
        sleep 12
    done
    echo "giving up on the tweak; the bridges it installs will read as missing" >&2
    return 1
}

device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
sleep 12

for page in "${pages[@]}"; do
    ensure_bridge
    device_run 20 "uiopen 'http://$HOST:$PORT/$page.html?run=$RANDOM'" >/dev/null 2>&1
    for _ in $(seq 1 22); do
        sleep 2
        grep -q "GET /verdicts?page=$page&results=.*final=1" "$LOG" && break
    done
done

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
