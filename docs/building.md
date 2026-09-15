# Building the port

Everything targets **armv7 with a 6.0 deployment target**, built with an **iOS 13.7
SDK** — the newest SDK that still emits armv7 and still accepts that deployment
target. Current clang compiles C++23 for a 2011 phone; only the SDK is old.

Host requirements: `conan`, `cmake`, `ninja`, `ldid` (ad-hoc signing), a current
`llvm`, and [Theos](https://theos.dev) for the SDK and the packages. Xcode is not
needed and is not installed here - the Command Line Tools carry the compiler and
its runtime, theos carries the SDK, and the linker is a package built from source.

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

They are declared, not scripted. `conanfile.py` names them and `conan.lock` pins
the exact recipe and binary of each; `recipes/` holds the recipe for every one,
and each names a git URL and a commit rather than vendoring a copy:

| Package | Why the system copy will not do |
| --- | --- |
| `libcxx/21.1.0@ios6/stable` | iOS 6 ships a 2012 libc++; C++23 needs a current one |
| `icu/74.2@ios6/stable` | the system ICU predates WebKit's minimum, and text segmentation with it has no zero-width joiner |
| `openssl/3.0.15@ios6/stable` | TLS 1.2/1.3 and Web Crypto |
| `libpsl/0.23.3@ios6/stable` | public-suffix lookups this CFNetwork does not do |
| `libwebp/1.4.0@ios6/stable` | this ImageIO cannot decode WebP |
| `libxslt/1.1.43@ios6/stable` | XSLT |
| `woff2/1.0.2@ios6/stable` | web fonts in the format the web serves them |
| `brotli/1.1.0@ios6/stable` | what woff2 decompresses with |

`@ios6/stable` is not decoration. ConanCenter publishes packages under these
same names, Conan asks remotes in the order they were registered, and a wrong
order does not fail - it quietly builds against a recipe that cannot
cross-compile for armv7. The namespace makes a bare `icu/74.2` unresolvable
from these indexes, so a reference that forgets it is an error instead.

Register the two indexes once, the toolchain's and this repository's:

```sh
conan config install <ios6-toolchain>/config
conan ios6-remote ios6 <ios6-toolchain>
conan ios6-remote revenant .
```

Every script that needs a library sources `scripts/deps.sh`, which runs `conan
install` and loads `build/conan/ios6-deps.env`. That file is written by the
`ios6-base` generator straight from the dependency graph - one
`IOS6_HOST_<NAME>=path` line per library and `IOS6_BUILD_<NAME>=path` per build
tool, so `IOS6_BUILD_LD64` is the linker - and it reads the same from a shell
(`.`) and from make (`include`). No script names a version, an architecture or
a folder layout; change a version in `conanfile.py` and everything follows.
Building the engine builds whatever is missing and reuses whatever is not.

`libios6compat.a` holds only this port's own stubs. It used to carry copies of
OpenSSL's and libpsl's objects, and because it comes first on the link line
those copies - not the packages - were what the engine actually linked. The
engine now links both packages directly.

Two pieces are still built by hand, because neither is a third-party library:

| Script | Builds |
| --- | --- |
| `scripts/build-compat.sh` | `libios6compat.a` - the symbols this OS predates, see [compatibility.md](compatibility.md) |
| `scripts/check-cacert.sh` | nothing - it verifies the trust store the standalone application carries against the hash this project reviewed; `--upstream` says whether curl serves the same extract today |

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

## The toolchain this port needs, and how little of it is Apple's

macOS 27 replaced the linker with ld-27037.1 and broke two things for armv7 at
once. The first is fixed at the source; the second is what this section is
really about.

**OpenSSL's ARM assembly.** The new linker asserts on any named atom in a
`__nl_symbol_ptr` section:

    ld: Assertion failed: (kindIs(Atom::Kind::anon)), function setGotCoalescable

clang emits those slots as local labels, so only hand-written assembly can
produce one. OpenSSL's ARM generator does, for the capability word every
NEON-dispatching module reads, and a single such object in an archive kills the
link whether or not anything references it. The `openssl` recipe patches
the generator - the ios32 branch of `$comm` in `crypto/perlasm/arm-xlate.pl` -
to emit a plain data word instead. Same address, same label name, no GOT atom.
Eight objects were affected; all of them link now, with the assembly kept.

**Reach.** WebCore's `__text` is about 25MB. A Thumb branch reaches 16MB, and
the call stubs are placed after all text, so code in the low third cannot reach
a stub at all. Apple's current linker gives up there. ld64-956.6 does not: it
inserts branch islands that bridge the distance, and it is what links the
engine. It was once recorded here as failing the same way; that came from
appending the test flags to the wrong command in a `&&` chain, and was wrong.

Things that do not work, so nobody tries them twice: `-ld_classic` is ignored
and the binary is gone; `-branch_island_region_size` governs island regions
between text sections, not stub placement; `-mlong-calls` cures the reach and
replaces it with text relocations, which would make `__TEXT` pages dirty at
load - the wrong trade on a device that is killed for dirty memory; lld has no
32-bit ARM Mach-O backend at all.

**Nothing here needs Xcode.** The toolchain can be assembled from parts that
outlive any macOS release:

- the compiler: any recent LLVM, Homebrew's `llvm` is enough - `armv7-apple-ios6.0`
  is a supported target;
- the linker: the `ld64` package from ios6-toolchain - ld64 956.6 built from
  `cctools-port`, which supports armv7, reads `.tbd` stubs through
  `apple-libtapi`, and does LTO through the same LLVM;
- the SDK: `iPhoneOS13.7.sdk`, which theos already carries and which has never
  depended on Xcode.

The `ld64` recipe carries the two snags in building it: `apple-libtapi` calls
`get_darwin_linker_version`, a CMake helper its vendored LLVM does not ship, so
the call is guarded and `HOST_LINK_VERSION` set by hand; and cctools' bundled
`llvm-c/lto.h` wants headers from a newer LLVM, so it is configured against
Homebrew's.

