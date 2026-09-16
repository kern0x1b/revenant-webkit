---
name: test
description: Verify the Safari substitution and the Settings pane on device — confirm the port's engine is active, capture screenshots, and check SpringBoard health. Use after deploying or when checking a change on the iPhone 4S.
---

# Testing on device

All commands go through `make device ARGS="<run|copy|fetch> ..."` with
`device.env` set. See `.claude/skills/deploy`.

## Is the port's engine active?

The stock engine reports `AppleWebKit/536`; the port reports `AppleWebKit/605`.

- Open a page in Safari (`make device ARGS='run 12 "uiopen 'https://…'"'`) and read the user
  agent — e.g. load a service that echoes it.
- Or read the on-device engine log:
  `make device ARGS='run 12 "cat /tmp/rev-safari-stderr.log"'` — the port prints
  `[tweak] ctor pass`, `WebKitInitialize`, `[jit] reservation … succeeded`.
- Or check what re-exec'd: `make device ARGS='run 12 "cat /tmp/rev-safari-tweak.log"'` — only
  apps enabled in `InjectedApps` (Safari by default) should appear.

Ground truth of rendering: the stock engine renders modern Google/YouTube broken;
the port renders them correctly.

## Screenshots

`/usr/bin/shot` writes `/tmp/screenshot.png` (it ignores any path argument):

```sh
make device ARGS="run 20 'sleep 8; /usr/bin/shot >/dev/null 2>&1'"
make device ARGS="fetch /tmp/screenshot.png ./shot.png   # scp it back, then view it"
```

Give heavy sites 15–30 s to finish; re-shoot if content is still loading.

## SpringBoard / UI health

```sh
make device ARGS="run 12 'launchctl list | grep com.apple.SpringBoard'   # present == running"
```

Do **not** trust `ps ax | grep SpringBoard` — the device's busybox `ps` output
does not match reliably and makes a healthy device look dead. If unsure, take a
screenshot; if the home screen renders, SpringBoard is fine. A stable pid across
two checks means it is not crash-looping.

## Memory breakdown (the device has no vmmap)

`tools/revmem.c` is a vmmap-lite: it sums a process's dirty/resident pages by VM
tag (CoreAnimation, CoreGraphics/ImageIO, JavaScriptCore, malloc, ...). The
`revenant-device-tools` package builds it with `revpid`, `revtouch` and
`raise-memory-limit`, each signed with the entitlements it needs. Install it into
`dist/` and run as root:

```sh
conan install --requires=revenant-device-tools/1.0.0@revenant/stable --lockfile="" \
  -pr:h profiles/revenant-armv7 -pr:b default --build=missing \
  --deployer=direct_deploy --deployer-folder=dist --output-folder=dist/conan
make device ARGS="copy dist/direct_deploy/revenant-device-tools/bin/revmem /usr/bin/revmem"
make device ARGS='run 40 "/usr/bin/revmem <mobilesafari-pid>"       # pid from launchctl list'
```

Use it before any memory change to confirm which owner actually holds the dirty
pages — measured, the heavy pages are malloc/JS-heap bound, not pixel buffers.

## The Settings pane

Reload without a respring: `make device ARGS='run 15 "killall Preferences; sleep 1; uiopen'
'prefs:root=RevWebKit'"`, then screenshot. The pane cannot be scrolled remotely —
ask a person at the device to scroll for the lower rows, or move a row to the top
temporarily to inspect it.
