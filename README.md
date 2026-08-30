# Revenant WebKit

**A current WebKit for hardware the web left for dead.**

WebKit 2.53 built for armv7, running today's websites on an iPhone 4S from 2011:
a dual-core 800 MHz device with 512 MB of memory, on iOS 6.1.3.

The engine the phone ships with is WebKit 536 from 2012. It cannot render a page
written this decade — the sign-in form of a modern site comes back with no input
elements at all, because the script that builds it never runs. Nor can the phone
still negotiate TLS with a current server, or perform the cryptography a login
form needs. Each of those is fixed here, inside one application, without
touching the system's own engine.

## What works

- **Current WebKit**, 2.53.91, built from source for armv7 with a 6.0 deployment
  target: current C++ compiled for a 2011 phone.
- **JavaScript with a JIT.** Upstream deleted the ARMv7 JIT in August 2026 and
  left the interpreter; it is restored here, and the regressions that came with
  restoring it are fixed (see `patches/engine/03-javascriptcore.patch`).
- **TLS 1.3.** The system's TLS is from 2012 and current servers refuse its
  cipher suites outright. `app/tls-openssl.c` answers SecureTransport's calls
  over OpenSSL instead, so the browser can reach sites the phone otherwise
  cannot open at all. Certificate verification is unchanged: the chain is handed
  back as a real `SecTrustRef` and the system evaluates it.
- **Web Crypto.** AES-GCM, HMAC, HKDF and AES key wrapping. Upstream routes
  these through CryptoKit, which has no armv7 compiler, so this port had them
  stubbed to return nothing at all - which is what a login form did with a
  password before sending it.
- **Web apps.** A site plus a manifest becomes an application on the home
  screen, sharing one copy of the engine (`notes/shared-engine-architecture.md`).

## Layout

```
app/            The application: window, web view, engine bridge, TLS, delegates
compat/         Symbols iOS 6 does not have, built into libios6compat.a
patches/engine/ This port's changes to WebKit, by area
platform/       Web app manifests, injected scripts, packaging, device runtime
scripts/        The build, one step per script; build.sh runs them in order
tools/          Diagnostic tools, on the host and on the device
notes/          Measurements, findings and the design journal
tests/          Test pages driven on the device
```

The engine checkout itself is not in this repository: `webkit-254/` is upstream's
2 GB of history. What belongs to this project is the difference, exported to
`patches/engine/` by `tools/export-engine-patches.sh` and applied by
`fetch-source.sh`.

## Build

Everything below assumes Xcode's toolchain and an iOS 13.7 SDK, which still
emits armv7 and accepts a 6.0 deployment target.

```
export IOS_SDK=/path/to/iPhoneOS13.7.sdk   # any SDK that still emits armv7
./fetch-source.sh                          # WebKit at a fixed commit, then patches/engine/
./build.sh                                 # everything else, in order
```

`build.sh` runs the steps under `scripts/`, each of which is worth running alone
when only one thing changed:

| Step | What it builds |
| --- | --- |
| `scripts/build-libcxx.sh` | libc++ for armv7 |
| `scripts/build-icu.sh` | ICU, trimmed to the languages in `tools/icu-keep-languages.txt` |
| `scripts/build-openssl.sh` | OpenSSL, for TLS and Web Crypto |
| `scripts/build-compat.sh` | `libios6compat.a`, the symbols iOS 6 lacks |
| `scripts/configure-engine.sh` | CMake configure; the flags carry why each is set |
| `scripts/build-app-lto.sh` | The application around the built engine |

The result is `dist/Threads-Native.app`: the application, three frameworks, the
TLS library, and the injected script for the site.

## On the device

Copy `device.env.example` to `device.env` and put the phone's address in it;
`scripts/deploy.sh` carries the bundle over and starts it. Nothing in the
repository holds an address or a password. The application reads
a handful of files under `/tmp` as switches — they are listed with what each one
does in `notes/measurements.md`; the ones worth knowing are:

| File | Effect |
| --- | --- |
| `/tmp/native-url` | Load the URL written into it |
| `/tmp/native-snap` | Write a screenshot to `/tmp/native-shot.png` |
| `/tmp/native-console` | Record the page's console to `/tmp/native-console.log` |
| `/tmp/native-tls-log` | Record every TLS handshake and its cipher |
| `/tmp/native-system-tls` | Use the system's TLS instead of this one |

## Notes

The reasoning behind the port, and the measurements behind each decision, are in
`notes/`. `notes/design-journal.md` is where it started; `notes/measurements.md`
and the `night-run-*.md` files record what was tried, what worked, and what was
refuted by measuring it.

## License

MIT, see `LICENSE`. The engine is WebKit and carries its own licences; the
patches under `patches/engine/` are changes to that source.
