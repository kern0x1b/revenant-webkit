#!/usr/bin/env bash
# What the port is, in numbers, against the upstream release it sits on.
#
# The engine is a graft: the port branch has no real ancestry, so "how far have
# we drifted" cannot be read from git log. It can be read from the diff against
# the upstream branch the snapshot was cut from, which is what this prints.
#
#   ./port-delta.sh [upstream-ref]      default origin/webkitglib/2.54
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENGINE=$ROOT/webkit-254
BASE=${1:-origin/webkitglib/2.54}

git -C "$ENGINE" rev-parse --verify -q "$BASE" >/dev/null || {
    echo "no such ref: $BASE (fetch it first)" >&2
    exit 1
}

echo "port delta against $BASE"
git -C "$ENGINE" diff --shortstat "$BASE..HEAD"
echo

echo "by area:"
git -C "$ENGINE" diff --numstat "$BASE..HEAD" | awk '
    { split($3, p, "/"); key = p[1]"/"p[2]; add[key]+=$1; del[key]+=$2; files[key]++ }
    END { for (k in add) printf "  %-34s %5d files  +%-7d -%d\n", k, files[k], add[k], del[k] }' |
    sort -k2 -rn | head -12
echo

echo "kind of change:"
git -C "$ENGINE" diff --name-status "$BASE..HEAD" | awk '
    { kind[$1]++ }
    END { printf "  %d modified, %d added, %d deleted\n", kind["M"], kind["A"], kind["D"] }'

changed=$(mktemp); guarded=$(mktemp)
trap 'rm -f "$changed" "$guarded"' EXIT
git -C "$ENGINE" diff --name-only "$BASE..HEAD" -- Source | sort > "$changed"
git -C "$ENGINE" grep -l 'defined(WEBKIT_IOS6)' -- Source | sort > "$guarded"

echo
echo "how much of it announces itself:"
printf "  %5d files changed under Source\n" "$(wc -l < "$changed")"
printf "  %5d of them carry the WEBKIT_IOS6 guard\n" "$(comm -12 "$changed" "$guarded" | wc -l)"
printf "  %5d do not - these are the ones a re-graft has to be careful with\n" "$(comm -23 "$changed" "$guarded" | wc -l)"
echo
echo "  the unguarded ones, by area:"
comm -23 "$changed" "$guarded" | awk -F/ '{print $1"/"$2}' | sort | uniq -c | sort -rn |
    head -8 | awk '{printf "    %-32s %d\n", $2, $1}'
