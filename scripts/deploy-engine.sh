#!/usr/bin/env bash
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"
REV=/usr/lib/rev-fw
SRC="$P/dist/rev-sys-fw"
bash "$P/scripts/layout-sys-frameworks.sh" >/dev/null
device_run 12 "echo ok" >/dev/null || { echo "device unreachable" >&2; exit 1; }
echo "backing up current engine -> $REV.bak"
device_run 30 "mkdir -p $REV.bak; for fw in JavaScriptCore WebCore WebKit; do cp -f $REV/\$fw.framework/\$fw $REV.bak/\$fw 2>/dev/null || true; done"
for fw in JavaScriptCore WebCore WebKit; do
  device_copy "$SRC/$fw.framework/$fw" "$REV/$fw.framework/$fw"
done

if [ -d "$SRC/WebCore.framework/modern-media-controls" ] || [ -f "$SRC/WebCore.framework/Info.plist" ]; then
  ( cd "$SRC/WebCore.framework" && tar czf - $(ls | grep -v '^WebCore$') 2>/dev/null ) \
    | ( if [ -n "${DEVICE_PASSWORD:-}" ]; then sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "cd $REV/WebCore.framework && tar xzf - && chmod -R 755 . 2>/dev/null";
        else ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "cd $REV/WebCore.framework && tar xzf - && chmod -R 755 . 2>/dev/null"; fi )
fi

device_run 20 "chmod 755 $REV/*/* 2>/dev/null; echo installed"
echo "restarting Mobile Safari (no respring)"
device_run 15 "killall MobileSafari" 2>/dev/null || true
echo "done — verify the engine reports AppleWebKit/605"
