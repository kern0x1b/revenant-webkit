#!/usr/bin/env python3
"""Install dist/RevWebViewHost.app on the phone, launch it and print its log.

    scripts/run-app-rev.py [WAIT] [URL]
"""
import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import device

APP = ROOT / "dist" / "RevWebViewHost.app"
SCHEME = "revwebviewhost"
INSTALL = "cd /Applications && tar xzf - && chmod +x /Applications/RevWebViewHost.app/RevWebViewHost"


def human_size(path):
    total = sum(entry.stat().st_size for entry in path.rglob("*") if entry.is_file())
    for unit in ("B", "K", "M", "G"):
        if total < 1024:
            return f"{total:.0f}{unit}" if unit == "B" else f"{total:.1f}{unit}"
        total /= 1024
    return f"{total:.1f}T"


def launch_script(wait, url):
    lines = ["rm -f /tmp/rev-webview-host.log /tmp/rev-url.txt"]
    if url:
        lines.append(f"echo '{url}' > /tmp/rev-url.txt")
    lines += [
        "su mobile -c uicache >/dev/null 2>&1",
        "sleep 4",
        f"uiopen {SCHEME}://",
        f"sleep {wait}",
        "echo '--- rev-webview-host.log ---'",
        "cat /tmp/rev-webview-host.log 2>&1",
    ]
    return "\n".join(lines)


def wait_for_phone(attempts=3, pause=5):
    for _ in range(attempts):
        if "up" in device.output(20, "echo up"):
            return
        time.sleep(pause)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("wait", nargs="?", type=int, default=20, help="seconds to let the app run")
    parser.add_argument("url", nargs="?", default="", help="page the app opens first")
    args = parser.parse_args()

    print(f"device: {device.HOST}:{device.PORT}")
    wait_for_phone()
    device.run(40, "killall -9 RevWebViewHost 2>/dev/null; rm -rf /Applications/RevWebViewHost.app")

    print(f"copying {human_size(APP)}", flush=True)
    if device.pipe_into(["tar", "-czf", "-", APP.name], INSTALL, cwd=APP.parent):
        print("copy failed")
        return 1

    return device.run(args.wait + 60, launch_script(args.wait, args.url), capture=False).returncode


if __name__ == "__main__":
    sys.exit(main())
