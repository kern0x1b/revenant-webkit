#!/usr/bin/env bash
# The engine source this port builds: upstream WebKit at a fixed commit, with
# this project's changes applied on top.
#
# Only Source/ and the build scripts are fetched, at depth 1 and without blobs
# for what is not checked out - a full clone is tens of gigabytes and none of
# that history is needed to compile.
set -e
P=$(cd "$(dirname "$0")" && pwd)
DIR="$P/webkit-254"
COMMIT="${1:-ad62a525b5bc3456a5fa38726bbe743e9da49283}"

[ -d "$DIR/.git" ] || git init -q "$DIR"
cd "$DIR"
git remote add origin https://github.com/WebKit/WebKit.git 2>/dev/null || true
git config core.sparseCheckout true
git sparse-checkout init --cone
git sparse-checkout set Source Tools/Scripts
git fetch --depth 1 --filter=blob:none origin "$COMMIT"
git checkout -q "$COMMIT"
echo "checked out ${COMMIT:0:12} ($(du -sh . | cut -f1))"

# The port's own changes. The series is disjoint and ordered, so it applies in
# one pass; regenerate it with tools/export-engine-patches.sh after editing the
# engine.
if [ -f "$P/patches/engine/new-files.tar" ]; then
    tar -xf "$P/patches/engine/new-files.tar"
    echo "added $(tar -tf "$P/patches/engine/new-files.tar" | grep -c . ) files this port introduces"
fi

for patch in "$P"/patches/engine/*.patch; do
    [ -e "$patch" ] || continue
    if git apply --check "$patch" 2>/dev/null; then
        git apply "$patch"
        echo "applied $(basename "$patch")"
    else
        echo "FAILED to apply $(basename "$patch") - the commit above may have moved" >&2
        exit 1
    fi
done
