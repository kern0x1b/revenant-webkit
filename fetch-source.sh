#!/usr/bin/env bash
# The engine source this port builds: webkit-254 is a real git submodule now,
# tracking the ios6-armv7 branch of kern0x1b/WebKit (a fork of upstream WebKit
# carrying this project's changes as real commits) - see .gitmodules.
#
# Before this, the port was upstream at a fixed commit with patches/engine/
# applied on top by hand; that series is no longer maintained.
set -e
P=$(cd "$(dirname "$0")" && pwd)
cd "$P"
git submodule update --init --depth 1 webkit-254
echo "webkit-254 at $(git -C webkit-254 rev-parse --short HEAD) ($(du -sh webkit-254 | cut -f1))"
