#!/usr/bin/env python3
"""Check that the staged binaries import only what this iOS exports.

    tests/device/imports-are-exported.py

A symbol the system does not export links and loads without complaint and kills
the process at its first call, so this is the difference between a build that
looks finished and one that runs. The answer lives in the phone's shared cache,
which is why this is a tier that declares a device instead of a step in the
build: a build must finish on a machine that has no phone attached.

The cache is fetched once and kept in ~/.charon; the checker itself comes from
the dependency environment the build wrote, so nothing here is a path anybody
has to supply.
"""
import subprocess
import sys
import tomllib
from pathlib import Path

REMOTE = "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_{arch}"
HELD = Path.home() / ".charon" / "dyld"
TOOL = "CHARON_BUILD_DYLD_IMPORTS_CHECK"
MANIFEST = "charon.toml"


def declared_arch(root):
    with (root / MANIFEST).open("rb") as handle:
        return tomllib.load(handle).get("platform", {}).get("arch")


def checker_from(build):
    written = build / "conan" / "charon-deps.env"
    if not written.is_file():
        return None, "{} does not exist, so nothing says where the checker was installed".format(written)
    for line in written.read_text().splitlines():
        name, _, value = line.partition("=")
        if name.strip() != TOOL:
            continue
        found = Path(value.strip()) / "bin" / "dyld-imports-check"
        if not found.is_file():
            return None, "{} names {} and no checker is there".format(written, found)
        return found, None
    return None, "{} carries no {}; the declaration asks for the checker under [tools]".format(written, TOOL)


def cache_for(arch, device):
    held = HELD / "dyld_shared_cache_{}".format(arch)
    if held.is_file() and held.stat().st_size:
        return held, None
    remote = REMOTE.format(arch=arch)
    HELD.mkdir(parents=True, exist_ok=True)
    print("fetching {} from the phone; this happens once".format(remote))
    device.fetch(remote, str(held))
    if not held.is_file() or not held.stat().st_size:
        return None, "{} did not arrive from the phone, so there is nothing to check against".format(remote)
    return held, None


def run_imports(root, device, build):
    arch = declared_arch(root)
    if not arch:
        print("FAIL  {} declares no [platform] arch, so nothing says which cache answers this".format(
            root / MANIFEST))
        return 1

    stage = build / "stage"
    if not stage.is_dir():
        print("FAIL  {} does not exist; there is nothing staged to check".format(stage))
        return 1

    checker, absent = checker_from(build)
    if absent:
        print("FAIL  {}".format(absent))
        return 1

    cache, missing = cache_for(arch, device)
    if missing:
        print("FAIL  {}".format(missing))
        return 1

    done = subprocess.run([str(checker), "--cache", str(cache), "--dist", str(stage)])
    if done.returncode:
        print("FAIL  {} imports a symbol this system does not export".format(stage))
        return done.returncode
    print("ok    everything staged in {} imports only what {} exports".format(stage, cache.name))
    return 0


if __name__ == "__main__":
    print("this runs as a tier, which is what supplies the phone and the build tree: charon test --tier imports")
    sys.exit(2)
