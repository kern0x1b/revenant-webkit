#!/usr/bin/env python3
"""Measure how fast a WebGL canvas keeps drawing in Safari on the phone.

    tests/device/gl-frame-rate.py [HOST]
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness  # noqa: E402

device = harness.device


def main(argv):
    host = argv[0] if argv and argv[0] else harness.host_address()
    port = int(os.environ.get("TEST_PORT") or 8899)

    with harness.PageServer(port) as server:
        time.sleep(1)
        device.restart_safari(6)
        device.open_url(f"http://{host}:{port}/gl-frame-rate.html?run={harness.run_token()}")
        server.wait_for("320x480%3D", 40, 3)
        verdict = server.last_report()

    print(f"webgl frame rate: {verdict or 'nothing reported'}")
    return 0 if "320x480=" in verdict else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
