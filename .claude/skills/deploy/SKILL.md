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

```sh
make -C packaging package install DEVICE_IP=...   # the whole substitution, then respring
```

It backs up each target before overwriting and installs to the correct paths:

| Local | Device |
| --- | --- |
| `dist/RevSafari.dylib` | `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib` |
| `platform/safari/rev-safari.plist` | `/Library/MobileSubstrate/DynamicLibraries/RevSafari.plist` |
| `dist/rev-safari-compat.dylib` | `/usr/lib/rev-safari-compat.dylib` |
| `dist/RevPrefs.bundle` | `/Library/PreferenceBundles/RevPrefs.bundle` |
| `dist/RevWebKit.plist` | `/Library/PreferenceLoader/Preferences/RevWebKit.plist` |

The engine frameworks (`/usr/lib/rev-fw`, plus the TLS shim and libc++) are a
one-time install; the tweak assumes they are already present.

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
