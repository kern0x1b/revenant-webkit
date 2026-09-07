#!/usr/bin/env bash
# Install RevWebViewHost.app and launch it under SpringBoard, then print
# /tmp/rev-webview-host.log - the direct-WebView equivalent of
# scripts/run-native.sh, which does this for the DYLD-substitution apps.
#
# Running the executable over SSH as root never reaches the foreground (no
# UIApplicationMain hand-off happens without SpringBoard), so this goes
# through uicache + uiopen like run-native.sh does.
#
#   bash scripts/run-app-rev.sh [seconds-to-wait]
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

WAIT=${1:-20}
APP=$P/dist/RevWebViewHost.app
SCHEME=revwebviewhost

echo "device: $DEVICE_HOST:$DEVICE_PORT"
for attempt in 1 2 3; do
  device_run 20 'echo up' 2>/dev/null | grep -q up && break
  sleep 5
done

device_run 40 'killall -9 RevWebViewHost 2>/dev/null; rm -rf /Applications/RevWebViewHost.app' >/dev/null 2>&1

echo "copying $(du -sh "$APP" | cut -f1)"
tar -C "$(dirname "$APP")" -czf - "$(basename "$APP")" \
  | sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" \
      "root@$DEVICE_HOST" 'cd /Applications && tar xzf - && chmod +x /Applications/RevWebViewHost.app/RevWebViewHost' 2>/dev/null \
  || { echo "copy failed"; exit 1; }

device_run $((WAIT + 60)) "
rm -f /tmp/rev-webview-host.log /tmp/rev-url.txt
${2:+echo '$2' > /tmp/rev-url.txt}
su mobile -c uicache >/dev/null 2>&1
sleep 4
uiopen $SCHEME://
sleep $WAIT
echo '--- rev-webview-host.log ---'
cat /tmp/rev-webview-host.log 2>&1
" 2>&1
