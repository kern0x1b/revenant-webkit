#!/usr/bin/env python3
"""Load pages you name in Safari on the phone and report what happened to it.

    tests/device/sweep.py https://example.org/ [more...]
    tests/device/sweep.py
"""
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness  # noqa: E402

device = harness.device

SITES_FILE = harness.TESTS / "sweep-sites.txt"

USAGE = """sweep.py loads pages you name and reports what happened to the browser.

    tests/device/sweep.py https://example.org/ [more...]
    tests/device/sweep.py                       # reads tests/device/sweep-sites.txt

It ships with no list of its own on purpose: which sites this repository may
drive a browser at is the operator's call, not the repository's, and loading
somebody's site from an automated run is between the operator and that site's
terms. tests/device/sweep-sites.txt is gitignored for the same reason.
"""

ROW = "%-46s %-6s %-6s %-10s %s"

DIRTY = r'P=$(revpid MobileSafari | sed -n "1s/ .*//p"); [ -n "$P" ] && revmem $P | sed -n "s/.*dirty=\([0-9.]*\) MB.*/\1 MB/p"'


def sites_from(argv, sites_file=SITES_FILE):
    sites = list(argv)
    if not sites and os.access(str(sites_file), os.R_OK):
        for line in sites_file.read_text().split("\n")[:-1]:
            if line == "" or line.startswith("#"):
                continue
            sites.append(line)
    return sites


def shot_name(url):
    return re.sub(r"[/?=&+]", "_", re.sub(r"https?://", "", url, count=1))[:46]


def trimmed(timeout, command):
    return device.output(timeout, command).rstrip("\n")


def main(argv):
    harness.SHOTS.mkdir(parents=True, exist_ok=True)

    sites = sites_from(argv)
    if not sites:
        sys.stderr.write(USAGE)
        return 2

    print(ROW % ("SITE", "ALIVE", "CRASH", "PAINTED", "DIRTY"), flush=True)
    for url in sites:
        name = shot_name(url)
        device.run(20, "killall MobileSafari 2>/dev/null; rm -f /tmp/rev-safari-stderr.log")
        time.sleep(6)
        device.open_url(url)
        time.sleep(26)

        live = trimmed(20, "killall -0 MobileSafari 2>/dev/null && echo 1 || echo 0")
        crash = trimmed(20, "grep -c REVCRASH /tmp/rev-safari-stderr.log 2>/dev/null")
        painted = "-"
        dirty = "-"
        if live == "1":
            dirty = trimmed(30, DIRTY)
            shot = harness.screenshot(f"{name}.png")
            painted = harness.painted(shot)
        print(ROW % (url, live, crash or "?", painted or "?", dirty or "?"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
