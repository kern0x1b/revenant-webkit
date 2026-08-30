#!/usr/bin/env bash
# Source/ of upstream Safari-603.1.30 and nothing else: no history, no tests.
set -e
TAG="${1:-Safari-603.1.30}"
DIR="webkit-603"
[ -d "$DIR/.git" ] || git init -q "$DIR"
cd "$DIR"
git remote add origin https://github.com/WebKit/WebKit.git 2>/dev/null || true
git config core.sparseCheckout true
git sparse-checkout init --cone
git sparse-checkout set Source Tools/Scripts
git fetch --depth 1 --filter=blob:none origin "refs/tags/$TAG:refs/tags/$TAG"
git checkout -q "$TAG"
echo "checked out $TAG ($(du -sh . | cut -f1))"
