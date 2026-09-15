# Why the engine is configured the way it is

Every CMake setting the engine is configured with has a reason, and several of
them were learned the hard way. They used to sit as comments beside each flag in
the configure script. They are recorded here so the build description itself can
stay a plain list of settings.

## How the build is driven

**ccache.** Every source file gets recompiled from scratch whenever a CMake flag
changes, because configuring starts from an empty build directory - on one night
that happened four times for a change to one or two files. ccache keys on the
preprocessed source plus the command line, not on the build directory, so it
survives and turns "rebuild everything" back into "recompile what changed" once
it is warm.

**The SDK is named explicitly.** Otherwise the build asks `xcrun` for an
"iphoneos" SDK by name, which only a full Xcode install has, and the toolchain
file overrides the answer anyway. Naming the SDK is what actually gets used, and
it leaves the Command Line Tools sufficient.

**Precompiled headers stay on.** The prefix header carries the export macros into
every translation unit, and it reaches them through the precompiled header.
Without it WebKitLegacy compiles WebCore headers with `WEBCORE_EXPORT` undefined,
and which files break depends on how the unified sources happen to group.

**The linker.** Apple's current linker cannot reach the call stubs of a 25MB
armv7 dylib from the low third of its text and gives up; ld64 inserts branch
islands and links it. `-B` puts it first in the compiler driver's search for
`ld`.

**Optional frameworks are declared absent.** `find_library` searches the host as
well, and on a Mac it finds BrowserEngineCore, BrowserEngineKit and
UniformTypeIdentifiers in the running system - paths that mean nothing to a
linker targeting armv7, which then fails with "framework not found".

## Features

**Touch events.** This is a touch device and the sites it renders are written for
a finger. `ENABLE_TOUCH_EVENTS` and `ENABLE_IOS_TOUCH_EVENTS` both default to off,
so touch support was compiled out entirely: a synthetic tap produced
mousedown/mouseup/click and no touch event at all, which is why an interface
built around touch did nothing. `ENABLE_TOUCH_EVENTS` is the portable path the
GTK and WPE ports build on - real Touch, TouchList and TouchEvent dispatch - and
`EventHandlerIOS.mm` carries a `touchEvent()` / `dispatchSimulatedTouchEvent()`
pair for it. `ENABLE_IOS_TOUCH_EVENTS` stays off on purpose: its guard pulls in
`WebKitAdditions/DocumentIOS.h` and `EventHandlerIOSTouch.cpp`, and the
open-source tree does not carry Apple's WebKitAdditions overlay.

**`-webkit-overflow-scrolling`.** A feed scrolls inside an overflow container, not
the document. Without this property the engine repaints that container on every
frame of a drag and runs a full compositing update with it; with it the scrolled
contents get their own layer, and a scroll is a layer move.

**Size over speed.** `WEBKIT_IOS6_SIZE_OPTIMIZED` optimises for size everywhere
except the script interpreter. The engine's own mapped code measured ninety one
megabytes against a page that uses forty, in a process the system kills at about
a hundred and seventy.

**Notifications and fullscreen.** Both are on. Fullscreen has a real UIKit bridge,
and it needed one upstream gap closed: `requestFullscreen()` is enabled by
`FullScreenEnabled` in `WebCore::Settings`, but WebKitLegacy's hand-maintained
preference sync never copied that setting across, so it was unreachable whatever
the preference said. Web notifications have `WebNotificationClient` wired into
`WebView.mm` and `NotificationsEnabled` defaulted to true for iOS, so
`window.Notification` and `requestPermission` are exposed and permission is
granted. MathML, once cut with these as "pure code weight", is back at the
upstream default: it is plain layout code with no platform backend to write.

**XSLT.** The SDK ships only `libxslt.tbd` - a link stub, with no headers and no
static library for armv7. libxml2's headers are in the SDK and used as they are;
libxslt's come from its package. Linking still goes through
`WEBKIT_ADD_SDK_IMPORTED_LIBRARY(LibXslt::LibXslt libxslt.tbd)`, the same
mechanism as libxml2, sqlite3 and zlib; the package's library directory is on
the linker's search path so a fully static link - bypassing the system's
libxslt the way OpenSSL bypasses SecureTransport - has something to point at.

**The system allocator.** bmalloc builds and runs on this port - the classic
allocator lives in `Source/bmalloc/bmalloc/ios6`, behind the CMake variable
`WEBKIT_IOS6_BMALLOC` together with the compiler define of the same name and
`USE_SYSTEM_MALLOC=OFF`, and it shows up as "WebKit Malloc" in the malloc zone
list. It is slower. On the same device and network, alternating builds:
domInteractive medians 6240 ms against 6090 for the system allocator, resident
157-159 MB against 154-160, and bmalloc owned both outliers at 8.1 and 8.7 s.
`tools/allocator-benchmark.js`, which allocates without the network: system
1494 and 1550 ms, bmalloc 1690, bmalloc with the scavenger at 2048 ms instead of
512 gives 1626 and 1617. Tuning helps and is not enough; allocation is 12% of the
sampled load window, so the ceiling was a few percent in any case.

**Media Source.** Verified to build, and never reachable from the browser.

**ImageDiff.** `Tools/CMakeLists.txt` builds a standalone layout-test comparison
tool whenever the tools directory exists. It is linked into none of the three
shipped frameworks, so turning it off saves build time only.
