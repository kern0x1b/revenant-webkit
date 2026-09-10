# Building the port

Everything targets **armv7 with a 6.0 deployment target**, built with an **iOS 13.7
SDK** — the newest SDK that still emits armv7 and still accepts that deployment
target. Current clang compiles C++23 for a 2011 phone; only the SDK is old.

Host requirements: Xcode's toolchain, `cmake`, `ninja`, `ldid` (ad-hoc signing),
and [Theos](https://theos.dev) for the packages.

Theos keeps its SDKs in `$THEOS/sdks`, which is where every script looks by
default. Point `IOS_SDK` somewhere else if yours lives elsewhere:

```sh
export IOS_SDK="$HOME/theos/sdks/iPhoneOS13.7.sdk"
```

## 1. The engine source

```sh
./fetch-source.sh
```

`webkit-254` is a git submodule tracking the `ios6-armv7` branch of a WebKit fork,
where this port's engine changes live as real commits. There is no patch series to
apply.

## 2. The libraries iOS 6 cannot supply

Each script builds one dependency for armv7 into `third_party/`, and each is worth
running alone when only it changed:

| Script | Builds | Why the system copy will not do |
| --- | --- | --- |
| `scripts/build-libcxx.sh` | libc++, libc++abi | iOS 6 ships a 2012 libc++; C++23 needs a current one |
| `scripts/build-icu.sh` | ICU | the system ICU predates WebKit's minimum, and text segmentation with it has no zero-width joiner |
| `scripts/build-openssl.sh` | OpenSSL | TLS 1.2/1.3 and Web Crypto |
| `scripts/build-libpsl.sh` | libpsl | public-suffix lookups this CFNetwork does not do |
| `scripts/build-libwebp.sh` | libwebp | this ImageIO cannot decode WebP |
| `scripts/build-libxslt.sh` | libxslt | XSLT |
| `scripts/build-woff2.sh` | woff2 | web fonts in the format the web serves them |
| `scripts/build-compat.sh` | `libios6compat.a` | the symbols this OS predates — see [compatibility.md](compatibility.md) |
| `scripts/check-cacert.sh` | nothing — it verifies | the trust store the standalone application carries, against the hash this project reviewed; `--upstream` says whether curl serves the same extract today |

## 3. The engine

```sh
scripts/configure-engine.sh          # CMake configure; each flag carries why it is set
ninja -C build-254-lto
```

Three things about these scripts are worth knowing before reading them, because
they explain choices that look arbitrary otherwise.

**The engine is built without a class prefix.** The prefix exists so this engine
can sit in a process beside the system one. When a process takes our frameworks
through `DYLD_FRAMEWORK_PATH` the system engine is never loaded, there is
nothing to collide with, and UIKit needs the classes under their real names - it
links `_OBJC_CLASS_$_WebView`, not a prefixed spelling. `configure-engine.sh`
therefore configures the unprefixed build, and `configure-engine-rev.sh` the
prefixed one for the standalone application.

**`layout-sys-frameworks.sh` arranges that build as the system frameworks a
process expects**, into a standalone directory rather than an application
bundle, which is what makes `DYLD_FRAMEWORK_PATH` substitution possible for
Mobile Safari.

**Nothing in the compatibility library may define a symbol WebKit itself
defines.** A stub that shadows a real definition links cleanly and then fails at
runtime: `WebCoreWebThreadLock` is a function pointer in WTF and was a function
here, which turned a call into a store into `__TEXT` and a bus error.
`build-compat.sh` ends with an `audit` step that checks for exactly that.

`build-254-lto/` and `dist/` are reproducible and gitignored.

**A change to a WebCore header means a full `ninja`.** A partial build leaves
WebKit and WebKitLegacy compiled against the old class size, and the result loads
and then behaves wrongly — empty text in the interface, and a silent death with no
crash log. This has cost more than one debugging session.

`scripts/configure-engine-rev.sh` configures the same source with the class prefix
applied, into `build-254-rev`, for a build that has to coexist with the system
engine in one process. The shipped build is the unprefixed one; see
[architecture.md](architecture.md#two-webkits-in-one-process).

## 4. The package

Everything that goes on the device around the engine is built and packaged by
Theos from `packaging/`:

```sh
scripts/layout-sys-frameworks.sh          # stage the engine as dist/rev-sys-fw
make -C packaging package FINALPACKAGE=1  # -> packaging/packages/*.deb
```

One `.deb` carries the loader and its MobileSubstrate filter, the compatibility
and hook dylib, the TLS library, the Settings bundle with its PreferenceLoader
entry, and the engine frameworks.

Two settings in `packaging/common.mk` and `packaging/compat/Makefile` are not
optional, and each says why where it is set: modules are off, because this SDK
still ships `mach-o/module.map` under its deprecated name; and the compat dylib is
built without `_FORTIFY_SOURCE` and without libc++, because the `__*_chk` symbols
are linkage this release never had and the engine carries its own C++ runtime — a
second one in the same process is a crash waiting to happen.

## 5. Onto the device

Copy `device.env.example` to `device.env` and fill in the address and password;
neither is in the repository.

```sh
scripts/deploy-engine.sh    # engine only: stage, back up, push to /usr/lib/rev-fw, respring
```

For everything else, install the package the way any tweak is installed:

```sh
scp packaging/packages/*.deb root@device:/tmp/ && ssh root@device dpkg -i /tmp/*.deb
```

## The engine without Safari

`app/rev-webview-host.m` is a plain UIKit view controller around one `WebView`:
no tabs, no chrome, one URL. It exists for two reasons.

**As a harness.** It links the engine and `ModernTLSURLProtocol` and nothing
else, so it answers questions about the engine with no `MobileSubstrate`, no
respring and no Safari in the way — and a crash is a crash of one process you
own, with its own log at `/tmp/rev-webview-host.log`. It is also the direct
`WebView` path rather than the substitution path: `UIWebBrowserView` cannot host
this engine, because it drives its view through the *system* WebCore's
`WKWindowSetContentView`, so the window and layer are built here by hand the way
`UIWebView`'s own implementation would.

```sh
scripts/build-app-rev.sh
scripts/run-app-rev.sh 20
```

The runner installs `dist/RevWebViewHost.app`, opens it through its
`revwebviewhost:` scheme and brings back the log. It needs the device
credentials in `tools/device.env`, as everything under `tools/` does.

**As an embedding surface.** Compiled with `-DREV_WEBVIEW_HOST_NO_MAIN` the file
carries no `main()`, and `RevWebViewHostControlling` in
`app/RevWebViewHostEmbedding.h` is the whole interface another application
drives it through — load, back, forward, reload, stop, a content frame, and a
delegate that reports title, progress, URL, scroll offset and failures. That is
the consumer the app-shell cache policy in [network.md](network.md) was written
for: a wrapped site that has to launch like a native application. Nothing in
this repository embeds it today; it is a capability, kept because the
substitution path cannot serve an application that is not Safari.

### What hosting the engine by hand requires

Four things this file had to learn, for anyone embedding it:

- **A root-layer handler must exist.** `WebKitUIKitDelegate` calls
  `-attachRootLayer:` with no `respondsToSelector:` guard, so without it the
  first promoted layer — `position: fixed` content, by default — kills the
  process with an unrecognized selector. The host layer is already in document
  coordinates, which is where `GraphicsLayer` puts the root layer, so parenting
  it needs no extra geometry.
- **Touches have to be posted.** WebKitLegacy takes them as `WebEvent`s sent to
  the `WAKWindow`; there is no automatic path from UIKit, and without it a
  correctly painted page looks frozen. A drag needs a pan recognizer rather than
  raw `touchesMoved:` forwarding, which arrives as stuttering fragments.
- **The keyboard follows WebKit's own focus.** `WebFormDelegate` reports a text
  field taking and losing focus, which is the native, poll-free signal to raise
  a hidden `UIKeyInput` view. Only that view may become first responder: making
  the `WebView` the WAK first responder blurs the focused field and bounces the
  keyboard straight back down. Resigning is debounced, because a tap moving
  focus between fields fires end-then-begin.
- **The host layer has to be resized to the document.** Otherwise a page taller
  than the initial viewport clips instead of scrolling.

## Verifying an injected dylib will load

A dylib can compile clean and still be refused by dyld, silently. Before
deploying one:

```sh
otool -L dist/rev-safari-compat.dylib
nm -u dist/rev-safari-compat.dylib | c++filt
```

- The loader links only `libSystem` and `CoreFoundation`, with install name
  `/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib`.
- The compat dylib framework-links Foundation, CoreFoundation, objc and sqlite3,
  with install name `/usr/lib/rev-safari-compat.dylib`.

Never `-undefined dynamic_lookup` a dylib that is eligible for the shared cache,
and never change a dylib's install name away from where it is deployed.

## Reading a crash

The engine installs a fault handler that prints, for each thread, the program
counter and the address the access was for. The backtrace below it is a chain of
*return* addresses, so its innermost frame is the caller of the function that
faulted, not the fault — symbolising that frame is an afternoon spent on the
wrong function. `backtrace_symbols_fd` names the nearest exported symbol, which
in a library this size is usually the wrong one for the same reason.

What makes a frame exact is the load slide, which the handler prints for every
engine image:

```sh
atos -o WebCore -l <slide> <address>
```

The handler runs on a stack of its own, because a stack overflow faults on the
guard page and would otherwise die without printing anything at all.

## Checking it took

The user agent is the test: a page that echoes it — or the engine's own log at
`/tmp/rev-safari-stderr.log` — should report `AppleWebKit/605`, not `536`.

Then run the numeric suite, which reads pixels and glyph widths rather than
screenshots: [`tests/device/run.sh`](../tests/device/README.md).
