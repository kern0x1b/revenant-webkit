#!/usr/bin/env bash
# Load real sites on the device, one browser per site, and report what happened.
#
#   tests/device/sweep.sh [URL ...]
#
# Per site: whether the browser is still alive, whether the crash handler fired,
# how much of the viewport was painted, and the dirty memory the process holds.
# Screenshots land in tests/device/sweep-shots/ (gitignored) so a verdict that
# looks wrong can be looked at.
#
# The suite in run.sh measures the engine against numbers it can check itself;
# this measures it against the web as it is actually served, which is the only
# place some failures appear at all - an anti-bot challenge that needs an API the
# port does not have looks like a blank page and nothing else.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/tools/device.sh"

SHOTS="$ROOT/tests/device/sweep-shots"
mkdir -p "$SHOTS"

# Each of these reaches something different: a heavy news front page, a
# React application, a document site behind a challenge, a map, a dark theme.
DEFAULT_SITES=(
    https://www.bbc.com/news
    https://stackoverflow.com/questions
    https://www.reddit.com
    https://developer.mozilla.org/en-US/docs/Web/CSS
    https://mastodon.social/explore
    https://www.amazon.com
    https://caniuse.com
    https://www.openstreetmap.org
)
sites=("$@")
[ ${#sites[@]} -eq 0 ] && sites=("${DEFAULT_SITES[@]}")

# The device has no ps: liveness is a signal, not a process listing. A grep over
# a process list silently reports every process dead, which has been read as a
# crash more than once.
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
        # The device carries sed, grep and its own tools and nothing else - no
        # head, cut, awk or wc - so the pid and the number come out with sed.
        dirty=$(device_run 30 'P=$(revpid MobileSafari | sed -n "1s/ .*//p"); [ -n "$P" ] && revmem $P | sed -n "s/.*dirty=\([0-9.]*\) MB.*/\1 MB/p"' 2>/dev/null)
        device_run 25 shot >/dev/null 2>&1
        device_fetch /tmp/screenshot.png "$SHOTS/$name.png" >/dev/null 2>&1
        painted=$(python3 "$ROOT/tests/device/painted.py" "$SHOTS/$name.png" 2>/dev/null)
    fi
    printf "%-46s %-6s %-6s %-10s %s\n" "$url" "$live" "${crash:-?}" "${painted:-?}" "${dirty:-?}"
done
