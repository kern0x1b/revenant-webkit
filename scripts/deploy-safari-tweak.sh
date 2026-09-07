#!/usr/bin/env bash
# Deploy the Safari compat tweak + the RevWebKit Settings pane to the device.
# Native layout, no Theos:
#   dist/rev-safari-compat.dylib -> /Library/MobileSubstrate/DynamicLibraries/rev-safari.dylib
#   platform/safari/rev-safari.plist -> /Library/MobileSubstrate/DynamicLibraries/rev-safari.plist
#   dist/RevPrefs.bundle -> /Library/PreferenceBundles/RevPrefs.bundle
#   dist/RevWebKit.plist -> /Library/PreferenceLoader/Preferences/RevWebKit.plist
# MobileSubstrate injects the sibling .dylib into the bundles the .plist filters
# (com.apple.mobilesafari). PreferenceLoader shows the pane in Settings.
#
#   DEVICE_HOST=... ./deploy-safari-tweak.sh
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

DL=/Library/MobileSubstrate/DynamicLibraries
PB=/Library/PreferenceBundles
PL=/Library/PreferenceLoader/Preferences

[ -f "$P/dist/rev-safari-compat.dylib" ] || { echo "build scripts/build-safari-compat.sh first" >&2; exit 1; }
[ -x "$P/dist/RevPrefs.bundle/RevPrefs" ] || { echo "build scripts/build-prefs.sh first" >&2; exit 1; }

echo "pinging $DEVICE_HOST:$DEVICE_PORT"
device_run 12 "echo ok" >/dev/null || { echo "device unreachable" >&2; exit 1; }

device_run 20 "mkdir -p $DL $PB $PL"

device_copy "$P/dist/rev-safari-compat.dylib" "$DL/rev-safari.dylib"
device_copy "$P/platform/safari/rev-safari.plist" "$DL/rev-safari.plist"
device_copy "$P/dist/RevWebKit.plist" "$PL/RevWebKit.plist"

tar -C "$P/dist" -czf - RevPrefs.bundle \
  | ( if [ -n "${DEVICE_PASSWORD:-}" ]; then sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "rm -rf $PB/RevPrefs.bundle && cd $PB && tar xzf -";
      else ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "rm -rf $PB/RevPrefs.bundle && cd $PB && tar xzf -"; fi )

device_run 20 "chown -R root:wheel $DL/rev-safari.dylib $DL/rev-safari.plist $PB/RevPrefs.bundle $PL/RevWebKit.plist && chmod -R 755 $PB/RevPrefs.bundle && chmod 644 $DL/rev-safari.plist $PL/RevWebKit.plist && find $PB/RevPrefs.bundle -name '._*' -delete"

echo "installed. respringing"
device_run 15 "killall SpringBoard" || true
echo "done"
