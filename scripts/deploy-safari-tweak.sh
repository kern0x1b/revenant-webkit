#!/usr/bin/env bash
# Deploy the Safari substitution + the RevWebKit Settings pane to the device.
# Native layout, no Theos. Two distinct dylibs with distinct jobs:
#
#   dist/RevSafari.dylib          -> /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib
#       the loader (build-safari-tweak.sh): re-execs Safari with our engine's DYLD_* set.
#   platform/safari/rev-safari.plist -> /Library/MobileSubstrate/DynamicLibraries/RevSafari.plist
#       the MobileSubstrate filter (com.apple.mobilesafari).
#   dist/rev-safari-compat.dylib  -> /usr/lib/rev-safari-compat.dylib
#       the compat/hook dylib (build-safari-compat.sh) the loader DYLD_INSERT's into the re-exec'd
#       Safari: iOS 6 ABI stubs, the bookmarks start page, WASM, and the space.kern0x1b.rev prefs.
#   dist/RevPrefs.bundle          -> /Library/PreferenceBundles/RevPrefs.bundle
#   dist/RevWebKit.plist          -> /Library/PreferenceLoader/Preferences/RevWebKit.plist
#
# Overwriting the loader with the compat dylib (or vice versa) drops the engine to the system one;
# they are not interchangeable. Each target is backed up before it is replaced.
#
#   DEVICE_HOST=... ./deploy-safari-tweak.sh
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/tools/device.sh"

DL=/Library/MobileSubstrate/DynamicLibraries
PB=/Library/PreferenceBundles
PL=/Library/PreferenceLoader/Preferences
COMPAT=/usr/lib/rev-safari-compat.dylib

[ -f "$P/dist/RevSafari.dylib" ]         || { echo "run scripts/build-safari-tweak.sh first" >&2; exit 1; }
[ -f "$P/dist/rev-safari-compat.dylib" ] || { echo "run scripts/build-safari-compat.sh first" >&2; exit 1; }
[ -x "$P/dist/RevPrefs.bundle/RevPrefs" ] || { echo "run scripts/build-prefs.sh first" >&2; exit 1; }

device_run 12 "echo ok" >/dev/null || { echo "device unreachable" >&2; exit 1; }
device_run 20 "mkdir -p $DL $PB $PL"

# Back each target up before replacing it.
device_run 20 "[ -f $DL/RevSafari.dylib ] && cp -f $DL/RevSafari.dylib $DL/RevSafari.dylib.bak || true"
device_run 20 "[ -f $COMPAT ] && cp -f $COMPAT $COMPAT.bak || true"

device_copy "$P/dist/RevSafari.dylib"         "$DL/RevSafari.dylib"
device_copy "$P/platform/safari/rev-safari.plist" "$DL/RevSafari.plist"
device_copy "$P/dist/rev-safari-compat.dylib" "$COMPAT"
device_copy "$P/dist/RevWebKit.plist"         "$PL/RevWebKit.plist"

tar -C "$P/dist" -czf - RevPrefs.bundle \
  | ( if [ -n "${DEVICE_PASSWORD:-}" ]; then sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "rm -rf $PB/RevPrefs.bundle && cd $PB && tar xzf -";
      else ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "rm -rf $PB/RevPrefs.bundle && cd $PB && tar xzf -"; fi )

device_run 25 "chown -R root:wheel $DL/RevSafari.dylib $DL/RevSafari.plist $COMPAT $PB/RevPrefs.bundle $PL/RevWebKit.plist; chmod 755 $DL/RevSafari.dylib $COMPAT; chmod -R 755 $PB/RevPrefs.bundle; chmod 644 $DL/RevSafari.plist $PL/RevWebKit.plist; find $PB/RevPrefs.bundle -name '._*' -delete"

echo "installed. respringing"
device_run 15 "killall SpringBoard" || true
echo "done"
