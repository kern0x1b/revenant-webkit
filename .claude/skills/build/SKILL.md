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

## Engine

```sh
./fetch-source.py     # webkit-254, a submodule on the ios6-armv7 branch
```

One command builds the libraries iOS 6 predates (declared in `conanfile.py`,
pinned in `conan.lock`), `libios6compat.a` and the engine:

```sh
conan build . -pr:h profiles/revenant-armv7 -pr:b default
```

It builds into `build/engine/armv7-system`; `-o prefixed=True` builds the
standalone application's engine into `build/engine/armv7-prefixed`. Unchanged
libraries come from the Conan cache and unchanged sources from ccache.

A change to a WebCore header means a full `ninja` — a partial build leaves the
other frameworks on the old class size, and the result loads and misbehaves with
no crash log. `docs/building.md` has the whole sequence.

`build/` and `dist/` are gitignored and reproducible.

## Safari-substitution artifacts

Build after the engine:

```sh
scripts/layout-sys-frameworks.sh   # stage the engine as dist/rev-sys-fw (-> /usr/lib/rev-fw)
make -C packaging package FINALPACKAGE=1   # loader + compat + TLS + prefs + engine, as a .deb
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
