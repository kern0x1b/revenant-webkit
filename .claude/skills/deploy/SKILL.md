---
name: deploy
description: Push the Safari substitution and the RevWebKit Settings pane to a jailbroken iPhone 4S over SSH, safely and reversibly. Use when installing or updating the tweak on device.
---

# Deploying to the device

## Configure the device address (never committed)

```sh
cp device.env.example device.env
# set DEVICE_HOST, DEVICE_PORT, DEVICE_PASSWORD in device.env (gitignored)
```

`tools/device.py` reads it: `tools/device.py run <timeout> "<cmd>"`,
`tools/device.py copy <local> <remote>` and `tools/device.py fetch <remote> <local>`.
Scripts import it instead of building SSH option strings of their own.

## Push everything

`conan build` leaves one package with the whole substitution in it; install it
the way any tweak is installed:

```sh
conan export-pkg . -pr:h profiles/revenant-armv7 -pr:b default
deb="$(conan cache path revenant-webkit/<version>:<package id>)/deb"
tools/device.py copy "$deb"/space.kern0x1b.rev_*_iphoneos-arm.deb /tmp/rev.deb
tools/device.py run 120 "dpkg -i /tmp/rev.deb"
```

For the engine alone, without rebuilding the package:

```sh
conan revenant:deploy
```

Its postinst restarts Mobile Safari and Preferences; no respring is needed. The
package puts each file where it belongs:

| In the package | Device |
| --- | --- |
| the loader | `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib` and `RevSafari.plist` |
| compat and hooks | `/usr/lib/rev-safari-compat.dylib` |
| TLS | `/usr/lib/rev-TLS.dylib` |
| the engine | `/usr/lib/rev-fw/{JavaScriptCore,WebCore,WebKit}.framework` |
| the C++ runtime | `/usr/lib/librev-c++.1.dylib`, `/usr/lib/librev-c++abi.1.dylib` |
| the Settings pane | `/Library/PreferenceBundles/RevPrefs.bundle`, `/Library/PreferenceLoader/Preferences/RevWebKit.plist` |

## Rules that keep the device bootable

- **Never overwrite the loader with the compat dylib or vice versa** — they are
  different files; swapping them drops Safari to the system engine.
- **Keep the `.bak` files** the deploy makes. To recover, copy a `.bak` back over
  its target and respring — see `.claude/skills/debug`.
- **Iterating on the Settings pane needs no respring:** redeploy the bundle, then
  `tools/device.py run 15 "killall Preferences"` and reopen it. A respring re-locks the
  device.

## After deploying

Respring with `tools/device.py run 15 "killall SpringBoard"`, wait for it to come back
(`launchctl list | grep com.apple.SpringBoard`), then verify — see
`.claude/skills/test`.
