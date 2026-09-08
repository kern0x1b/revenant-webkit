#!/usr/bin/env bash
# Push the built engine frameworks to /usr/lib/rev-fw on the device — the path the
# Safari-substitution loader points DYLD_FRAMEWORK_PATH at. Backs up first, then resprings.
#   ./deploy-engine.sh          (after layout-sys-frameworks.sh has staged dist/rev-sys-fw)
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"
REV=/usr/lib/rev-fw
SRC="$P/dist/rev-sys-fw"
[ -d "$SRC" ] || { echo "run scripts/layout-sys-frameworks.sh first" >&2; exit 1; }
device_run 12 "echo ok" >/dev/null || { echo "device unreachable" >&2; exit 1; }
echo "backing up current engine -> $REV.bak"
device_run 30 "mkdir -p $REV.bak; for fw in JavaScriptCore WebCore WebKit; do cp -f $REV/\$fw.framework/\$fw $REV.bak/\$fw 2>/dev/null || true; done"
for fw in JavaScriptCore WebCore WebKit; do
  device_copy "$SRC/$fw.framework/$fw" "$REV/$fw.framework/$fw"
done

# WebCore's media controls load resources (scripts, localized strings, button
# icons) from the framework bundle, so push those too, not just the binary.
if [ -d "$SRC/WebCore.framework/modern-media-controls" ] || [ -f "$SRC/WebCore.framework/Info.plist" ]; then
  ( cd "$SRC/WebCore.framework" && tar czf - Info.plist en.lproj modern-media-controls 2>/dev/null ) \
    | ( if [ -n "${DEVICE_PASSWORD:-}" ]; then sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "cd $REV/WebCore.framework && tar xzf - && chmod -R 755 modern-media-controls en.lproj 2>/dev/null";
        else ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "cd $REV/WebCore.framework && tar xzf - && chmod -R 755 modern-media-controls en.lproj 2>/dev/null"; fi )
fi

device_run 20 "chmod 755 $REV/*/* 2>/dev/null; echo installed"
echo "restarting Mobile Safari (no respring)"
device_run 15 "killall MobileSafari" 2>/dev/null || true
echo "done — verify the engine reports AppleWebKit/605"
