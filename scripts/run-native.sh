#!/usr/bin/env bash
# Install the built web app and launch it the way the system does.
#
# Running the executable over SSH as root never reaches the foreground, so
# UIApplicationMain sits there and the log stops at "entering UIApplicationMain".
# The app has to come up under SpringBoard, which means uicache then uiopen.
#
#   ./run-native.sh [label] [seconds-to-wait]
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

LABEL=${1:-run}
WAIT=${2:-90}
APP=$P/dist/Threads-Native.app
SCHEME=$(python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['CFBundleURLTypes'][0]['CFBundleURLSchemes'][0])
" "$APP/Info.plist")

device_run 40 'killall -9 Threads-Native 2>/dev/null; rm -rf /Applications/Threads-Native.app' >/dev/null 2>&1
tar -C "$(dirname "$APP")" -czf - "$(basename "$APP")" \
  | sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" \
      "root@$DEVICE_HOST" 'cd /Applications && tar xzf - && chmod +x /Applications/Threads-Native.app/Threads-Native' 2>/dev/null \
  || { echo "copy failed"; exit 1; }

# sshd on the device rate-limits after a burst of connections, and a refused
# login here produces an empty log that reads as "the page never loaded".
for attempt in 1 2 3; do
  device_run 20 'echo up' 2>/dev/null | grep -q up && break
  sleep 15
done

device_run $((WAIT + 120)) "
rm -f /tmp/native.log
su mobile -c uicache 2>/dev/null
sleep 4
uiopen $SCHEME://
sleep $WAIT
cat /tmp/native.log
" 2>/dev/null > "/tmp/native-$LABEL.log"

python3 - "$LABEL" "/tmp/native-$LABEL.log" <<'PY'
import sys, re
label, path = sys.argv[1], sys.argv[2]
start = bridge = None
for line in open(path, errors='replace'):
    m = re.match(r'(\d+\.\d+) (.*)', line)
    if not m:
        continue
    t, text = float(m.group(1)), m.group(2)
    if start is None:
        start = t
    if 'bridge installed' in text and bridge is None:
        bridge = t
print(f"{label}: bridge at {bridge - start:.1f}s" if bridge else f"{label}: bridge at -1.0s")
PY
