#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

SHOTS="$ROOT/tests/device/sweep-shots"
mkdir -p "$SHOTS"

sites=("$@")
if [ ${#sites[@]} -eq 0 ] && [ -r "$ROOT/tests/device/sweep-sites.txt" ]; then
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        sites+=("$line")
    done < "$ROOT/tests/device/sweep-sites.txt"
fi
if [ ${#sites[@]} -eq 0 ]; then
    cat >&2 <<'USAGE'
sweep.sh loads pages you name and reports what happened to the browser.

    tests/device/sweep.sh https://example.org/ [more...]
    tests/device/sweep.sh                       # reads tests/device/sweep-sites.txt

It ships with no list of its own on purpose: which sites this repository may
drive a browser at is the operator's call, not the repository's, and loading
somebody's site from an automated run is between the operator and that site's
terms. tests/device/sweep-sites.txt is gitignored for the same reason.
USAGE
    exit 2
fi

alive() { device_run 20 "killall -0 MobileSafari 2>/dev/null && echo 1 || echo 0" 2>/dev/null; }

printf "%-46s %-6s %-6s %-10s %s\n" SITE ALIVE CRASH PAINTED DIRTY
for url in "${sites[@]}"; do
    name=$(printf '%s' "$url" | sed 's|https\{0,1\}://||; s|[/?=&+]|_|g' | cut -c1-46)
    device_run 20 "killall MobileSafari 2>/dev/null; rm -f /tmp/rev-safari-stderr.log" >/dev/null 2>&1
    sleep 6
    device_run 20 "uiopen '$url'" >/dev/null 2>&1
    sleep 26

    live=$(alive)
    crash=$(device_run 20 "grep -c REVCRASH /tmp/rev-safari-stderr.log 2>/dev/null" 2>/dev/null)
    painted="-"
    dirty="-"
    if [ "$live" = "1" ]; then
        dirty=$(device_run 30 'P=$(revpid MobileSafari | sed -n "1s/ .*//p"); [ -n "$P" ] && revmem $P | sed -n "s/.*dirty=\([0-9.]*\) MB.*/\1 MB/p"' 2>/dev/null)
        device_run 25 shot >/dev/null 2>&1
        device_fetch /tmp/screenshot.png "$SHOTS/$name.png" >/dev/null 2>&1
        painted=$(python3 "$ROOT/tests/device/painted.py" "$SHOTS/$name.png" 2>/dev/null)
    fi
    printf "%-46s %-6s %-6s %-10s %s\n" "$url" "$live" "${crash:-?}" "${painted:-?}" "${dirty:-?}"
done
