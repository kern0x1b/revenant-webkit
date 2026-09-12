#!/usr/bin/env bash
# Lists files whose port adaptations thinned out against a reference branch.
#
#   scripts/carry-audit.sh [ref] [path ...]
#
# The count of port markers per file is compared with the same file on the
# reference branch; a file that carries fewer markers than the reference is
# either an upstream refactor or a carry that was dropped when the file was
# taken from trunk, and every one of them is worth reading before a release.
set -uo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
E=$P/webkit-254
REF=${1:-main}
shift || true
paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=(Source/WebCore Source/WebKitLegacy Source/JavaScriptCore Source/WTF)
MARKERS='WEBKIT_IOS6|USE\(JSVALUE64\)|JSVALUE32_64|CPU\(ARM_THUMB2\)|payloadGPR|tagGPR'

cd "$E" || exit 2
gaps=0
while read -r f; do
    [ -f "$f" ] || continue
    a=$(git show "$REF:$f" 2>/dev/null | grep -cE "$MARKERS")
    [ "$a" -gt 0 ] || continue
    b=$(grep -cE "$MARKERS" "$f")
    if [ "$b" -lt "$a" ]; then
        printf '%-4s %s (%s has %s, here %s)\n' "-$((a-b))" "$f" "$REF" "$a" "$b"
        gaps=$((gaps+1))
    fi
done < <(git ls-tree -r --name-only "$REF" -- "${paths[@]}" | grep -E '\.(cpp|h|mm|m|asm)$')
echo "$gaps files carry fewer markers than $REF"
