#!/usr/bin/env python3
"""Build JavaScriptCore for 32-bit ARM and run its own suites under emulation.

    tests/jsc32/build-and-test.py              build, then a smoke run
    tests/jsc32/build-and-test.py stress       and a slice of JSTests/stress

The stress run is a crash sweep, not a pass/fail run: many of those tests throw
on purpose and only JSC's own runner understands their //@ directives, so what
it asks is narrower - does the 32-bit engine take a signal on any of them.
STRESS_COUNT (default 150) sets how many.
"""
import os
import subprocess
import sys
from pathlib import Path

P = Path(__file__).resolve().parent.parent.parent
IMAGE = "jsc32"
BUILD = P / "build-jsc32"

CONFIGURE_AND_BUILD = '''
  if [ ! -f build.ninja ]; then
    cmake -S /src -B /build -G Ninja \\
      -DCMAKE_TOOLCHAIN_FILE=/armhf.cmake \\
      -DPORT=JSCOnly -DCMAKE_BUILD_TYPE=RelWithDebInfo \\
      -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \\
      -DENABLE_STATIC_JSC=ON -DUSE_THIN_ARCHIVES=OFF \\
      -DENABLE_API_TESTS=OFF -DENABLE_TOOLS=OFF -DENABLE_WEBASSEMBLY=OFF
  fi
  ninja jsc
'''

SMOKE = 'print("jsc " + (40 + 2) + " " + typeof 1n + " " + [1,2,3].map(x=>x*2).join(","))\n'


def container(*command):
    return ["docker", "run", "--rm", "-v", f"{P / 'webkit-254'}:/src:ro", "-v", f"{BUILD}:/build",
            "-w", "/build", IMAGE, *command]


def jsc(*args, quiet=False):
    sink = subprocess.DEVNULL if quiet else None
    command = container("qemu-arm-static", "-L", "/usr/arm-linux-gnueabihf", "/build/bin/jsc", *args)
    return subprocess.run(command, stdout=sink, stderr=sink).returncode


def main(argv):
    what = argv[0] if argv and argv[0] else "smoke"

    built = subprocess.run(["docker", "build", "-q", "-t", IMAGE, str(P / "tests" / "jsc32")],
                           stdout=subprocess.DEVNULL)
    if built.returncode:
        return built.returncode
    BUILD.mkdir(parents=True, exist_ok=True)

    compiled = subprocess.run(container("bash", "-euc", CONFIGURE_AND_BUILD))
    if compiled.returncode:
        return compiled.returncode

    print("=== the engine answers, on a 32-bit ARM build ===", flush=True)
    (BUILD / "smoke.js").write_text(SMOKE)
    smoke = jsc("/build/smoke.js")
    if smoke:
        return smoke

    if what == "stress":
        print("=== JSTests/stress, looking for crashes ===", flush=True)
        count = int(os.environ.get("STRESS_COUNT") or 150)
        stress = P / "webkit-254" / "JSTests" / "stress"
        tests = sorted(name for name in os.listdir(str(stress)) if name.endswith(".js") and not name.startswith("."))
        ran = crashed = 0
        for test in tests[:count]:
            code = jsc(f"/src/JSTests/stress/{test}", quiet=True)
            ran += 1
            if code >= 128:
                crashed += 1
                print(f"  signal {code - 128}: {test}", flush=True)
        print(f"stress: {ran} ran, {crashed} crashed")
        return 0 if crashed == 0 else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
