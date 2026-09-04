#!/usr/bin/env bash
# Compare two engine builds on a page that does not change between runs.
#
# The live site cannot answer "is this build faster". Its content varies per
# load, resident memory tracks that content at r = 0.98, and it rate-limits;
# the same configuration measured 29, 107 and 122 stalls across three soaks.
# This drives tests/scrollbench.html from the device's own filesystem instead:
# same DOM every time, same script load, no network.
#
#   ./bench-native.sh <label> [flicks]
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

LABEL=${1:?usage: bench-native.sh <label> [flicks] [posts]}
FLICKS=${2:-12}
POSTS=${3:-400}
HEAP=${4:-0}

for attempt in 1 2 3; do
  device_run 20 'echo up' 2>/dev/null | grep -q up && break
  sleep 15
done

device_copy "$P/tests/scrollbench.html" /tmp/scrollbench.html >/dev/null 2>&1 || {
    echo "$LABEL: could not copy the page"; exit 1; }

device_run 40 'killall -9 Threads-Native 2>/dev/null
touch /tmp/native-harness /tmp/native-watch-stalls
rm -f /tmp/native.log /tmp/native-stall.log /tmp/native-eval-result' >/dev/null 2>&1

tar -C "$P/dist" -czf - Threads-Native.app 2>/dev/null | sshpass -p "$DEVICE_PASSWORD" \
  ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" \
  'rm -rf /Applications/Threads-Native.app && cd /Applications && tar xzf - && chmod +x /Applications/Threads-Native.app/Threads-Native' 2>/dev/null

device_run 90 'su mobile -c uicache 2>/dev/null; sleep 4; uiopen threadsnative://; sleep 45
echo "file:///tmp/scrollbench.html?posts='"$POSTS"'&heap='"$HEAP"'" > /tmp/native-url
sleep 30' >/dev/null 2>&1

# The page reports its own build cost, so a run that never got there is visible
# rather than being averaged in as a fast one.
READY=$("$P/scripts/probe-native.sh" 'window.benchStop ? "ready" : "not-loaded"' 2>/dev/null | tail -1)
if [ "$READY" != "ready" ]; then
    echo "$LABEL: page did not load (got '$READY') - discard"; exit 1
fi

"$P/scripts/probe-native.sh" 'window.benchStart()' >/dev/null 2>&1
device_run $((FLICKS * 4 + 60)) "echo '400,$FLICKS' > /tmp/native-flick; sleep $((FLICKS * 3 + 15))" >/dev/null 2>&1

FLICKED=$(device_run 30 'grep -ac flicking /tmp/native.log' 2>/dev/null | tr -d '[:space:]')
RESULT=$("$P/scripts/probe-native.sh" 'window.benchStop()' 2>/dev/null | tail -1)
STALLS=$(device_run 30 'grep -ac stalled /tmp/native-stall.log 2>/dev/null' 2>/dev/null | tr -d '[:space:]')

# A run where the flick never fired measures an idle app and must not be read as
# a good result - that mistake has been made here already.
if [ "${FLICKED:-0}" = "0" ]; then
    echo "$LABEL: no flicks executed - discard"; exit 1
fi

echo "$LABEL: posts=$POSTS heap=$HEAP flicks=$FLICKED stalls=${STALLS:-?} $RESULT"
