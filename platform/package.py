#!/usr/bin/env python3
"""Turn a web-app manifest plus the shared browser build into an installable .app.

The shared engine is 160 MB of frameworks and the browser is 3 MB of code, so a
packaged app cannot be a copy of both: four of them would be two thirds of a
gigabyte on a phone that has 8 or 16. The split this generator makes is that the
frameworks are installed once, at RUNTIME_INSTALL_PATH, and every packaged bundle
reaches them through a `Frameworks` symlink. Nothing in the binary has to be
rewritten for that — the load commands already say
`@executable_path/Frameworks/...`, and `@executable_path` is resolved by dyld
against the directory the executable sits in, following the symlink like any
other path component. Rewriting them to an absolute path instead was the first
design and it is worse: install_name_tool has to fit the new string into the
space the old one occupied, and `/Library/LegacyWebKit/Frameworks/...` is longer
than `@executable_path/Frameworks/...`.

What ends up in a packaged bundle is therefore about 3 MB: the browser binary,
an Info.plist, the manifest compiled to a binary plist, the certificate
authorities, the icons, the launch image, and whatever stylesheet or script the
manifest injects.

Usage:

    ./platform/package.py apps/threads.json --from dist/LegacyBrowser.app --out out/webapps
    ./platform/package.py apps/*.json --check          # validate manifests only

The output directory deliberately defaults to `out/`, not `dist/`, so this never
writes where build-app.sh does.
"""

import argparse
import binascii
import glob
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import zlib

# Where the shared frameworks are installed on the device. Every packaged bundle
# points its `Frameworks` symlink here, so upgrading the engine is one copy
# rather than one copy per packaged app.
RUNTIME_INSTALL_PATH = "/Library/LegacyWebKit"

# What a packaged bundle takes from the shared build. Everything else in
# LegacyBrowser.app — the frameworks, the headless harness — is either shared or
# has no business in a packaged app.
BUNDLE_FILES = ["cacert.pem"]

ORIENTATIONS = {
    "portrait": ["UIInterfaceOrientationPortrait"],
    "portrait-any": ["UIInterfaceOrientationPortrait",
                     "UIInterfaceOrientationPortraitUpsideDown"],
    "landscape": ["UIInterfaceOrientationLandscapeLeft",
                  "UIInterfaceOrientationLandscapeRight"],
    "all": ["UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"],
}

# iOS 6 has exactly these three. There is no light-content-on-transparent style
# and no per-view-controller control worth using from a plist.
STATUS_BAR_STYLES = {
    "default": "UIStatusBarStyleDefault",
    "black": "UIStatusBarStyleBlackOpaque",
    "black-translucent": "UIStatusBarStyleBlackTranslucent",
}

EXTERNAL_LINK_POLICIES = ["open-in-safari", "stay"]


class ManifestError(Exception):
    pass


# ------------------------------------------------------------------ the manifest


def _require(manifest, key, kind, where):
    if key not in manifest:
        raise ManifestError("%s: missing required key %r" % (where, key))
    value = manifest[key]
    if not isinstance(value, kind):
        raise ManifestError("%s: %r should be %s, got %s"
                            % (where, key, kind.__name__, type(value).__name__))
    return value


def _hosts(value, key, where):
    """Host names, lower-cased. A URL here is a common slip and a silent one:
    ModernTLSURLProtocol compares against `[[request URL] host]`, so
    "https://www.threads.com/" would simply never match anything."""
    if not isinstance(value, list):
        raise ManifestError("%s: %r should be a list of host names" % (where, key))
    out = []
    for host in value:
        if not isinstance(host, str) or not host:
            raise ManifestError("%s: %r contains a non-host entry %r" % (where, key, host))
        if "/" in host or ":" in host:
            raise ManifestError("%s: %r entry %r looks like a URL; it must be a bare host name"
                                % (where, key, host))
        out.append(host.lower())
    return out


def _color(value, key, where):
    """`#rrggbb` to the three floats UIColor wants, so that the runtime needs no
    hex parsing of its own."""
    if not isinstance(value, str) or not value.startswith("#") or len(value) != 7:
        raise ManifestError("%s: %r should look like \"#101010\", got %r" % (where, key, value))
    try:
        red, green, blue = (int(value[i:i + 2], 16) for i in (1, 3, 5))
    except ValueError:
        raise ManifestError("%s: %r is not a hex colour: %r" % (where, key, value))
    return [red / 255.0, green / 255.0, blue / 255.0]


def load_manifest(path):
    """Reads one authored manifest and returns it fully defaulted and validated.

    Authoring is JSON because JSON is what a person edits and what git shows a
    diff of. What the bundle carries is a binary plist, because the runtime reads
    it with -[NSDictionary dictionaryWithContentsOfFile:] and that call has no
    error path to get wrong. The two formats never diverge: the plist is only
    ever produced from the JSON, here.
    """
    where = os.path.basename(path)
    with open(path, "r", encoding="utf-8") as handle:
        try:
            raw = json.load(handle)
        except ValueError as error:
            raise ManifestError("%s: not valid JSON: %s" % (where, error))
    if not isinstance(raw, dict):
        raise ManifestError("%s: the manifest should be a JSON object" % where)

    known = {
        "name", "bundle_id", "scheme", "version", "start_url", "internal_hosts",
        "shell_hosts", "precache", "user_agent", "user_agent_string",
        "orientation", "status_bar_style", "background_color", "icon_color",
        "icon", "inject_css", "inject_js", "external_links", "notes",
    }
    for key in raw:
        if key not in known:
            raise ManifestError("%s: unknown key %r" % (where, key))

    name = _require(raw, "name", str, where)
    bundle_id = _require(raw, "bundle_id", str, where)
    start_url = _require(raw, "start_url", str, where)
    if not start_url.startswith("https://"):
        # ModernTLSURLProtocol only claims https, and a wrapped app that starts
        # on http would silently fall through to iOS 6's own TLS-less loader.
        raise ManifestError("%s: start_url must be https, got %r" % (where, start_url))

    start_host = start_url.split("/", 3)[2].split("@")[-1].split(":")[0].lower()

    shell_hosts = _hosts(raw.get("shell_hosts", [start_host]), "shell_hosts", where)
    internal_hosts = _hosts(raw.get("internal_hosts", []), "internal_hosts", where)
    # The start page's host is internal whether or not it was listed: a link home
    # is not a link off-site.
    if start_host not in internal_hosts:
        internal_hosts.insert(0, start_host)

    orientation = raw.get("orientation", "portrait")
    if orientation not in ORIENTATIONS:
        raise ManifestError("%s: orientation should be one of %s, got %r"
                            % (where, ", ".join(sorted(ORIENTATIONS)), orientation))

    status_bar = raw.get("status_bar_style", "default")
    if status_bar != "hidden" and status_bar not in STATUS_BAR_STYLES:
        raise ManifestError("%s: status_bar_style should be \"hidden\" or one of %s, got %r"
                            % (where, ", ".join(sorted(STATUS_BAR_STYLES)), status_bar))

    external = raw.get("external_links", "open-in-safari")
    if external not in EXTERNAL_LINK_POLICIES:
        raise ManifestError("%s: external_links should be one of %s, got %r"
                            % (where, ", ".join(EXTERNAL_LINK_POLICIES), external))

    agent = raw.get("user_agent")
    if agent is not None:
        if not isinstance(agent, dict):
            raise ManifestError("%s: user_agent should be an object with "
                                "product_version, build_version and bundle_version" % where)
        for key in ("product_version", "build_version", "bundle_version"):
            if not isinstance(agent.get(key), str):
                raise ManifestError("%s: user_agent.%s is required and must be a string"
                                    % (where, key))

    precache = raw.get("precache", [])
    if not isinstance(precache, list) or any(not isinstance(u, str) for u in precache):
        raise ManifestError("%s: precache should be a list of URL strings" % where)
    for url in precache:
        if not url.startswith("https://"):
            raise ManifestError("%s: precache entry %r must be https" % (where, url))

    scheme = raw.get("scheme", bundle_id.rsplit(".", 1)[-1])
    if not scheme.isalnum():
        # LaunchServices will register anything, but `uiopen` and the runtime both
        # build the URL by string concatenation and a scheme with punctuation in
        # it turns into a debugging session rather than a launch.
        raise ManifestError("%s: scheme should be alphanumeric, got %r" % (where, scheme))

    return {
        "name": name,
        "bundle_id": bundle_id,
        "scheme": scheme,
        "version": raw.get("version", "1.0"),
        "start_url": start_url,
        "internal_hosts": internal_hosts,
        "shell_hosts": shell_hosts,
        "precache": precache,
        "user_agent": agent,
        "user_agent_string": raw.get("user_agent_string"),
        "orientation": orientation,
        "status_bar_style": status_bar,
        "background_color": _color(raw.get("background_color", "#ffffff"),
                                   "background_color", where),
        "icon_color": _color(raw.get("icon_color", raw.get("background_color", "#ffffff")),
                             "icon_color", where),
        "icon": raw.get("icon"),
        "inject_css": raw.get("inject_css"),
        "inject_js": raw.get("inject_js"),
        "external_links": external,
        "_source": path,
    }


# --------------------------------------------------------------------- the plists


def info_plist(manifest):
    """The Info.plist SpringBoard reads.

    UIDeviceFamily entries are integers, not strings: a bundle whose family list
    is strings is refused outright, which is the mistake tools/write-info-plist.py
    exists to avoid and the reason nothing here builds a plist as text.
    """
    plist = {
        "CFBundleName": manifest["name"],
        "CFBundleDisplayName": manifest["name"],
        "CFBundleIdentifier": manifest["bundle_id"],
        "CFBundleExecutable": executable_name(manifest),
        "CFBundleVersion": manifest["version"],
        "CFBundleShortVersionString": manifest["version"],
        "CFBundlePackageType": "APPL",
        "CFBundleSignature": "????",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": "6.0",
        # One target device, so no iPad idiom and no iPad icon sizes to carry.
        "UIDeviceFamily": [1],
        "CFBundleIconFiles": ["Icon.png", "Icon@2x.png"],
        # False so SpringBoard applies its own mask and gloss; a flat colour icon
        # that has opted out of the mask is a square among rounded squares and
        # reads immediately as something irregular.
        "UIPrerenderedIcon": False,
        # The only way to launch this from a shell: SpringBoard's launch API wants
        # entitlements a fake signature cannot grant, but uiopen goes through
        # LaunchServices.
        "CFBundleURLTypes": [{
            "CFBundleURLName": manifest["bundle_id"],
            "CFBundleURLSchemes": [manifest["scheme"]],
        }],
        "UISupportedInterfaceOrientations": ORIENTATIONS[manifest["orientation"]],
    }
    if manifest["status_bar_style"] == "hidden":
        plist["UIStatusBarHidden"] = True
    else:
        plist["UIStatusBarHidden"] = False
        plist["UIStatusBarStyle"] = STATUS_BAR_STYLES[manifest["status_bar_style"]]
    return plist


def webapp_plist(manifest):
    """The manifest as the runtime sees it.

    Everything is already normalised: hosts are lower-case, the background colour
    is three floats, and every optional key is present with a definite value.
    That is on purpose — the runtime should be reading a decided document, not
    re-deciding what an absent key meant, because the two decisions drift.
    """
    return {
        "Name": manifest["name"],
        "StartURL": manifest["start_url"],
        "InternalHosts": manifest["internal_hosts"],
        "ShellHosts": manifest["shell_hosts"],
        "PrecacheURLs": manifest["precache"],
        "UserAgentProductVersion": (manifest["user_agent"] or {}).get("product_version", ""),
        "UserAgentBuildVersion": (manifest["user_agent"] or {}).get("build_version", ""),
        "UserAgentBundleVersion": (manifest["user_agent"] or {}).get("bundle_version", ""),
        "UserAgentString": manifest["user_agent_string"] or "",
        "BackgroundColor": manifest["background_color"],
        "InjectStyleSheet": "inject.css" if manifest["inject_css"] else "",
        "InjectScript": "inject.js" if manifest["inject_js"] else "",
        "OpenExternalLinksInSafari": manifest["external_links"] == "open-in-safari",
    }


def executable_name(manifest):
    """The binary's name inside the bundle. Spaces are legal in a bundle name and
    illegal in nothing here, but the name also ends up in ps output and in every
    log line about the process, so it is stripped down."""
    return "".join(c for c in manifest["name"] if c.isalnum()) or "WebApp"


# ----------------------------------------------------------------------- the icon


def solid_png(width, height, rgb):
    """A one-colour PNG, written by hand.

    Pillow is not a dependency worth adding to a build that otherwise needs only
    a Python 3 and a clang, and the image wanted here is a rectangle. iOS rounds
    and masks the icon itself, so a flat brand colour is a finished icon rather
    than a placeholder for one — and a manifest that names a real PNG in `icon`
    overrides this entirely.
    """
    red, green, blue = (int(round(component * 255)) for component in rgb)
    row = bytes((red, green, blue)) * width
    # Filter type 0 (None) in front of every scanline.
    raw = b"".join(b"\x00" + row for _ in range(height))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", binascii.crc32(kind + payload) & 0xffffffff))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def write_icons(bundle, manifest):
    """Icons and the launch image.

    The launch image is the cheapest thing on this list and the one that changes
    the impression most: without a Default.png iOS shows nothing until the first
    frame, and the first frame of this app is the root view's background colour
    several seconds after the tap. With one, the brand colour is on screen before
    the process has finished linking, which is what every native app looks like.
    """
    supplied = manifest["icon"]
    if supplied:
        source = os.path.join(os.path.dirname(manifest["_source"]), supplied)
        if not os.path.exists(source):
            raise ManifestError("%s: icon %r does not exist"
                                % (os.path.basename(manifest["_source"]), supplied))
        # One file at both names: iOS picks by name, and a supplied icon is
        # assumed to be the @2x one because every target device here is @2x.
        shutil.copyfile(source, os.path.join(bundle, "Icon@2x.png"))
        shutil.copyfile(source, os.path.join(bundle, "Icon.png"))
    else:
        colour = manifest["icon_color"]
        with open(os.path.join(bundle, "Icon.png"), "wb") as handle:
            handle.write(solid_png(57, 57, colour))
        with open(os.path.join(bundle, "Icon@2x.png"), "wb") as handle:
            handle.write(solid_png(114, 114, colour))

    background = manifest["background_color"]
    # 320x480 and 640x960: the iPhone 4S is a 3.5-inch @2x screen, and iOS 6 will
    # not show a launch image whose pixel size is not exactly one of these.
    with open(os.path.join(bundle, "Default.png"), "wb") as handle:
        handle.write(solid_png(320, 480, background))
    with open(os.path.join(bundle, "Default@2x.png"), "wb") as handle:
        handle.write(solid_png(640, 960, background))


# -------------------------------------------------------------------- the bundles


def stage_runtime(source_app, out_dir):
    """Copies the shared frameworks out of the built browser into the tree that
    becomes RUNTIME_INSTALL_PATH on the device. Done once for all packaged apps."""
    frameworks = os.path.join(source_app, "Frameworks")
    if not os.path.isdir(frameworks):
        raise ManifestError("%s has no Frameworks directory; build it first" % source_app)
    runtime = os.path.join(out_dir, os.path.basename(RUNTIME_INSTALL_PATH))
    target = os.path.join(runtime, "Frameworks")
    if os.path.exists(target):
        shutil.rmtree(target)
    os.makedirs(runtime, exist_ok=True)
    shutil.copytree(frameworks, target, symlinks=True)
    return runtime


def package(manifest, source_app, out_dir, sign=True):
    """Assembles one packaged .app."""
    binary_source = None
    for candidate in os.listdir(source_app):
        full = os.path.join(source_app, candidate)
        if os.path.isfile(full) and os.access(full, os.X_OK) and candidate != "headless":
            binary_source = full
            break
    if not binary_source:
        raise ManifestError("%s contains no application binary" % source_app)

    bundle = os.path.join(out_dir, manifest["name"] + ".app")
    if os.path.exists(bundle):
        shutil.rmtree(bundle)
    os.makedirs(bundle)

    shutil.copyfile(binary_source, os.path.join(bundle, executable_name(manifest)))
    os.chmod(os.path.join(bundle, executable_name(manifest)), 0o755)

    # Not a copy. See the module docstring: the frameworks exist once on the
    # device and `@executable_path/Frameworks` resolves through this link. It is
    # dangling here on the build host, which is correct — the target is a device
    # path.
    os.symlink(os.path.join(RUNTIME_INSTALL_PATH, "Frameworks"),
               os.path.join(bundle, "Frameworks"))

    for name in BUNDLE_FILES:
        source = os.path.join(source_app, name)
        if not os.path.exists(source):
            raise ManifestError("%s is missing %s" % (source_app, name))
        shutil.copyfile(source, os.path.join(bundle, name))

    with open(os.path.join(bundle, "Info.plist"), "wb") as handle:
        plistlib.dump(info_plist(manifest), handle, fmt=plistlib.FMT_BINARY)
    with open(os.path.join(bundle, "WebApp.plist"), "wb") as handle:
        plistlib.dump(webapp_plist(manifest), handle, fmt=plistlib.FMT_BINARY)

    manifest_dir = os.path.dirname(os.path.abspath(manifest["_source"]))
    for key, name in (("inject_css", "inject.css"), ("inject_js", "inject.js")):
        if not manifest[key]:
            continue
        source = os.path.join(manifest_dir, manifest[key])
        if not os.path.exists(source):
            raise ManifestError("%s: %s %r does not exist"
                                % (os.path.basename(manifest["_source"]), key, manifest[key]))
        shutil.copyfile(source, os.path.join(bundle, name))

    write_icons(bundle, manifest)

    if sign and not shutil.which("ldid"):
        print("warning: ldid is not on PATH; %s is unsigned and SpringBoard will "
              "refuse to launch it" % os.path.basename(bundle), file=sys.stderr)
    elif sign:
        entitlements = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "app", "entitlements.xml")
        # Argument list rather than a shell string: the bundle name comes out of
        # a manifest, and a name with a quote in it would otherwise become a
        # shell injection rather than a validation error.
        subprocess.run(["ldid", "-S" + entitlements,
                        os.path.join(bundle, executable_name(manifest))],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # ldid signs by writing a scratch file beside the binary and renaming it
        # over the original; a run that could not finish leaves the scratch file
        # behind, and a stray dotfile inside an .app is the kind of thing that
        # gets copied to the device forever without anyone asking what it is.
        for leftover in os.listdir(bundle):
            if leftover.startswith(".ldid"):
                os.remove(os.path.join(bundle, leftover))
    return bundle


def write_installer(out_dir, bundles, runtime):
    """One script the owner runs to put all of this on the device.

    It is written rather than run: this generator never touches the device, and
    an install is the owner's to time — it replaces the shared runtime that every
    packaged app links against.
    """
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by platform/package.py. Installs the shared runtime and every",
        "# packaged app. The runtime goes first: a bundle whose Frameworks symlink",
        "# points at nothing launches and dies in dyld with no crash report.",
        "set -e",
        'HERE="$(cd "$(dirname "$0")" && pwd)"',
        'DEV="${1:-${DEVICE_HOST:-127.0.0.1}}"',
        'PORT="${2:-22}"',
        'SSH="${DEVICE_SSH:-ssh} -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no'
        ' -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password'
        ' -o PubkeyAuthentication=no -p $PORT"',
        "",
        'echo "installing the shared runtime"',
        # The archive is rooted at the runtime's own directory name and unpacked
        # into its parent, so this needs no --strip-components: the device's tar
        # is whichever one the jailbreak installed and not all of them have it.
        'tar -C "$HERE" -cf - %s | $SSH "root@$DEV" '
        '\'rm -rf %s && mkdir -p %s && tar -C %s -xf - && chown -R root:wheel %s\''
        % (os.path.basename(runtime), RUNTIME_INSTALL_PATH,
           os.path.dirname(RUNTIME_INSTALL_PATH), os.path.dirname(RUNTIME_INSTALL_PATH),
           RUNTIME_INSTALL_PATH),
        "",
    ]
    for bundle in bundles:
        name = os.path.basename(bundle)
        lines += [
            'echo "installing %s"' % name,
            'tar -C "$HERE" -cf - %s | $SSH "root@$DEV" \''
            'rm -rf /Applications/%s && tar -C /Applications -xf - '
            '&& chown -R root:wheel /Applications/%s\'' % (name, name, name),
        ]
    lines += [
        "",
        "# LaunchServices caches every bundle's Info.plist. Without this a new app",
        "# has no icon and `uiopen` finds no scheme. uicache writes into mobile's",
        "# own container, so it has to run as mobile.",
        '$SSH "root@$DEV" \'su mobile -c uicache\'',
        'echo "installed"',
    ]
    path = os.path.join(out_dir, "install.sh")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


# ------------------------------------------------------------------------- driver


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifests", nargs="*", help="manifest JSON files")
    parser.add_argument("--from", dest="source_app", default="dist/LegacyBrowser.app",
                        help="the built shared browser bundle")
    parser.add_argument("--out", default="out/webapps", help="where to write the bundles")
    parser.add_argument("--check", action="store_true",
                        help="validate the manifests and print what they resolve to, "
                             "without reading the build or writing anything")
    parser.add_argument("--no-sign", action="store_true", help="skip ldid")
    arguments = parser.parse_args(argv)

    paths = []
    for pattern in arguments.manifests:
        expanded = sorted(glob.glob(pattern))
        paths.extend(expanded or [pattern])
    if not paths:
        parser.error("name at least one manifest")

    manifests = []
    for path in paths:
        try:
            manifests.append(load_manifest(path))
        except ManifestError as error:
            print("error: %s" % error, file=sys.stderr)
            return 1

    if arguments.check:
        for manifest in manifests:
            print("%s -> %s.app  (%s, scheme %s://)"
                  % (os.path.basename(manifest["_source"]), manifest["name"],
                     manifest["bundle_id"], manifest["scheme"]))
            print("   start        %s" % manifest["start_url"])
            print("   internal     %s" % ", ".join(manifest["internal_hosts"]))
            print("   shell        %s" % ", ".join(manifest["shell_hosts"]))
            print("   precache     %s" % (", ".join(manifest["precache"]) or "-"))
            print("   orientation  %s, status bar %s"
                  % (manifest["orientation"], manifest["status_bar_style"]))
        return 0

    os.makedirs(arguments.out, exist_ok=True)
    runtime = stage_runtime(arguments.source_app, arguments.out)
    bundles = [package(manifest, arguments.source_app, arguments.out,
                       sign=not arguments.no_sign)
               for manifest in manifests]
    installer = write_installer(arguments.out, bundles, runtime)

    for bundle in bundles:
        # lstat, not getsize: the Frameworks entry is a symlink to a device path
        # and so is dangling here, and following it is both an error and the
        # wrong number — the frameworks are not part of what this bundle costs.
        size = sum(os.lstat(os.path.join(root, name)).st_size
                   for root, _, names in os.walk(bundle) for name in names)
        print("%s  %.1f MB" % (bundle, size / (1024.0 * 1024.0)))
    print("shared runtime: %s -> %s" % (runtime, RUNTIME_INSTALL_PATH))
    print("install with:   %s [device] [port]" % installer)
    return 0


if __name__ == "__main__":
    sys.exit(main())
