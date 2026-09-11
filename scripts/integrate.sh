#!/usr/bin/env bash
# One upstream update, in the order that fails cheapest first.
#
#   scripts/integrate.sh upstream/webkitglib/2.54     take the series' own picks
#   scripts/integrate.sh upstream/main                the base change, when it is time
#   scripts/integrate.sh --no-merge                   just run the gates on what is here
set -uo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
E=$P/webkit-254
REF=${1:-}

step() { printf '\n=== %s\n' "$1"; }
die()  { printf '\nSTOPPED: %s\n' "$1"; exit 1; }

git -C "$E" config rerere.enabled true

if [ -n "$REF" ] && [ "$REF" != --no-merge ]; then
    step "merging $REF"
    remote=${REF%%/*}
    branch=${REF#*/}
    git -C "$E" fetch --filter=blob:none "$remote" "refs/heads/$branch:refs/remotes/$REF" || die "fetch failed"
    before=$(git -C "$E" rev-parse HEAD)
    git -C "$E" merge --no-edit "$REF" || die "merge conflicts left in webkit-254 - resolve, commit, then rerun with --no-merge"
    [ "$before" = "$(git -C "$E" rev-parse HEAD)" ] && echo "already up to date"
fi

step "carry manifest"
bash "$P/scripts/carry-check.sh" | grep -v '^ok' || true
bash "$P/scripts/carry-check.sh" >/dev/null || die "the tree no longer holds what this port depends on"

step "port delta"
bash "$P/scripts/port-delta.sh" 2>/dev/null | head -14

step "build"
ninja -C "$P/build-254-lto" || die "build failed"

step "symbols"
bash "$P/scripts/symbol-check.sh" || die "the symbol surface moved - check each line against the device"

step "host checks"
bash "$P/tests/run-tests.sh" host || die "host checks failed"

step "device"
if bash "$P/tools/device.sh" >/dev/null 2>&1 && bash -c ". $P/tools/device.sh; device_run 10 'echo up'" 2>/dev/null | grep -q up; then
    bash "$P/scripts/deploy-engine.sh" >/dev/null 2>&1 || die "deploy failed"
    bash "$P/tests/device/run.sh" | tail -3
else
    echo "no device - this integration is unverified and must not be shipped"
    exit 3
fi

printf '\nintegration green\n'
