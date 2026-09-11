#!/usr/bin/env bash
set -uo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
B=${BUILD:-$P/build-254-lto}
PIN=$P/carry-symbols.txt
FW="JavaScriptCore WebCore WebKitLegacy"

collect() {
    for f in $FW; do
        bin=$B/$f.framework/$f
        [ -f "$bin" ] || { echo "no build: $bin" >&2; exit 2; }
        nm -u "$bin" | sed "s|^|undefined $f |"
        nm -gU "$bin" | awk '{print $NF}' | grep '^_OBJC_CLASS_\$_' | sed "s|^|class $f |"
    done | sort -u
}

if [ "${1:-}" = --pin ]; then
    { echo "# Symbols this port's frameworks depend on and provide, as of the last"
      echo "# build known to load on the device. scripts/symbol-check.sh compares a"
      echo "# fresh build against this."
      echo "#"
      echo "# undefined <framework> <symbol>  something iOS 6 must already have."
      echo "#   A new one means an upstream change reached for API this system may"
      echo "#   not have, and dyld kills the process at load with no crash log."
      echo "# class <framework> <symbol>      an Objective-C class UIKit and Safari"
      echo "#   link by name. Losing one is the same death, from the other side."
      collect
    } > "$PIN"
    echo "pinned $(grep -vc '^#' "$PIN") symbols"
    exit 0
fi

now=$(mktemp)
collect > "$now" || { echo "FAIL  no usable build to check - build first"; exit 2; }
grep -v '^#' "$PIN" | sort -u > "$now.pin"

new=$(comm -23 <(grep '^undefined ' "$now") <(grep '^undefined ' "$now.pin"))
gone=$(comm -13 <(grep '^class ' "$now") <(grep '^class ' "$now.pin"))
rm -f "$now" "$now.pin"

fail=0
if [ -n "$new" ]; then
    echo "FAIL  new undefined symbols - iOS 6 may not have these:"
    echo "$new" | sed 's/^/        /'
    fail=1
else
    echo "ok    no new undefined symbols"
fi
if [ -n "$gone" ]; then
    echo "FAIL  Objective-C classes no longer exported:"
    echo "$gone" | sed 's/^/        /'
    fail=1
else
    echo "ok    every pinned Objective-C class is still exported"
fi
[ $fail -eq 0 ] && echo "symbols intact" || echo "SYMBOLS CHANGED - check each against the device before deploying"
exit $fail
