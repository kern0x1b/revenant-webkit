#!/usr/bin/env python3
"""Stage the engine frameworks and install them into /usr/lib/rev-fw on the phone.

    scripts/deploy-engine.py
    ENGINE_BUILD=build-... scripts/deploy-engine.py
"""
import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import device

REMOTE = "/usr/lib/rev-fw"
FRAMEWORKS = ("JavaScriptCore", "WebCore", "WebKit")

log = logging.getLogger("deploy-engine")


def stage_frameworks(root: Path, build: Path) -> Path:
    staged = build / "rev-sys-fw"
    if not (staged / "WebCore.framework" / "WebCore").is_file():
        raise SystemExit(f"{staged} holds no laid-out frameworks - run conan build at {root} first")
    return staged


def back_up_engine() -> None:
    log.info("backing up current engine -> %s.bak", REMOTE)
    names = " ".join(FRAMEWORKS)
    device.run(30, f"mkdir -p {REMOTE}.bak; for fw in {names}; do "
                   f"cp -f {REMOTE}/$fw.framework/$fw {REMOTE}.bak/$fw 2>/dev/null || true; done",
               capture=False, check=True)


def install_binaries(staged: Path) -> bool:
    return all(device.copy(staged / f"{framework}.framework" / framework,
                           f"{REMOTE}/{framework}.framework/{framework}", capture=False)
               for framework in FRAMEWORKS)


def install_webcore_resources(staged: Path) -> int:
    webcore = staged / "WebCore.framework"
    if not ((webcore / "modern-media-controls").is_dir() or (webcore / "Info.plist").is_file()):
        return 0
    entries = sorted(entry.name for entry in webcore.iterdir()
                     if not entry.name.startswith(".") and entry.name != "WebCore")
    return device.pipe_into(["tar", "czf", "-", *entries],
                            f"cd {REMOTE}/WebCore.framework && tar xzf - && chmod -R 755 . 2>/dev/null",
                            cwd=webcore)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    sys.stdout.reconfigure(line_buffering=True)
    argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter).parse_args()
    build = Path(os.environ.get("ENGINE_BUILD") or ROOT / "build" / "engine" / "armv7-system")

    try:
        staged = stage_frameworks(ROOT, build)

        probe = device.run(12, "echo ok")
        sys.stderr.write(probe.stderr or "")
        if probe.returncode:
            log.error("device unreachable")
            return 1

        back_up_engine()
        if not install_binaries(staged):
            return 1
        status = install_webcore_resources(staged)
        if status:
            return status
        device.run(20, f"chmod 755 {REMOTE}/*/* 2>/dev/null; echo installed", capture=False, check=True)
    except subprocess.CalledProcessError as error:
        return error.returncode

    log.info("restarting Mobile Safari (no respring)")
    print(device.run(15, "killall MobileSafari").stdout or "", end="")
    print("done — verify the engine reports AppleWebKit/605")
    return 0


if __name__ == "__main__":
    sys.exit(main())
