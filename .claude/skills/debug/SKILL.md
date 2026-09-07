---
name: debug
description: Diagnose and recover the Safari substitution on device — Safari fell back to the system engine, an injected dylib will not load, the device SSH is unresponsive, or SpringBoard looks down. Use when something on the iPhone 4S is broken.
---

# Debugging on device

## Safari is on the system engine (`AppleWebKit/536`)

The loader did not re-exec Safari, or the engine did not load. Check in order:

1. `device_run 12 "cat /tmp/rev-safari-tweak.log"` — is there a
   `re-exec …MobileSafari` line? No line → the loader bailed (Safari disabled in
   `InjectedApps`, or the loader failed to load).
2. Confirm the two dylibs are the right files and sizes:
   `device_run 12 "ls -la /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib /usr/lib/rev-safari-compat.dylib"`.
   A common mistake is deploying the compat dylib over `RevSafari.dylib` — the
   loader is small; the compat dylib is much larger (bundles WASM).
3. Compare the on-device dylib's linkage to the local build: pull it back and run
   `otool -L`. A dylib linked against an SDK dependency whose iOS 6 compatibility
   version is lower will be **refused by dyld silently**. Match the linkage of the
   proven copy (see `.claude/skills/build`).

## An injected dylib will not load

`otool -L <dylib>` and `nm -u <dylib> | c++filt`. Fixes:

- The loader must link only `libSystem` + `CoreFoundation`.
- The compat dylib must framework-link Foundation/CoreFoundation/objc/sqlite with
  install_name `/usr/lib/rev-safari-compat.dylib`.
- Keep each dylib's `install_name` equal to its deployed path.

## The device looks dead / SSH resets

- `launchctl list | grep com.apple.SpringBoard` is the reliable liveness check.
  **`ps ax | grep` on the device's busybox does not match reliably** — an empty
  result there does *not* mean SpringBoard is down. Take a `/usr/bin/shot`
  screenshot; a rendered home screen means the UI is fine.
- `kex_exchange_identification: read: Connection reset by peer` with the host
  tunnel still listening usually means the USB tunnel glitched or dropbear is
  rate-limiting rapid connections — slow down and reconnect, or re-seat USB. It is
  usually **not** a device crash.

## Recover to the last good state

The deploy leaves `.bak` copies. Restore and respring:

```sh
device_run 15 "cp -f /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib.bak2 /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib; killall SpringBoard"
```

If a bad **broad** injection makes the UI misbehave, restoring the loader + its
filter `.bak` and respringing brings it back; the loader guards SpringBoard, so
the phone stays bootable. If ever truly stuck, booting into **safe mode** (hold
Volume Up during boot) disables MobileSubstrate so you can SSH in and revert.
