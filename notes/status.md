# Where this stands

Written overnight, 2026-08-25. The device is an iPhone 4S, armv7 Cortex-A9,
512 MB, iOS 6.1.3, jailbroken. It locked itself when its owner went to sleep,
so everything below was measured through `headless`, which runs from a shell
and needs no SpringBoard. The GUI application cannot be launched while the
screen is locked; that verification is queued.

## The application

It runs. It loads threads.com in about nine seconds, paints the real feed —
avatars, images, the promo sheet — and stays alive. Screenshots are in the
scratchpad.

Four defects the owner reported or I found, all fixed, none yet seen working in
the GUI because of the lock:

- **Taps did nothing.** `-sendEvent:` hands the event to the web thread and
  waits for it; called from the main thread that is a wait on whatever the page
  is doing. Now goes through `WebThreadRun`, like everything else that touches
  the engine.
- **Scrolling ran off the end into white and then crashed.** Two separate
  causes. `setDocumentSize:` was never called from anywhere, so the host layer
  stayed one screen tall and no tile was ever made below it. And
  `restoreNormalTilingAfterScrolling` was called from four places and did not
  exist — every scroll that came to rest was an unrecognised selector.
- **The status bar was gone.** `UIStatusBarHidden` was true; the page now starts
  below the bar.
- **The whole process died 25 seconds in, with no crash report.** `withWebLock`
  took the web lock on a background queue, and CoreAnimation takes the same lock
  on the main thread when it draws a tile. The main thread lost, stopped
  answering, and SpringBoard killed it.

## The engine

Fixed tonight, each with a platform fact behind it:

- `position:fixed` resolved against **zero width on every page**, because
  `pendingFixedPositionLayoutRect` starts as `CGRectZero` and the guard tests
  `CGRectIsNull`, which is `{{∞,∞},{0,0}}`. UIWebView hides this by always
  pushing a real rect; we never pushed one.
- The screen was white on any page whose content sits in `position:fixed`
  containers, because those get promoted to compositing layers and
  `WebChromeClient::attachRootGraphicsLayer` has a body only under
  `PLATFORM(MAC)` — nothing hosts them. Accelerated compositing is now off for
  this embedder, which is what this embedder actually is.
- A page with a media element killed the process: `MediaExperience` and
  CarPlay's `AVAudioSessionPortCarAudio` postdate this OS, and PAL's soft-link
  asserts rather than returning nil.
- `-[NSData enumerateByteRangesUsingBlock:]` is iOS 7. A `CFData` is always
  contiguous, so the loop had one iteration anyway.
- `+[UIColor labelColor]` and its kin are iOS 13 semantic colours; the theme
  now asks whether this UIColor knows a selector before sending it.
- **Cookies, and this is the one that decides whether a wrapped site stays
  logged in.** Every private cookie API the engine uses is absent on this
  Foundation and every public equivalent is present. WebKit wraps these calls in
  exception guards, so each failure was silent: `document.cookie = "x=y"` read
  back empty and no log said why. Now fixed throughout and measured on the
  device:

      document.cookie round trip     readback=[legacyprobe=works]
      survives a fresh process       after new process=[... persisttest=survived]
      on disk                        /var/root/Library/Cookies, 8141 bytes
      discarded exceptions           none

  Two behaviours were settled by measurement rather than by reading:
  `+cookieWithProperties:` accepts the non-public keys WebKit writes, and
  `NSHTTPCookieManagerCookiesChangedNotification` does fire here - which the
  packaging layer's cookie jar depends on.

## The measurements

See notes/measurements.md. The one that decides priorities: a warm cache does
not make threads.com faster, and 50 million loop iterations take 19 seconds.
The load is script execution, and the answer to that is a JIT.

## The JIT

All three frameworks now build for armv7 with `ENABLE_JIT 1`, `ENABLE_C_LOOP 0`
and the YARR regex JIT on, on the 2.54 branch in `webkit-254`/`build-254`.
`PROT_EXEC` is confirmed working on the device. The build currently dies with
SIGBUS the first time it runs generated code; that is being chased.

## The platform

There is now also a JavaScript bridge, `window.legacyApp`, verified installed on
the device. It denies every selector by default and permits exactly one, because
the facility's own header is wrong about that: `ObjcClass::methodNamed()` walks
the class and every superclass to NSObject, so a bridge that does not say
otherwise hands the page `-release` and `-dealloc`. The first thing built on it
is a native tab bar: the page's own bar is a `position:fixed` strip that this
embedder repaints through the tile cache on every scroll frame, so drawing it
natively costs nothing per frame and is the most visible part of not looking
like a browser.

`platform/` packages a web site as its own application: a manifest, a generator,
a shared 160 MB engine installed once with each 3 MB bundle reaching it through
a symlink. Threads and Instagram are packaged and installed. The bundle loads
through dyld and reaches `main` — proven on the device — and the rest waits on
the screen lock.

## The repaint dead end and the touch dead end, 2026-08-25

Everything the owner reported — a fixed header/footer that jitters and drifts
during scroll, an infinite-looking feed that never appends new posts, taps that
appear to do nothing, a promo sheet that will not close — traced to one function:
`WebChromeClient::invalidateContentsAndRootView` in
`Source/WebKitLegacy/mac/WebCoreSupport/WebChromeClient.mm` was **empty**.
Upstream leaves it empty because the WebKitLegacy clients left on iOS draw
themselves; this embedder paints through WAKWindow's tile cache and was never
told anything had changed. A dialog dismissed in the DOM, a fixed element
re-laid-out for a new scroll position, a feed that appended posts — none of it
ever reached the screen. Fixed: the invalidated rect is forwarded to
`-[WAKWindow setNeedsDisplayInRect:]`.

Verified on the device with a script sent to the running application (see
`scratchpad/ask.sh`): the promo sheet's own close control, pressed the way a
finger would press it, took `document.documentElement.scrollHeight` from 460
(one screen — the sheet **is** the whole page while it is open) to 2320 (the
real feed). `platform/inject/threads.js` was rewritten around this: it presses
the sheet's own close button rather than hiding anything, because the sheet's
container is not decoration to hide, it is the page.

Second finding, independent of the first: **touch events were compiled out of
the engine entirely.** `ENABLE_TOUCH_EVENTS` and `ENABLE_IOS_TOUCH_EVENTS` both
default to OFF in this WebKit's CMake and neither `configure-webkit-254.sh` nor
`configure-webkit.sh` turned them on. Confirmed in the built config
(`build-254/cmakeconfig.h`) and confirmed behaviourally: an event listener
installed on the live page, hit with a synthetic touch sent exactly the way this
embedder sends every tap, recorded `mousedown`, `mouseup`, `click` — and no
`touchstart`, no `touchend`. A site whose interface is built on touch, which is
what threads.com is, had no path to react to a tap at all. Both flags are now
ON in both configure scripts; both build trees need a full reconfigure
(`rm -rf` of the build directory, which the configure scripts already do) and
rebuild, which is running as this is written.

A debugging capability was added alongside all of this, because three reports in
a row were guessed at rather than looked at: touching `/tmp/snap` on the device
takes a screenshot on the main thread and writes it to `/tmp/app-shot.png`;
writing `x,y\n` to `/tmp/tap` sends a tap at that screen point and logs what
`document.elementFromPoint` finds there; writing a script to `/tmp/js` runs it
in the page and logs the return value. All three read the trigger file, act, and
clear it rather than deleting it — `/tmp` is sticky and the files are written by
root while the application runs as `mobile`, so `unlink()` was silently refused
and the first version of this re-fired every two seconds forever.
