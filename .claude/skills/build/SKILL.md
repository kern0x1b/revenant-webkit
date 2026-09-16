---
name: build
description: Build the WebKit engine and the Safari-substitution artifacts (loader, compat dylib, Settings PreferenceBundle) for armv7 / iOS 6. Use when compiling any part of Revenant WebKit on the macOS host.
---

# Building Revenant WebKit

Everything targets **armv7, iOS 6.0 deployment**, built with an **iOS 13.7 SDK**
(the newest SDK that still emits armv7), from https://github.com/theos/sdks. The
profile finds it at `~/theos/sdks/iPhoneOS13.7.sdk`; set `IOS_SDK` only if it
lives elsewhere. `cmake`, `ninja`, `ldid` and `ld64` come from Conan, not `PATH`;
Theos is not used.

## Engine

```sh
./fetch-source.py     # webkit-254, a submodule on the fork's main branch
```

One command builds the libraries iOS 6 predates (declared in `charon.toml`,
pinned in `conan.lock`), `libios6compat.a` and the engine:

```sh
make build
```

It builds into `build/system`; `make build VARIANT=prefixed` builds the
standalone application's engine into `build/prefixed`. Unchanged
libraries come from the Conan cache. ccache is used only when set as the
compiler launcher through `tools.cmake.cmaketoolchain:extra_variables`
(`CMAKE_<LANG>_COMPILER_LAUNCHER` for C, CXX, OBJC and OBJCXX) in one's own
`global.conf` or profile.

A change to a WebCore header means a full `make build` — a partial build leaves the
other frameworks on the old class size, and the result loads and misbehaves with
no crash log. `docs/building.md` has the whole sequence.

`build/` is gitignored and reproducible.

## Safari-substitution artifacts

The same `make build` finishes them: after the engine it runs the carry,
compat and symbol checks, builds loader, compat, TLS and prefs with CMake from
`platform/`, and lays everything out as the device filesystem in
`build/system/stage` (frameworks in `stage/usr/lib/rev-fw`). Every
binary is stripped and signed with `ldid -S`.

```sh
make package
```

packs that stage into
`<package folder>/deb/space.kern0x1b.rev_<version>_iphoneos-arm.deb`.
The version is `version` in `charon.toml`.

Add `make build ARGS="-c user.ios6:dyld_shared_cache=<path>"` with a copy of the phone's
`dyld_shared_cache_armv7` to have the build refuse imports iOS 6 does not export.

## After building an injected dylib — always verify it will load

A dylib can compile clean and still refuse to load on iOS 6 (dyld gives up
silently). Before deploying:

```sh
otool -L build/system/stage/usr/lib/rev-safari-compat.dylib     # dependencies must match the on-device working copy
nm -u build/system/stage/usr/lib/rev-safari-compat.dylib | c++filt | less   # undefined symbols sanity
```

- The **loader** (`RevSafari.dylib`) links only `libSystem` + `CoreFoundation`,
  install_name `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib`.
- The **compat dylib** framework-links Foundation/CoreFoundation/objc/sqlite,
  install_name `/usr/lib/rev-safari-compat.dylib`.

Do not `-undefined dynamic_lookup` a shared-cache-eligible dylib, and do not
change a dylib's install_name away from the path it is deployed to.

See `.claude/skills/deploy` next, and `.claude/skills/debug` if a build loads but
does nothing on device.
