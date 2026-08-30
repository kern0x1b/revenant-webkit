#!/usr/bin/env bash
# Drive the build repeatedly, reporting the first distinct error each round.
P=$(cd "$(dirname "$0")/.." && pwd)
cd "$P"
for round in $(seq 1 "${ROUNDS:-1}"); do
    if ./build-webkit.sh > /tmp/auto_$round.log 2>&1; then
        echo "ROUND $round: BUILD OK"
        exit 0
    fi
    echo "ROUND $round:"
    tail -3 /tmp/auto_$round.log | head -2
    for t in bmalloc WTF JavaScriptCore PAL WebCoreJSBindings WebCoreDOMAndRendering \
             WebCoreStyle WebCoreInspector WebCoreAVFoundation WebCore WebKitLegacy; do
        [ -f /tmp/wk_$t.log ] || continue
        errs=$(grep "error:" /tmp/wk_$t.log 2>/dev/null | sed 's|.*/webkit-trunk/||;s|.*/build-cocoa/||;s|.*/sdks/||;s/:[0-9]*:[0-9]*:/:/' | sort -u | head -6)
        [ -n "$errs" ] && { echo "--- $t"; echo "$errs"; break; }
    done
    exit 1
done
