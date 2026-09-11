#!/usr/bin/env bash
# Build JavaScriptCore for 32-bit ARM and run its own suites under emulation.
#
#   tests/jsc32/build-and-test.sh              build, then a smoke run
#   tests/jsc32/build-and-test.sh stress       and a slice of JSTests/stress
set -euo pipefail
P=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=jsc32
BUILD=$P/build-jsc32
what=${1:-smoke}

docker build -q -t "$IMAGE" "$P/tests/jsc32" >/dev/null
mkdir -p "$BUILD"

docker run --rm -v "$P/webkit-254:/src:ro" -v "$BUILD:/build" -w /build "$IMAGE" bash -euc '
  if [ ! -f build.ninja ]; then
    cmake -S /src -B /build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/armhf.cmake \
      -DPORT=JSCOnly -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \
      -DENABLE_STATIC_JSC=ON -DUSE_THIN_ARCHIVES=OFF \
      -DENABLE_API_TESTS=OFF -DENABLE_TOOLS=OFF
  fi
  ninja jsc
'

run() { docker run --rm -v "$P/webkit-254:/src:ro" -v "$BUILD:/build" -w /build "$IMAGE" \
        qemu-arm-static -L /usr/arm-linux-gnueabihf /build/bin/jsc "$@"; }

echo "=== the engine answers, on a 32-bit ARM build ==="
echo 'print("jsc " + (40 + 2) + " " + typeof 1n + " " + [1,2,3].map(x=>x*2).join(","))' > "$BUILD/smoke.js"
run /build/smoke.js

if [ "$what" = stress ]; then
  # A crash sweep, not a pass/fail run: many of these tests throw on purpose,
  # and only JSC's own runner understands their //@ directives. What is being
  # asked here is narrower and still worth asking - does the 32-bit engine take
  # a signal on any of them.
  echo "=== JSTests/stress, looking for crashes ==="
  ran=0; crashed=0
  for t in $(cd "$P/webkit-254/JSTests/stress" && ls *.js | head -"${STRESS_COUNT:-150}"); do
    run "/src/JSTests/stress/$t" >/dev/null 2>&1
    code=$?
    ran=$((ran+1))
    if [ $code -ge 128 ]; then crashed=$((crashed+1)); echo "  signal $((code-128)): $t"; fi
  done
  echo "stress: $ran ran, $crashed crashed"
  [ $crashed -eq 0 ]
fi
