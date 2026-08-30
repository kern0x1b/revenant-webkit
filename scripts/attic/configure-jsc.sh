#!/usr/bin/env bash
# JavaScriptCore alone, armv7, against the iOS 10.3 SDK. Milestone 1: the
# smallest piece of WebKit that proves the toolchain works at all.
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$HERE/build-jsc"
cd "$HERE/build-jsc"
cmake -DPORT=JSCOnly -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$HERE/ios6-armv7.cmake" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DPYTHON_EXECUTABLE=/usr/bin/python3 \
      -DENABLE_STATIC_JSC=ON -DUSE_SYSTEM_MALLOC=ON \
      -DENABLE_FTL_JIT=OFF -DENABLE_API_TESTS=OFF -DENABLE_TOOLS=OFF \
      "$HERE/webkit-603"
echo "configured; now: cd build-jsc && make -j8 JavaScriptCore"
