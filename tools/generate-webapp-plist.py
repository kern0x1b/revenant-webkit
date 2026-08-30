#!/usr/bin/env python3
"""Turn a platform/apps/*.json manifest into the binary WebApp.plist a
packaged app reads at runtime (see WebAppManifest.m for the exact keys)."""
import json
import plistlib
import sys


def hex_to_rgb(text):
    text = (text or "#ffffff").lstrip("#")
    if len(text) == 3:
        text = "".join(c * 2 for c in text)
    r, g, b = (int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    return [r, g, b]


def build(manifest):
    user_agent = manifest.get("user_agent") or {}
    out = {
        "Name": manifest["name"],
        "StartURL": manifest["start_url"],
        "BackgroundColor": hex_to_rgb(manifest.get("background_color")),
        "InternalHosts": manifest.get("internal_hosts") or [],
        "ShellHosts": manifest.get("shell_hosts") or [],
        "PrecacheURLs": manifest.get("precache") or [],
        "OpenExternalLinksInSafari": manifest.get("external_links") == "open-in-safari",
    }
    if user_agent.get("literal"):
        out["UserAgentString"] = user_agent["literal"]
    if user_agent.get("product_version"):
        out["UserAgentProductVersion"] = user_agent["product_version"]
        out["UserAgentBuildVersion"] = user_agent.get("build_version", "")
        out["UserAgentBundleVersion"] = user_agent.get("bundle_version", "")
    if manifest.get("inject_css"):
        out["InjectStyleSheet"] = manifest["inject_css"].rsplit("/", 1)[-1]
    if manifest.get("inject_js"):
        out["InjectScript"] = manifest["inject_js"].rsplit("/", 1)[-1]
    return out


if __name__ == "__main__":
    manifest_path, out_path = sys.argv[1], sys.argv[2]
    with open(manifest_path) as handle:
        manifest = json.load(handle)
    with open(out_path, "wb") as handle:
        plistlib.dump(build(manifest), handle, fmt=plistlib.FMT_BINARY)
