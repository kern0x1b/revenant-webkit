#!/usr/bin/env python3
"""Write a bundle's Info.plist with correct value types.

SpringBoard refuses a bundle whose UIDeviceFamily entries are strings rather
than integers, which is easy to get wrong when generating the plist as text.

Usage:
  write-info-plist.py Info.plist                 the plain browser
  write-info-plist.py Info.plist manifest.json    a packaged web app
"""
import json
import plistlib
import sys

ORIENTATIONS = {
    "portrait": ["UIInterfaceOrientationPortrait"],
    "any": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
}

DEFAULT_NAME = "LegacyBrowser"
DEFAULT_IDENTIFIER = "space.kern0x1b.legacybrowser"
DEFAULT_SCHEME = "legacybrowser"

PLIST = {
    "CFBundleName": DEFAULT_NAME,
    "CFBundleDisplayName": DEFAULT_NAME,
    "CFBundleIdentifier": DEFAULT_IDENTIFIER,
    # The compiled binary is always named LegacyBrowser inside every bundle
    # build-app.sh produces, whatever the app is called on the home screen.
    "CFBundleExecutable": "LegacyBrowser",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "0.1",
    "CFBundlePackageType": "APPL",
    "CFBundleSignature": "????",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "6.0",
    "UIDeviceFamily": [1, 2],
    # A URL scheme is the only way to launch this from a shell: SpringBoard's own
    # launch API needs entitlements a fake signature cannot grant, but uiopen
    # goes through LaunchServices and works.
    "CFBundleURLTypes": [{
        "CFBundleURLName": DEFAULT_IDENTIFIER,
        "CFBundleURLSchemes": [DEFAULT_SCHEME],
    }],
    "UIStatusBarHidden": False,
    "UISupportedInterfaceOrientations": ORIENTATIONS["any"],
}

if __name__ == "__main__":
    out_path = sys.argv[1]
    plist = dict(PLIST)
    if len(sys.argv) > 2:
        with open(sys.argv[2]) as handle:
            manifest = json.load(handle)
        name = manifest["name"]
        identifier = manifest["bundle_id"]
        scheme = manifest["scheme"]
        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        plist["CFBundleIdentifier"] = identifier
        plist["CFBundleShortVersionString"] = manifest.get("version", "1.0")
        plist["CFBundleURLTypes"] = [{
            "CFBundleURLName": identifier,
            "CFBundleURLSchemes": [scheme],
        }]
        plist["UISupportedInterfaceOrientations"] = ORIENTATIONS[
            manifest.get("orientation", "any")]
        style = manifest.get("status_bar_style")
        if style == "default":
            plist["UIStatusBarStyle"] = "UIStatusBarStyleDefault"
        elif style == "black-translucent":
            plist["UIStatusBarStyle"] = "UIStatusBarStyleBlackTranslucent"
        elif style == "black":
            plist["UIStatusBarStyle"] = "UIStatusBarStyleBlackOpaque"

    with open(out_path, "wb") as handle:
        plistlib.dump(plist, handle, fmt=plistlib.FMT_BINARY)
