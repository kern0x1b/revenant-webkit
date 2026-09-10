# Contributor guide

Orientation for anyone — human or AI assistant — working on this repository.
Read it before making changes. Task-specific playbooks live as skills under
`.claude/skills/` (build, deploy, test, debug); this file is the map.

## What this is

A modern WebKit engine built from source for **armv7 / iOS 6.1.3** (iPhone 4S),
and the machinery that runs it. There are two ways the engine is used:

1. **Standalone app** — the engine hosted in this repo's own application
   (`app/`), which exists to exercise the engine directly. Built by
   `scripts/build-app-rev.sh`.
2. **Safari substitution** — the engine dropped underneath the phone's own Mobile
   Safari by a MobileSubstrate tweak. This is the current focus; the screenshots
   in the README are of it.

## The Safari substitution — three artifacts, do not confuse them

The engine lives in the dyld shared cache and cannot be swapped for one process.
A loader is injected into the launching app, sets `DYLD_FRAMEWORK_PATH` /
`DYLD_INSERT_LIBRARIES`, and re-execs; the second launch loads the port's engine.

| Source | Built to | On device | Job |
| --- | --- | --- | --- |
| `platform/safari/rev-safari-tweak.c` | `dist/RevSafari.dylib` | `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib` | The **loader**: reads `InjectedApps`, re-execs enabled apps, skips SpringBoard. |
| `platform/safari/safari-compat.mm` | `dist/rev-safari-compat.dylib` | `/usr/lib/rev-safari-compat.dylib` | **Compat + hooks**: iOS 6 ABI stubs, bookmarks start page, WebAssembly, preference reads. Inserted by the loader. |
| the engine build | `dist/rev-sys-fw` | `/usr/lib/rev-fw/*.framework` | The WebKit engine itself. |

**The loader and the compat dylib are different files.** Deploying the compat
dylib over `RevSafari.dylib` (or vice versa) drops Safari to the system engine —
this has happened. The package puts each in its own place.

## The Settings pane

`platform/prefs/` builds `RevPrefs.bundle` — a native PreferenceBundle (no Theos)
that writes the `space.kern0x1b.rev` preferences domain the engine reads
(`NewTabStartPage`, `CustomURLEnabled`, `CustomURL`, `InjectedApps`). System
`PSListController` cells are loaded from `platform/prefs/Resources/Root.plist`.

## Hard-won gotchas

- **A header change means a full build.** `ninja WebCore` builds one target;
  `WebKit.framework` and `WebKitLegacy.framework` embed WebCore types by value.
  Change a class's size in a WebCore header, deploy only the rebuilt WebCore, and
  those two frameworks read that type with the old layout. The symptom is not a
  crash log: the engine initialises cleanly, Safari's chrome draws with no text at
  all, and the process disappears with no REVCRASH line and no crash report. After
  any header change run plain `ninja`, then deploy.
- **Load-time undefined symbols.** A dylib that links clean (`ninja`/`clang`
  exit 0) can still fail to load on iOS 6, silently — dyld gives up and, for the
  Safari case, Safari falls back to the system engine. After building an injected
  dylib, check `nm -u <dylib> | c++filt` and match the linkage of the copy proven
  on device (`otool -L`). The compat dylib framework-links Foundation/CF/objc/
  sqlite; the loader links only libSystem + CoreFoundation.
- **SpringBoard is boot-critical.** The Substrate filter is broad
  (`Filter { Classes = UIApplication }`) so the loader reaches every app, but the
  loader returns immediately for SpringBoard (`getprogname`) and no-ops for any
  app not enabled in `InjectedApps`. Never let injection touch SpringBoard.
- **Checking whether SpringBoard is alive:** use `launchctl list | grep
  com.apple.SpringBoard`. The device's busybox `ps ax | grep` does **not** match
  reliably and will make a healthy device look dead. Take a `/usr/bin/shot`
  screenshot to confirm the UI.
- **Iterating on the Settings pane** needs no respring: redeploy the bundle, then
  `killall Preferences` and reopen. A respring re-locks the device.
- **`/usr/bin/shot`** always writes `/tmp/screenshot.png` and ignores any path
  argument.
- **The engine is a git submodule** (`webkit-254/`) on the `ios6-armv7` branch.
  Commit and push are forward-only safe; `git checkout`/`reset` inside it can
  destroy the port. Never do destructive git there.

## Conventions

- **No personal data in the repo.** The device address and password live only in
  `device.env` (gitignored). Never commit device credentials, IP addresses,
  hostnames, or absolute `/Users/<name>/...` paths — use `$HOME` / `$IOS_SDK` /
  placeholders in scripts and docs.
- **Commit messages:** plain imperative subject describing the change. No AI or
  tool attribution.
- **Build artifacts** (`dist/`, `build-254*/`, `*.dylib`, `*.a`, `*.log`) are
  gitignored and reproducible from the scripts — do not commit them.

## Where to look

- Build: `scripts/build-*.sh` and `configure-engine.sh`, then `ninja -C build-254-lto`; see `docs/building.md`.
- Package: `packaging/` — Theos makefiles for the loader, the compat dylib, the
  TLS library and the Settings bundle; `make -C packaging package FINALPACKAGE=1`
  produces the installable `.deb`, engine frameworks included.
- Deploy: `make -C packaging package install`, `scripts/deploy-engine.sh`, `tools/device.sh`.
- Documentation: `docs/` (`architecture.md`, `building.md`, `ios6-gaps.md`, `memory-and-caches.md`).
- Playbooks: `.claude/skills/{build,deploy,test,debug}/SKILL.md`.
