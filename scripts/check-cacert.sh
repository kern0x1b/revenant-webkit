#!/usr/bin/env bash
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=$P/app/cacert.pem
EXPECTED=f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9
UPSTREAM=https://curl.se/ca/cacert.pem

actual=$(shasum -a 256 "$BUNDLE" | cut -d' ' -f1)
if [ "$actual" != "$EXPECTED" ]; then
    echo "app/cacert.pem is not the reviewed bundle" >&2
    echo "  expected $EXPECTED" >&2
    echo "  found    $actual" >&2
    exit 1
fi
echo "app/cacert.pem matches the reviewed bundle ($EXPECTED)"

if [ "${1:-}" = "--upstream" ]; then
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    curl -sfL -o "$tmp" "$UPSTREAM"
    remote=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
    if [ "$remote" = "$actual" ]; then
        echo "and it is byte-for-byte what $UPSTREAM serves today"
    else
        echo "$UPSTREAM now serves a different extract ($remote)."
        echo "A trust store changes only after somebody reads the change:"
        echo "  1. diff the two files and see which authorities moved"
        echo "  2. replace app/cacert.pem"
        echo "  3. put the new hash in EXPECTED above, in the same commit"
    fi
fi
