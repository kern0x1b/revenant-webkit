# Building the port

Everything targets **armv7 with a 6.0 deployment target**, built with an **iOS 13.7
SDK** — the newest SDK that still emits armv7 and still accepts that deployment
target. Current clang compiles C++23 for a 2011 phone; only the SDK is old.

Host requirements: `conan`, the Command Line Tools, and `iPhoneOS13.7.sdk` from
[theos/sdks](https://github.com/theos/sdks). Conan itself installs the rest:
`cmake` and `ninja` from ConanCenter, `ldid` (ad-hoc signing) and the `ld64`
linker from ios6-toolchain. Xcode is not needed and is not installed here, and
neither is Theos - the Command Line Tools carry the compiler and its runtime,
and `strip`, `otool`, `nm` and `install_name_tool` are found through them. The
Python that runs WebKit's generators and the check scripts is the one Conan runs
in; nothing is taken from `PATH`.

The SDK reaches the build as `tools.apple:sdk_path`, which ios6-toolchain's
`ios6-armv7` profile sets from `IOS_SDK`, or `~/theos/sdks/iPhoneOS13.7.sdk`
when that is unset. Only an SDK somewhere else needs the variable:

```sh
export IOS_SDK="$HOME/path/to/iPhoneOS13.7.sdk"
```

ccache is not picked up on its own. To use it, set the compiler launchers in
your own `global.conf` or profile; `compat/`, `platform/` and the engine all
build with the same generated `conan_toolchain.cmake`, so this covers all three:

```
tools.cmake.cmaketoolchain:extra_variables={"CMAKE_C_COMPILER_LAUNCHER": "ccache", "CMAKE_CXX_COMPILER_LAUNCHER": "ccache", "CMAKE_OBJC_COMPILER_LAUNCHER": "ccache", "CMAKE_OBJCXX_COMPILER_LAUNCHER": "ccache"}
```

## 1. The engine source

```sh
./fetch-source.py
```

`webkit-254` is a git submodule tracking the `main` branch of a WebKit fork,
where this port's engine changes live as real commits. There is no patch series to
apply.

## 2. The libraries iOS 6 cannot supply

They are declared, not scripted. `conanfile.py` names them and `conan.lock` pins
the exact recipe and binary of each; `recipes/` holds the recipe for every one,
and each names a git URL and a commit rather than vendoring a copy:

| Package | Why the system copy will not do |
| --- | --- |
| `libcxx/21.1.0@ios6/stable` | iOS 6 ships a 2012 libc++; C++23 needs a current one |
| `icu/74.2@revenant/stable` | the system ICU predates WebKit's minimum, and text segmentation with it has no zero-width joiner |
| `openssl/3.0.15@revenant/stable` | TLS 1.2/1.3 and Web Crypto |
| `libpsl/0.23.3@revenant/stable` | public-suffix lookups this CFNetwork does not do |
| `libwebp/1.4.0@revenant/stable` | this ImageIO cannot decode WebP |
| `libxml2/2.15.4@revenant/stable` | the system copy is 2.7.8 from 2010, older than the API libxslt and the SDK headers expect |
| `libxslt/1.1.45@revenant/stable` | XSLT; the SDK has no libxslt headers or armv7 library |
| `woff2/1.0.2@revenant/stable` | web fonts in the format the web serves them |
| `brotli/1.1.0@revenant/stable` | what woff2 decompresses with |

The user and channel are not decoration. ConanCenter publishes packages under
these same names, Conan asks remotes in the order they were registered, and a
wrong order does not fail - it quietly builds against a recipe that cannot
cross-compile for armv7. The namespace makes a bare `icu/74.2` unresolvable
from these indexes, so a reference that forgets it is an error instead.

`@ios6/stable` belongs to what ios6-toolchain serves and every port shares.
The libraries this port builds for itself are `@revenant/stable`: another port
on the same machine builds its own OpenSSL with its own choices, and two recipes
behind one reference overwrite each other's packages in the shared cache.

The target comes from ios6-toolchain's shared `ios6-armv7` profile, which says
only what is true of armv7 on iOS 6. What is this port's own - C++23, and
tuning for the Cortex-A9 in the iPhone 4S and iPad 2 - is in
`profiles/revenant-armv7`, which includes the shared one. A 3GS is a
Cortex-A8, and another port on the same toolchain has no reason to inherit
either choice.

Register the two indexes once, the toolchain's and this repository's:

```sh
conan config install <ios6-toolchain>/config
conan ios6-remote ios6 <ios6-toolchain>
conan ios6-remote revenant .
conan config install conan
```

The last line installs this repository's own commands, `revenant:deploy`,
`revenant:run-app` and `revenant:test-device`, which take the phone's address
from `device.env` at the root of the checkout or from `user.revenant:device_host` and the
configuration beside it. `conan config install` copies them, so run it again
after changing anything under `conan/`.

`conan build` writes `build/engine/armv7-system/conan/ios6-deps.env` through the
`ios6-base` generator, straight from the dependency graph - one
`IOS6_HOST_<NAME>=path` line per library and `IOS6_BUILD_<NAME>=path` per build
tool, so `IOS6_BUILD_LD64` is the linker. Nothing names a version, an
architecture or a folder layout. Change a version in
`conanfile.py` and everything follows. Building builds whatever is missing and
reuses whatever is not.

`libios6compat.a` holds only this port's own stubs. It used to carry copies of
OpenSSL's and libpsl's objects, and because it comes first on the link line
those copies - not the packages - were what the engine actually linked. The
engine now links both packages directly.

`libios6compat.a` - the symbols this OS predates, see
[compatibility.md](compatibility.md) - is this port's own code, built by the
engine's recipe from `compat/CMakeLists.txt` before the engine itself.

`scripts/check-cacert.py` builds nothing: it verifies the trust store the
standalone application carries against the hash this project reviewed, and with
`--upstream` says whether curl serves the same extract today.

## 3. The engine

```sh
conan build . -pr:h profiles/revenant-armv7 -pr:b default --build=missing
```

`conanfile.py` is the whole build, the way a Gradle or Maven build file is: it
installs the libraries, writes the CMake toolchain and cache - every path taken
from the dependency graph, the linker from the `ld64` package - and then runs
the steps in the order that fails cheapest first:

1. `scripts/carry-check.py` - the engine tree still holds what this port needs
2. `libios6compat.a`, then the engine through CMake and Ninja
3. WebKitLegacy exports exactly the symbols its export list names
4. `tools/compat-audit.py` - no stub shadows a definition WebKit has
5. `tools/symbol-check.py` - the symbol surface matches `carry-symbols.txt`
6. `platform/` through CMake - the loader, the compat and TLS dylibs and the
   Settings bundle - stripped and signed
7. the frameworks laid out as the iOS 6 system frameworks they replace, beside
   the C++ runtime and everything from step 6, as the whole device filesystem
   tree in `build/engine/armv7-system/stage`
8. `tools/ios6-imports-check.py`, when the phone's shared cache is configured

Everything lands in `build/engine/armv7-system`. The `.deb` is a separate step,
described in [the package](#4-the-package). Why each CMake setting has the
value it has is in [engine-configuration.md](engine-configuration.md).

A change to any recipe here or in ios6-toolchain changes its revision, and
`conan.lock` has to follow in the same commit:

```sh
conan lock create . -pr:h profiles/revenant-armv7 -pr:b default --lockfile="" --update
```

A stale lock does not fail on the machine that made the change - the old
revision is still in its cache and the build quietly uses it - only on a fresh
clone. `.github/workflows/port.yml` is that fresh clone: without the SDK, which
cannot be redistributed, it checks that every Python file compiles, that the
engine at the pinned commit still holds what `carry-manifest.txt` names, that
`conan.lock` resolves against both repositories' recipes, and ICU on the host.

Three things about this build are worth knowing, because they explain choices
that look arbitrary otherwise.

**The engine is built without a class prefix.** The prefix exists so this engine
can sit in a process beside the system one. When a process takes our frameworks
through `DYLD_FRAMEWORK_PATH` the system engine is never loaded, there is
nothing to collide with, and UIKit needs the classes under their real names - it
links `_OBJC_CLASS_$_WebView`, not a prefixed spelling. The recipe therefore
builds the unprefixed engine by default; `-o prefixed=True` builds the prefixed
one for the standalone application.

**The recipe arranges that build as the system frameworks a process expects**,
into `build/engine/armv7-system/stage/usr/lib/rev-fw` rather than an application bundle,
which is what makes `DYLD_FRAMEWORK_PATH` substitution possible for Mobile
Safari: `WebKitLegacy` becomes `WebKit.framework`, every framework takes the
install name of the iOS 6 framework it stands in for (`JavaScriptCore` is a
private framework on this release), the C++ runtime is renamed
`librev-c++` so it cannot be mistaken for the system's, and nothing is left
depending on `@rpath`.

**Nothing in the compatibility library may define a symbol WebKit itself
defines.** A stub that shadows a real definition links cleanly and then fails at
runtime: `WebCoreWebThreadLock` is a function pointer in WTF and was a function
here, which turned a call into a store into `__TEXT` and a bus error.
`tools/compat-audit.py` checks for exactly that:

```sh
python3 tools/compat-audit.py --compat build/engine/armv7-system/compat/libios6compat.a \
    --engine-build build/engine/armv7-system --icu "$IOS6_HOST_ICU"
```

**Every import has to exist on the phone.** The SDK the engine compiles against
is years newer than the system it runs on, so a call can link cleanly against a
function iOS 6 never had. Nothing fails at load: the import is bound lazily, and
the process dies the first time the call is made. A plain `ws://` WebSocket did
exactly that. `tools/ios6-imports-check.py` compares every non-weak import of the
laid-out frameworks with what the phone's own shared cache exports, and the build
runs it once it knows where a copy of that cache is:

```sh
tools/device.py fetch /System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7 build/
conan build . -pr:h profiles/revenant-armv7 -pr:b default \
    -c user.ios6:dyld_shared_cache="$PWD/build/dyld_shared_cache_armv7"
```

`build/` is reproducible and gitignored.

**A change to a WebCore header means a full build - `conan build`, which builds
everything.** A partial build leaves
WebKit and WebKitLegacy compiled against the old class size, and the result loads
and then behaves wrongly — empty text in the interface, and a silent death with no
crash log. This has cost more than one debugging session.

`conan build . -pr:h profiles/revenant-armv7 -pr:b default -o prefixed=True`
builds the same source with the class prefix applied, into
`build/engine/armv7-prefixed`, for a build that has to coexist with the system
engine in one process. The shipped build is the unprefixed one; see
[architecture.md](architecture.md#two-webkits-in-one-process).

## 4. The package

```sh
conan export-pkg . -pr:h profiles/revenant-armv7 -pr:b default
```

`conan build` has already built everything around the engine - `platform/CMakeLists.txt`
builds `RevSafari.dylib`, `rev-safari-compat.dylib`, `rev-TLS.dylib` and
`RevPrefs.bundle` - and laid it out with the engine in
`build/engine/armv7-system/stage`. `conan export-pkg` runs the recipe's
`package()`, which copies that tree into `<package folder>/root` and writes
`<package folder>/deb/space.kern0x1b.rev_<version>_iphoneos-arm.deb` with
ios6-base's `DebianPackage`: `debian-binary`, `control.tar.gz` and
`data.tar.lzma`, the same members `dpkg-deb` writes. To release a new version,
change `version` in `conanfile.py` and build. `packaging/` holds only
`packaging/control`, which carries no version of its own, and
`packaging/DEBIAN/postinst`.

One `.deb` carries the loader and its MobileSubstrate filter, the compatibility
and hook dylib, the TLS library, the Settings bundle with its PreferenceLoader
entry, the C++ runtime and the engine frameworks.

Two settings in `platform/CMakeLists.txt` are not optional: the compat dylib is
built without `_FORTIFY_SOURCE` and without libc++ (`-nostdlib++`), because the `__*_chk` symbols
are linkage this release never had and the engine carries its own C++ runtime — a
second one in the same process is a crash waiting to happen.

## 5. Onto the device

Copy `device.env.example` to `device.env` and fill in the address and password;
neither is in the repository.

```sh
conan revenant:deploy    # engine only: back up, push the staged frameworks, restart Safari
```

For everything else, install the package the way any tweak is installed:

```sh
tools/device.py copy "<package folder>/deb/space.kern0x1b.rev_<version>_iphoneos-arm.deb" /tmp/rev.deb
tools/device.py run dpkg -i /tmp/rev.deb
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
conan build . -pr:h profiles/revenant-armv7 -pr:b default -o prefixed=True
conan revenant:run-app --wait 20
```

The prefixed build ends in `build/engine/armv7-prefixed/RevWebViewHost.app`,
the engine and the C++ runtime bundled inside it and its version taken from
`conanfile.py`; `conan export-pkg` with the same option puts it in
`<package folder>/RevWebViewHost.app`. The runner installs it, opens it through its
`revwebviewhost:` scheme and brings back the log. It needs the device
address in `device.env` at the root of the checkout, as everything that reaches
the phone does.

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

A dylib can compile clean and still be refused by dyld, silently. The build's
imports check covers what it links against; two things it cannot see are worth
looking at in the staged tree the package is made from:

```sh
otool -L build/engine/armv7-system/stage/usr/lib/rev-safari-compat.dylib
otool -l build/engine/armv7-system/stage/Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib | grep LC_ENCRYPTION_INFO
```

The second must print nothing. Apple's linker from Xcode 27 writes that load
command into armv7 dylibs, and iOS 6 then never starts the app the tweak is
injected into; the tweak dylibs link through ld64 for exactly this reason.

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
screenshots: [`tests/device/run.py`](../tests/device/README.md).

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
- the SDK: `iPhoneOS13.7.sdk` from theos/sdks, which has never depended on
  Xcode.

The `ld64` recipe carries the two snags in building it: `apple-libtapi` calls
`get_darwin_linker_version`, a CMake helper its vendored LLVM does not ship, so
the call is guarded and `HOST_LINK_VERSION` set by hand; and cctools' bundled
`llvm-c/lto.h` wants headers from a newer LLVM, so it is configured against
Homebrew's.

