#!/usr/bin/env bash
# Load a list of sites through the headless harness on the device and print one
# row each: how long the load took, how much memory it cost, how much of the
# screen was painted, and whether the process survived.
set -u
D=${DEVICE_HOST:-127.0.0.1}
SSHO="-o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SETTLE="${SETTLE:-25}"

printf '%-34s %8s %8s %8s %9s %6s\n' site commit finish peakMB painted status
for url in "$@"; do
    out=$(timeout 400 $DEVICE_SSH -n $SSHO root@$D \
        "/Applications/LegacyBrowser.app/headless '$url' $SETTLE > /tmp/bench.log 2>&1; echo rc=\$?; grep -a 'load committed\|load finished\|footprint\|pixels painted\|js errors' /tmp/bench.log" 2>/dev/null)
    commit=$(printf '%s' "$out" | sed -n 's/.*load committed *\([0-9.]*\) s.*/\1/p' | sed -n 1p)
    finish=$(printf '%s' "$out" | sed -n 's/.*load finished *\([0-9.]*\) s.*/\1/p' | sed -n 1p)
    peak=$(printf '%s' "$out"   | sed -n 's/.*footprint: *\([0-9.]*\) MB.*/\1/p' | sort -rn | sed -n 1p)
    painted=$(printf '%s' "$out"| sed -n 's/.*snapshot: \([0-9]*\) of \([0-9]*\) pixels painted.*/\1/p' | sed -n 1p)
    total=$(printf '%s' "$out"  | sed -n 's/.*snapshot: [0-9]* of \([0-9]*\) pixels painted.*/\1/p' | sed -n 1p)
    rc=$(printf '%s' "$out"     | sed -n 's/^rc=\(.*\)/\1/p' | sed -n 1p)
    pct="-"
    [ -n "${painted:-}" ] && [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ] 2>/dev/null && pct=$(( painted * 100 / total ))%
    printf '%-34s %8s %8s %8s %9s %6s\n' \
        "$(printf '%s' "$url" | sed 's|https\?://||;s|/$||' | cut -c1-34)" \
        "${commit:--}" "${finish:--}" "${peak:--}" "$pct" "${rc:--}"
done
