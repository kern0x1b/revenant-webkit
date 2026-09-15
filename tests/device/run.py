#!/usr/bin/env python3
"""Load every device test page in Safari on the phone and print each verdict.

    tests/device/run.py [HOST]
    TEST_PORT=8898 tests/device/run.py
"""
import os
import re
import subprocess
import sys
import time

import harness

device = harness.device

PAGES = ["text-and-emoji", "gradients-and-blends", "image-draw-cost", "svg-image-filters", "web-platform", "websocket"]


def final_pattern(page):
    return "^" + re.escape(f"GET /verdicts?page={page}&results=") + "[^&]+.*final=1"


def reported_pattern(page):
    return re.escape(f"GET /verdicts?page={page}")


def warm_pattern(token):
    return re.escape(f"GET /warm-up-state?bridge=yes&token={token}")


class Bridge:
    def __init__(self, server, base):
        self.server = server
        self.base = base
        self.token = 0

    def ensure(self):
        for attempt in (1, 2, 3):
            self.token += 1
            device.open_url(f"{self.base}/warmup.html?token={self.token}")
            if self.server.wait_for(warm_pattern(self.token), 8, 2):
                return True
            print(f"the tweak is not in this Safari; restarting it (attempt {attempt})", file=sys.stderr, flush=True)
            device.restart_safari(12)
        print("giving up on the tweak; the bridges it installs will read as missing", file=sys.stderr, flush=True)
        return False


def problems(server, pages=PAGES):
    found = []
    for page in pages:
        if not server.seen(reported_pattern(page)):
            found.append(f"MISSING {page} reported nothing")
        elif not server.seen(final_pattern(page)):
            found.append(f"PARTIAL {page} stopped before its end - the verdicts below are what it reached")
    return found


def verdict_feed(server):
    return "".join(f"GET {path}\n" for path in server.matching("/verdicts?"))


def main(argv):
    host = argv[0] if argv and argv[0] else harness.host_address()
    port = int(os.environ.get("TEST_PORT") or 8899)
    base = f"http://{host}:{port}"

    with harness.PageServer(port) as server:
        time.sleep(1)
        device.restart_safari(12)

        bridge = Bridge(server, base)
        for page in PAGES:
            bridge.ensure()
            device.open_url(f"{base}/{page}.html?run={harness.run_token()}")
            server.wait_for(final_pattern(page), 22, 2)

        found = problems(server)
        for line in found:
            print(line, flush=True)

        status = subprocess.run([sys.executable, str(harness.TESTS / "verdicts.py")],
                                input=verdict_feed(server), text=True).returncode
    return 1 if found else status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
