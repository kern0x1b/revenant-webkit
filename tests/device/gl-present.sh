#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

HOST=${1:-$(ipconfig getifaddr en0 2>/dev/null)}
PORT=${TEST_PORT:-8899}
SHOT="$ROOT/tests/device/sweep-shots/gl-present.png"
mkdir -p "$(dirname "$SHOT")"

cd "$ROOT/tests/device"
python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null' EXIT
sleep 1

device_run 20 "killall MobileSafari 2>/dev/null" >/dev/null 2>&1
sleep 6
device_run 20 "uiopen 'http://$HOST:$PORT/gl-present.html?run=$RANDOM'" >/dev/null 2>&1
sleep 14
device_run 25 shot >/dev/null 2>&1
device_fetch /tmp/screenshot.png "$SHOT" >/dev/null 2>&1

red=$(python3 "$ROOT/tests/device/painted.py" "$SHOT" 255,0,0 2>/dev/null)
echo "webgl canvas on screen: ${red:-?}"
case "$red" in
    absent|""|"no shot"|"no PIL") exit 1 ;;
esac
