#!/usr/bin/env python3
"""Install dist/RevWebViewHost.app on the phone, launch it and print its log.

    scripts/run-app-rev.py [WAIT] [URL]
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import device  # noqa: E402

P = device.ROOT
APP = P / "dist" / "RevWebViewHost.app"
SCHEME = "revwebviewhost"


def launch_command(wait, url):
    return (
        "\n"
        "rm -f /tmp/rev-webview-host.log /tmp/rev-url.txt\n"
        + (f"echo '{url}' > /tmp/rev-url.txt" if url else "") + "\n"
        "su mobile -c uicache >/dev/null 2>&1\n"
        "sleep 4\n"
        f"uiopen {SCHEME}://\n"
        f"sleep {wait}\n"
        "echo '--- rev-webview-host.log ---'\n"
        "cat /tmp/rev-webview-host.log 2>&1\n"
    )


def main(argv):
    wait = argv[0] if argv and argv[0] else "20"
    url = argv[1] if len(argv) > 1 else ""

    print(f"device: {device.HOST}:{device.PORT}", flush=True)
    for _ in range(3):
        if "up" in device.output(20, "echo up"):
            break
        time.sleep(5)

    device.run(40, "killall -9 RevWebViewHost 2>/dev/null; rm -rf /Applications/RevWebViewHost.app")

    size = subprocess.run(["du", "-sh", str(APP)], stdout=subprocess.PIPE, text=True).stdout
    print(f"copying {size.split(chr(9), 1)[0].rstrip()}", flush=True)
    argv_ssh, env = device._authenticated(
        [*device.ssh_command(), "cd /Applications && tar xzf - && chmod +x /Applications/RevWebViewHost.app/RevWebViewHost"])
    tar = subprocess.Popen(["tar", "-C", str(APP.parent), "-czf", "-", APP.name], stdout=subprocess.PIPE)
    ssh = subprocess.Popen(argv_ssh, env=env, stdin=tar.stdout, stderr=subprocess.DEVNULL)
    tar.stdout.close()
    ssh.wait()
    tar.wait()
    if ssh.returncode:
        print("copy failed")
        return 1

    sys.stdout.flush()
    os.dup2(sys.stdout.fileno(), sys.stderr.fileno())
    return device.run(int(wait) + 60, launch_command(wait, url), capture=False).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
