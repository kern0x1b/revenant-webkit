#!/usr/bin/env python3
"""Refuse a staged framework whose Info.plist is the unprocessed one.

    tests/scripts/staged-plists-are-processed.py

CMake writes its own Info.plist for a framework target every time it regenerates,
and the engine post-build command replaces it with the processed one. A build
that reconfigures and relinks nothing loses that race and stages the default:
no MinimumOSVersion, no UIDeviceFamily, an empty CFBundleName. It loads, it runs,
and nothing says the bundle lost what identifies it - which is why this refuses
rather than warns.
"""
import plistlib
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "charon.toml"
REQUIRED = ("MinimumOSVersion", "UIDeviceFamily", "CFBundleSupportedPlatforms")


def engine_location():
    with MANIFEST.open("rb") as handle:
        declared = tomllib.load(handle)
    where = declared.get("stage", {}).get("engine-location")
    if not where:
        raise SystemExit("{} declares no stage engine-location, so where the frameworks land is unknown".format(
            MANIFEST))
    return where


def staged_plists():
    found = []
    for stage in sorted((ROOT / "build").glob("*/stage")):
        for plist in sorted((stage / engine_location()).glob("*.framework/Info.plist")):
            found.append(plist)
    return found


def main():
    plists = staged_plists()
    if not plists:
        print("FAIL  no staged framework carries an Info.plist; run charon build first")
        return 1
    failures = []
    for plist in plists:
        with plist.open("rb") as handle:
            described = plistlib.load(handle)
        missing = [key for key in REQUIRED if not described.get(key)]
        if missing:
            failures.append("{} lacks {} - it is the plist CMake generates, not the one the engine "
                            "processes".format(plist.relative_to(ROOT), ", ".join(missing)))
        if not described.get("CFBundleName"):
            failures.append("{} carries an empty CFBundleName".format(plist.relative_to(ROOT)))
    for line in failures:
        print("FAIL  {}".format(line))
    if failures:
        print("{} staged framework(s) carry an unprocessed Info.plist".format(len(failures)))
        return 1
    print("ok    {} staged framework plists carry the keys the device is identified by".format(len(plists)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
