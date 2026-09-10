#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")" && pwd)
cd "$P"
git submodule update --init --depth 1 webkit-254
echo "webkit-254 at $(git -C webkit-254 rev-parse --short HEAD) ($(du -sh webkit-254 | cut -f1))"
