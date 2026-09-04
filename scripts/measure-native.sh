#!/usr/bin/env bash
# One command for the whole picture: launch, settle, scroll, and report.
#
# Every number this prints has been got wrong at least once by doing it by
# hand, so the point of the script is that the mistakes are made once here
# rather than differently every time:
#
#   - the app is launched under SpringBoard, never by running the binary over
#     SSH, which never reaches the foreground and looks exactly like a hang;
#   - each script evaluation carries a unique stamp, because two evaluations
#     inside the same second look like one and the second read returns the
#     previous answer;
#   - the device's sshd rate-limits after a burst, and a refused login gives an
#     empty log that reads as "the page never loaded", so connections retry;
#   - the probe files are cleared first, so a stale file cannot be reported as
#     this run's result.
#
#   ./measure-native.sh <label> [settle-seconds] [flicks]
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

LABEL=${1:?usage: measure-native.sh <label> [settle] [flicks]}
SETTLE=${2:-80}
FLICKS=${3:-10}
OUT=/tmp/measure-$LABEL

for attempt in 1 2 3; do
  device_run 20 'echo up' 2>/dev/null | grep -q up && break
  sleep 15
done

# The probe files are read once, at startup, so they have to exist before the
# launch rather than before the scroll. Getting this wrong reports zero stalls
# and no frame-rate windows on a run that had plenty of both.
device_run 30 'touch /tmp/native-harness /tmp/native-watch-stalls /tmp/native-fps /tmp/native-sched-log
rm -f /tmp/native-stall.log /tmp/native-stderr.log /tmp/native-shot-*.png' >/dev/null 2>&1

"$P/scripts/run-native.sh" "$LABEL" "$SETTLE" | tail -1

PROBE='["y="+(window.pageYOffset||0),"els="+document.getElementsByTagName("*").length,"imgs="+document.images.length,"scrollH="+document.body.scrollHeight,"txt="+document.body.innerText.length,"cookie="+document.cookie.length].join(" | ")'
echo "settled:  $("$P/scripts/probe-native.sh" "$PROBE" 2>/dev/null | tail -1)"

device_run $((FLICKS * 6 + 120)) "
echo '400,$FLICKS' > /tmp/native-flick
sleep $((FLICKS * 4 + 20))
touch /tmp/native-shot
sleep 10
" >/dev/null 2>&1

echo "scrolled: $("$P/scripts/probe-native.sh" "$PROBE" 2>/dev/null | tail -1)"

device_run 90 "
echo '--- stalls over 400 ms ---'
grep -ac stalled /tmp/native-stall.log 2>/dev/null || echo 0
echo '--- frame rate windows ---'
grep -a uifps /tmp/native.log 2>/dev/null
echo '--- peak resident ---'
grep -a 'resident' /tmp/native.log 2>/dev/null
" 2>/dev/null > "$OUT.raw"

python3 - "$LABEL" "$OUT.raw" <<'PY'
import re, sys, statistics
label, path = sys.argv[1], sys.argv[2]
text = open(path, errors='replace').read()

stalls = re.search(r'stalls over 400 ms ---\s*\n(\d+)', text)
print(f"stalls>400ms: {stalls.group(1) if stalls else 'n/a'}")

fps = [float(m) for m in re.findall(r'uifps[^0-9]*([0-9]+\.?[0-9]*)', text)]
if fps:
    # The distribution is bimodal: an idle window sits at 60 and a scrolling
    # window at single digits, so the median mostly reports how much of the run
    # was idle. Everything above 45 is treated as idle and reported separately;
    # what the reader feels is the low tail.
    fps.sort()
    scrolling = [f for f in fps if f <= 45]
    idle = len(fps) - len(scrolling)
    if scrolling:
        p10 = scrolling[max(0, len(scrolling) // 10 - 1)]
        print(f"fps while scrolling: median {statistics.median(scrolling):.1f}  "
              f"p10 {p10:.1f}  min {scrolling[0]:.1f}  n={len(scrolling)} ({idle} idle windows ignored)")
    else:
        print(f"fps: all {len(fps)} windows idle, nothing measured")
else:
    print("fps: no windows logged")

mem = [float(m) for m in re.findall(r'resident[^0-9]*([0-9]+\.?[0-9]*)', text)]
if mem:
    print(f"resident MB: median {statistics.median(mem):.1f}  max {max(mem):.1f}  n={len(mem)}")
PY

if sshpass -p "$DEVICE_PASSWORD" scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" \
    "root@$DEVICE_HOST:/tmp/native-shot-7.png" "$OUT.png" 2>/dev/null; then
    echo "screenshot: $OUT.png"
fi
