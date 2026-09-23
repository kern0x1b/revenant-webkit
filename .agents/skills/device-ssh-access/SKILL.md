---
name: device-ssh-access
description: Reach a jailbroken legacy-iOS device over its USB tunnel in this workspace — claim/release, run a command, copy a file, tell whether it's actually alive, and read a "Permission denied" or connection-reset failure correctly instead of assuming the credentials are wrong. Use whenever a task needs to touch a real device (not the shade emulator).
---

# Device access

Every device-touching repo in this workspace goes through charon's device transport
(`charon/modules/device.lua`), driven by the `xmake device` plugin tasks — never hand-rolled
`ssh`/`scp` to a guessed host/port.

## Run, copy, fetch

```
charon device run <seconds> "<command>"
charon device copy <local> <remote>
charon device fetch <remote> <local>
```

This port's Charon driver has no separate claim/release step: each command reads
`device.env` itself and revives the `iproxy` USB tunnel before running, so a dead tunnel reads
as "connection refused" rather than as a hang. `DEVICE_UDID` / `DEVICE_HOST` / `DEVICE_PORT` /
`DEVICE_PASSWORD` come from a gitignored `device.env` next to the project (copied from
`device.env.example`), or the environment. The well-known default password on a freshly
jailbroken device is `alpine`; nothing more specific than that belongs in a tracked file, a
commit, or this skill.

## "Permission denied (publickey,password,...)" almost never means the password is wrong

It means the command reached the wrong device. On a host running a USB tunnel (`iproxy`), a
port number by itself reaches whichever device that tunnel currently serves — not necessarily
the one you think, especially with more than one device attached. Charon's device transport
already checks this (both the `xmake device run`/`copy` plugin-task form other repos use, and
this repo's own `charon device run`/`copy`) and raises `port %s tunnels to %s, not to %s` before
it would ever reach an auth prompt; a raw `ssh`/`scp` to a guessed port has no such check and
just fails at the credential stage instead, which reads exactly like a wrong password but isn't
one.

- Find what's actually bound: `pgrep -fl iproxy` (lines look like `iproxy <port> 22 -u <udid>`).
- Or ask the tool directly (`xmake device list`, where that plugin task is available) — it shows
  every attached device, its UDID and tunnel port.
- Never guess a port. On a host with more than one attached device, a guessed port reaches
  whichever phone that tunnel happens to serve today.

## The device looks dead

- `launchctl list | grep com.apple.SpringBoard` is the reliable liveness check. The device's
  busybox `ps ax | grep` does **not** match reliably — an empty result there does not mean
  SpringBoard is down.
- A screenshot (`/usr/bin/shot`, always writes to `/tmp/screenshot.png` regardless of any path
  argument) confirms whether the UI is actually up.
- `kex_exchange_identification: read: Connection reset by peer` while the tunnel is still
  listening is usually the USB tunnel glitching, or dropbear rate-limiting rapid reconnects —
  slow down and retry, or re-seat USB. It is usually not a device crash.

## Privacy

Never write a real device UDID, IP/hostname, or password into a tracked file, a commit message,
or a skill — `alpine` (the well-known jailbreak default) is the only credential-shaped string
that's safe to name. Everything device-specific lives in the gitignored `device.env`.
