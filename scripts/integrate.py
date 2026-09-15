#!/usr/bin/env python3
"""One upstream update, in the order that fails cheapest first.

    scripts/integrate.py upstream/webkitglib/2.54     take the series' own picks
    scripts/integrate.py upstream/main                the base change, when it is time
    scripts/integrate.py --no-merge                   just run the gates on what is here
"""
import argparse
import functools
import itertools
import logging
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import device

ENGINE = "webkit-254"
PORT_DELTA_LINES = 14

log = logging.getLogger("integrate")


class Stopped(Exception):
    pass


class NoDevice(Exception):
    pass


def require(argv: list, reason: str, **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run([str(part) for part in argv], check=True, **kwargs)
    except OSError as error:
        log.error("%s: %s", argv[0], error.strerror)
        raise Stopped(reason) from error
    except subprocess.CalledProcessError as error:
        raise Stopped(reason) from error


def python_tool(root: Path, relative: str, *args: str) -> list:
    return [sys.executable, str(root / relative), *args]


def head_of(engine: Path) -> str:
    return subprocess.run(["git", "-C", str(engine), "rev-parse", "HEAD"],
                          stdout=subprocess.PIPE, text=True, check=True).stdout.strip()


def merge(root: Path, ref: str) -> None:
    engine = root / ENGINE
    remote, _, branch = ref.partition("/")
    require(["git", "-C", engine, "fetch", "--filter=blob:none", remote,
             f"refs/heads/{branch or ref}:refs/remotes/{ref}"], "fetch failed")
    before = head_of(engine)
    require(["git", "-C", engine, "merge", "--no-edit", ref],
            f"merge conflicts left in {ENGINE} - resolve, commit, then rerun with --no-merge")
    if head_of(engine) == before:
        log.info("already up to date")


def check_carry(root: Path) -> None:
    result = subprocess.run(python_tool(root, "scripts/carry-check.py"), stdout=subprocess.PIPE,
                            text=True, errors="replace", check=False)
    for line in result.stdout.splitlines():
        if not line.startswith("ok"):
            print(line)
    if result.returncode:
        raise Stopped("the tree no longer holds what this port depends on")


def port_delta(root: Path) -> None:
    with subprocess.Popen(python_tool(root, "scripts/port-delta.py"), stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, errors="replace") as delta:
        for line in itertools.islice(delta.stdout, PORT_DELTA_LINES):
            print(line, end="")


def build(root: Path) -> None:
    require(["conan", "build", root, "-pr:h", root / "profiles" / "revenant-armv7", "-pr:b", "default"],
            "build failed")


def host_checks(root: Path) -> None:
    result = require(python_tool(root, "tests/run-tests.py", "host"), "host checks failed",
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    for line in result.stdout.rstrip("\n").split("\n")[-4:]:
        print(line)
    if "host tests: conan install failed" in result.stdout:
        log.warning("WARNING: the ICU tier did not run - the ICU package for this Mac did not install")


def device_gate(root: Path) -> None:
    if not device.reachable(10):
        raise NoDevice("no device - this integration is unverified and must not be shipped")
    require(["conan", "config", "install", root / "conan"], "installing the port's conan commands failed",
            stdout=subprocess.DEVNULL)
    require(["conan", "revenant:deploy", "--root", root], "deploy failed",
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(["conan", "revenant:test-device", "--root", str(root), "--tier", "gate"],
                            stdout=subprocess.PIPE, text=True, errors="replace", check=False)
    for line in result.stdout.splitlines()[-3:]:
        print(line)
    if result.returncode:
        raise Stopped("the device gate failed - read the verdicts above")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("ref", nargs="?", help="upstream ref to merge into webkit-254, e.g. upstream/main")
    target.add_argument("--no-merge", action="store_true", help="run the gates on the tree as it is")
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    sys.stdout.reconfigure(line_buffering=True)
    args = parse_args()

    steps = [
        (f"merging {args.ref}", functools.partial(merge, ref=args.ref), bool(args.ref)),
        ("carry manifest", check_carry, True),
        ("port delta", port_delta, True),
        ("build, symbols and package", build, True),
        ("host checks", host_checks, True),
        ("device", device_gate, True),
    ]

    subprocess.run(["git", "-C", str(ROOT / ENGINE), "config", "rerere.enabled", "true"], check=False)
    try:
        for title, step, enabled in steps:
            if enabled:
                log.info("\n=== %s", title)
                step(ROOT)
    except Stopped as stop:
        print(f"\nSTOPPED: {stop}")
        return 1
    except subprocess.CalledProcessError as error:
        print(f"\nSTOPPED: {' '.join(map(str, error.cmd))} exited with {error.returncode}")
        return 1
    except NoDevice as missing:
        print(missing)
        return 3

    print("\nintegration green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
