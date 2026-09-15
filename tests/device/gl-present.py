#!/usr/bin/env python3
"""Check that a WebGL canvas the GPU drew actually reaches the screen.

    tests/device/gl-present.py [HOST]
"""
import os
import sys
import time

import harness

device = harness.device


def main(argv):
    host = argv[0] if argv and argv[0] else harness.host_address()
    port = int(os.environ.get("TEST_PORT") or 8899)
    harness.SHOTS.mkdir(parents=True, exist_ok=True)

    with harness.PageServer(port):
        time.sleep(1)
        device.restart_safari(6)
        device.open_url(f"http://{host}:{port}/gl-present.html?run={harness.run_token()}")
        time.sleep(14)
        shot = harness.screenshot("gl-present.png")

    red = harness.painted(shot, "255,0,0")
    print(f"webgl canvas on screen: {red or '?'}")
    return 1 if red in ("absent", "", "no shot", "no PIL") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
