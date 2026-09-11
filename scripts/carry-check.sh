#!/usr/bin/env bash
set -uo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
E=$P/webkit-254
M=${1:-$P/carry-manifest.txt}
fail=0

report() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }

while read -r kind a b; do
    case "$kind" in
        ''|'#') continue ;;
        file)
            [ -f "$E/$a" ] && report ok "$a" || report FAIL "missing: $a"
            ;;
        grep)
            if [ -f "$E/$a" ] && grep -qF -- "$b" "$E/$a"; then
                report ok "$a contains $b"
            else
                report FAIL "$a no longer contains: $b"
            fi
            ;;
        set)
            if grep -qF -- "$b" "$P/$a"; then
                report ok "$a keeps $b"
            else
                report FAIL "$a lost: $b"
            fi
            ;;
        guard)
            n=$(git -C "$E" grep -l WEBKIT_IOS6 -- "$a" 2>/dev/null | grep -c . || true)
            if [ "${n:-0}" -ge "$b" ]; then
                report ok "$a carries the guard in $n files (floor $b)"
            else
                report FAIL "$a carries the guard in only $n files, floor is $b"
            fi
            ;;
        *)
            report FAIL "unknown directive: $kind"
            ;;
    esac
done < "$M"

[ $fail -eq 0 ] && echo "carry intact" || echo "CARRY BROKEN - the tree no longer holds what this port depends on"
exit $fail
