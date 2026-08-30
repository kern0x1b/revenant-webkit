#!/usr/bin/env bash
# Export this port's changes to the engine as a patch series.
#
# webkit-254/ is an upstream checkout and is not tracked here: it is 2 GB of
# someone else's history. What belongs to this project is the difference, so it
# is written out per area, which keeps a change to the JIT out of the same file
# as a change to layout and makes the series readable.
#
# Regenerate after touching the engine:  tools/export-engine-patches.sh
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=$P/webkit-254
OUT=$P/patches/engine

if [ ! -d "$ENGINE/.git" ]; then
    echo "no engine checkout at $ENGINE - run fetch-source.sh first" >&2
    exit 1
fi

rm -f "$OUT"/*.patch
mkdir -p "$OUT"

emit() {
    local name=$1; shift
    git -C "$ENGINE" diff --binary -- "$@" > "$OUT/$name.patch"
    if [ ! -s "$OUT/$name.patch" ]; then
        rm -f "$OUT/$name.patch"
    else
        printf '%-28s %5s lines\n' "$name.patch" "$(wc -l < "$OUT/$name.patch" | tr -d ' ')"
    fi
}

# The areas are disjoint: each one excludes what an earlier one already carries,
# so the series applies cleanly in order and no hunk appears twice.
emit 01-build            Source/cmake ':(exclude)Source/cmake/nothing'
emit 02-wtf              Source/WTF
emit 03-javascriptcore   Source/JavaScriptCore
emit 04-webcore-platform Source/WebCore/platform Source/WebCore/PAL
emit 05-webcore-render   Source/WebCore/rendering Source/WebCore/style Source/WebCore/layout
emit 06-webcore-rest     Source/WebCore \
    ':(exclude)Source/WebCore/platform' ':(exclude)Source/WebCore/PAL' \
    ':(exclude)Source/WebCore/rendering' ':(exclude)Source/WebCore/style' \
    ':(exclude)Source/WebCore/layout'
emit 07-webkitlegacy     Source/WebKitLegacy
emit 08-rest             . ':(exclude)Source/cmake' ':(exclude)Source/WTF' \
    ':(exclude)Source/JavaScriptCore' ':(exclude)Source/WebCore' \
    ':(exclude)Source/WebKitLegacy'

# Files this port adds outright are not in the diff above.
git -C "$ENGINE" ls-files --others --exclude-standard \
    | tar -C "$ENGINE" -cf "$OUT/new-files.tar" -T - 2>/dev/null || true
echo "new-files.tar             $(git -C "$ENGINE" ls-files --others --exclude-standard | wc -l | tr -d ' ') files"
