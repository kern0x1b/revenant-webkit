---
name: build
description: Build the WebKit engine and the Safari-substitution artifacts (loader, compat dylib, Settings PreferenceBundle) for armv7 / iOS 6. Use when compiling any part of Revenant WebKit on the macOS host.
---

# Building Revenant WebKit

Everything targets **armv7, iOS 6.0 deployment**, built with an **iOS 13.7 SDK**
(the newest SDK that still emits armv7). Point `IOS_SDK` at it. `cmake`, `ninja`
and `ldid` must be on `PATH`.

```sh
export IOS_SDK="$HOME/path/to/iPhoneOS13.7.sdk"
```

## Engine + standalone app

```sh
./fetch-source.sh     # WebKit at a fixed commit + this port's patches/engine/
./build.sh            # libc++, ICU, OpenSSL, compat, engine, app — in order
```

Run one step alone when only it changed (they are slow):

- `scripts/build-libcxx.sh`, `scripts/build-icu.sh`, `scripts/build-openssl.sh`
- `scripts/build-compat.sh` → `libios6compat.a`
- `scripts/configure-engine.sh` then `ninja -C build-254-lto WebCore WebKitLegacy JavaScriptCore`

`build-254-lto/` and `dist/` are gitignored and reproducible.

## Safari-substitution artifacts

Build after the engine:

```sh
scripts/layout-sys-frameworks.sh   # stage the engine as dist/rev-sys-fw (-> /usr/lib/rev-fw)
make -C packaging package        # loader + compat + TLS + prefs, packaged as a .deb
```

Each signs with `ldid -S`.

## After building an injected dylib — always verify it will load

A dylib can compile clean and still refuse to load on iOS 6 (dyld gives up
silently). Before deploying:

```sh
otool -L dist/rev-safari-compat.dylib     # dependencies must match the on-device working copy
nm -u dist/rev-safari-compat.dylib | c++filt | less   # undefined symbols sanity
```

- The **loader** (`RevSafari.dylib`) links only `libSystem` + `CoreFoundation`,
  install_name `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib`.
- The **compat dylib** framework-links Foundation/CoreFoundation/objc/sqlite,
  install_name `/usr/lib/rev-safari-compat.dylib`.

Do not `-undefined dynamic_lookup` a shared-cache-eligible dylib, and do not
change a dylib's install_name away from the path it is deployed to.

See `.claude/skills/deploy` next, and `.claude/skills/debug` if a build loads but
does nothing on device.
