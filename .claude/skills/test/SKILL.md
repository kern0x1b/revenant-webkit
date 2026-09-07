---
name: test
description: Verify the Safari substitution and the Settings pane on device — confirm the port's engine is active, capture screenshots, and check SpringBoard health. Use after deploying or when checking a change on the iPhone 4S.
---

# Testing on device

All commands go through `tools/device.sh` (`device_run`, `device_copy`) with
`device.env` set. See `.claude/skills/deploy`.

## Is the port's engine active?

The stock engine reports `AppleWebKit/536`; the port reports `AppleWebKit/605`.

- Open a page in Safari (`device_run 12 "uiopen 'https://…'"`) and read the user
  agent — e.g. load a service that echoes it.
- Or read the on-device engine log:
  `device_run 12 "cat /tmp/rev-safari-stderr.log"` — the port prints
  `[tweak] ctor pass`, `WebKitInitialize`, `[jit] reservation … succeeded`.
- Or check what re-exec'd: `device_run 12 "cat /tmp/rev-safari-tweak.log"` — only
  apps enabled in `InjectedApps` (Safari by default) should appear.

Ground truth of rendering: the stock engine renders modern Google/YouTube broken;
the port renders them correctly.

## Screenshots

`/usr/bin/shot` writes `/tmp/screenshot.png` (it ignores any path argument):

```sh
device_run 20 'sleep 8; /usr/bin/shot >/dev/null 2>&1'
device_copy_back /tmp/screenshot.png ./shot.png   # scp it back, then view it
```

Give heavy sites 15–30 s to finish; re-shoot if content is still loading.

## SpringBoard / UI health

```sh
device_run 12 'launchctl list | grep com.apple.SpringBoard'   # present == running
```

Do **not** trust `ps ax | grep SpringBoard` — the device's busybox `ps` output
does not match reliably and makes a healthy device look dead. If unsure, take a
screenshot; if the home screen renders, SpringBoard is fine. A stable pid across
two checks means it is not crash-looping.

## The Settings pane

Reload without a respring: `device_run 15 "killall Preferences; sleep 1; uiopen
'prefs:root=RevWebKit'"`, then screenshot. The pane cannot be scrolled remotely —
ask a person at the device to scroll for the lower rows, or move a row to the top
temporarily to inspect it.
