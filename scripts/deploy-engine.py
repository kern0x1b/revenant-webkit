#!/usr/bin/env python3
"""Stage the engine frameworks and install them into /usr/lib/rev-fw on the phone.

    scripts/deploy-engine.py
    ENGINE_BUILD=build-... scripts/deploy-engine.py
"""
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import device  # noqa: E402

P = device.ROOT
REV = "/usr/lib/rev-fw"
SRC = P / "dist" / "rev-sys-fw"
FRAMEWORKS = ("JavaScriptCore", "WebCore", "WebKit")


def stream_webcore_resources():
    webcore = SRC / "WebCore.framework"
    entries = sorted(name for name in os.listdir(str(webcore)) if not name.startswith(".") and name != "WebCore")
    argv, env = device._authenticated(
        [*device.ssh_command(), f"cd {REV}/WebCore.framework && tar xzf - && chmod -R 755 . 2>/dev/null"])
    tar = subprocess.Popen(["tar", "czf", "-", *entries], cwd=str(webcore),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    ssh = subprocess.Popen(argv, env=env, stdin=tar.stdout)
    tar.stdout.close()
    ssh.wait()
    tar.wait()
    return ssh.returncode or tar.returncode


def main():
    layout = subprocess.run(["bash", str(P / "scripts" / "layout-sys-frameworks.sh")], stdout=subprocess.DEVNULL)
    if layout.returncode:
        return layout.returncode

    probe = device.run(12, "echo ok")
    sys.stderr.write(probe.stderr or "")
    if probe.returncode:
        print("device unreachable", file=sys.stderr)
        return 1

    print(f"backing up current engine -> {REV}.bak", flush=True)
    backup = device.run(30, f"mkdir -p {REV}.bak; for fw in JavaScriptCore WebCore WebKit; do "
                            f"cp -f {REV}/$fw.framework/$fw {REV}.bak/$fw 2>/dev/null || true; done", capture=False)
    if backup.returncode:
        return backup.returncode
    for fw in FRAMEWORKS:
        if not device.copy(SRC / f"{fw}.framework" / fw, f"{REV}/{fw}.framework/{fw}", capture=False):
            return 1

    webcore = SRC / "WebCore.framework"
    if (webcore / "modern-media-controls").is_dir() or (webcore / "Info.plist").is_file():
        status = stream_webcore_resources()
        if status:
            return status

    installed = device.run(20, f"chmod 755 {REV}/*/* 2>/dev/null; echo installed", capture=False)
    if installed.returncode:
        return installed.returncode
    print("restarting Mobile Safari (no respring)", flush=True)
    sys.stdout.write(device.run(15, "killall MobileSafari").stdout or "")
    print("done — verify the engine reports AppleWebKit/605")
    return 0


if __name__ == "__main__":
    sys.exit(main())
