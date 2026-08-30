#!/usr/bin/env bash
# Build everything, in the order the pieces need each other.
#
# The steps are separate scripts under scripts/ because each takes long enough
# that repeating one of them alone is the normal case. This runs them all.
#
#   ./build.sh                      the engine and the Threads application
#   ./build.sh platform/apps/x.json some other web app
set -e
P=$(cd "$(dirname "$0")" && pwd)
APP=${1:-platform/apps/threads.json}

[ -d "$P/webkit-254" ] || { echo "no engine source - run ./fetch-source.sh first" >&2; exit 1; }

step() { printf '\n=== %s ===\n' "$1"; }

step "libc++ for armv7";        "$P/scripts/build-libcxx.sh"
step "ICU";                     "$P/scripts/build-icu.sh"
step "OpenSSL";                 "$P/scripts/build-openssl.sh"
step "compatibility library";   "$P/scripts/build-compat.sh"
step "configure the engine";    "$P/scripts/configure-engine.sh"
step "engine";                  (cd "$P/build-254-lto" && ninja WebCore WebKitLegacy JavaScriptCore)
step "application";             "$P/scripts/build-app-lto.sh" "$APP"

echo
echo "built dist/$(basename "${APP%.json}" | tr '[:lower:]' '[:upper:]' | cut -c1)$(basename "${APP%.json}" | cut -c2-)-Native.app"
