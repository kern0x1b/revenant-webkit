# Changelog

All notable changes to this project are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Dates are the day the change was measured on the device, not the day it compiled.

## [Unreleased]

### Added
- **Web Crypto that performs its operations.** AES-GCM, HMAC, HKDF and AES key
  wrapping over OpenSSL. Upstream routes all four through CryptoKit, whose Swift
  has no armv7 target, so this port aliased them to one stub returning an empty
  result and no error: a page encrypting a password received an empty buffer and
  sent it. Signing in to a site works from this change on.
- **The engine's own TLS.** `TLS.dylib`, OpenSSL 1.1.1 behind the twenty-five
  SecureTransport entry points CFNetwork imports, inserted at relaunch. The
  system's TLS offers only cipher suites a current server refuses — measured
  against claude.ai, which accepts nothing but AEAD suites. Verification is
  unchanged: the peer chain is returned as a `SecTrustRef` and evaluated by the
  system against its own trust store.
- `requestIdleCallback`, which the engine implements and this port had disabled.
- The page's console, recorded to `/tmp/native-console.log` behind a switch.
- The faulting address and the register file in the crash report. A stack names
  the function; it does not say which pointer was bad.

### Changed
- Stylesheet parsing can be timed through `WEBKIT_IOS6_STYLE_LOG`, which is how
  the launch was accounted for: of the twenty six and a half seconds between
  the application starting and the feed appearing, the web thread is busy for
  ninety eight percent of them. About forty percent is running the site's
  JavaScript, ten percent compiling it, and three of those seconds are a single
  stylesheet - one file, parsed once. Compiling later (`thresholdForJITAfterWarmUp`
  2000, `thresholdForOptimizeAfterWarmUp` 5000) brings the feed up two seconds
  sooner and costs 43% on the JavaScript benchmark, so the upstream numbers stay.
- **The bytecode cache is on, for the large bundles only.** Caching every
  script cost 31 MB of resident memory to save a second and a half, which is
  why it was off. The site's weight is in four bundles: with the engine's floor
  raised to half a megabyte of source, the feed comes up 24.0 s after launch
  against 28.3 s without, for 7 MB. Its ceiling is 192 MB rather than 32 - one
  of these bundles compiles to a seven megabyte blob - and
  `/tmp/native-no-bytecode-cache` turns it off,
  `WEBKIT_IOS6_BYTECODE_MINIMUM_BYTES` moves the floor.
- Stylesheet parsing can be timed through `WEBKIT_IOS6_STYLE_LOG`, which is how
  the launch was accounted for: of the twenty six and a half seconds between
  the application starting and the feed appearing, the web thread is busy for
  ninety eight percent of them. About forty percent is running the site's
  JavaScript, ten percent compiling it, and three of those seconds are a single
  stylesheet - one file, parsed once. Compiling later (`thresholdForJITAfterWarmUp`
  2000, `thresholdForOptimizeAfterWarmUp` 5000) brings the feed up two seconds
  sooner and costs 43% on the JavaScript benchmark, so the upstream numbers stay.
- The bytecode cache's ceiling is 192 MB rather than 32, and a number written
  into `/tmp/native-bytecode-cache` sets it. At 32 MB it held four of this
  site's bundles and missed everything else - one hit against forty three. It
  is still off by default. Warmed by three launches it reaches twenty one hits
  against five misses and brings the feed up in 24.9 s instead of 26.5, which
  costs 31 MB of resident memory - 226 against 195 over the same scripted
  session. On this device that is the wrong side of the trade.

### Fixed
- **Tile layout, which was being skipped almost every frame.** The interface
  stops waiting for the engine before laying out tiles, which is right, but the
  engine holds the web lock nearly all the time on this device: counted on the
  phone, 527 layout passes were skipped against 10 that ran. That method is also
  where tiles for newly exposed page are made, so a flick landed on page that
  was laid out and never painted - photographed, a white screen with the content
  behind it, which stayed white until something else moved. Skipping is now
  bounded: after a quarter of a second without a real pass the interface waits
  for the engine however long it takes. The same counter afterwards reads 129
  passes run against 451 skipped.
- **Tile coverage, cut to the visible screen whenever memory was tight.** Which
  is always here, so every scroll dropped the tiles it had and made two new
  ones. Coverage now follows the system's own pressure reading rather than the
  process's memory policy, and a scroll keeps eleven or twelve tiles - a screen
  above and below - instead of two. `WEBKIT_IOS6_MINIMAL_TILES` restores the old
  behaviour; one soak in three ended in a fault inside the GPU driver with the
  larger set of layers, which two further soaks did not reproduce.
- **Compiled JavaScript, thrown away on the same schedule.** The memory-release
  path also deletes every code block in the process, and the site's route change
  then spends its time parsing and generating bytecode again - parser, bytecode
  generator and `newCodeBlockFor` together dominate the profile of a tab switch.
  Sampled from inside the page, the stretches where it cannot run a timer at all
  across four switches: 77 s in total with the code deleted, 53 s with it kept.
  The code is now deleted only above 235 MB resident, which is where this device
  starts killing the process anyway;
  `WEBKIT_IOS6_CODE_DELETION_THRESHOLD_MB` moves the line. Deleting only the
  linked code and keeping the parse was tried and crashes: an inline cache
  outlives the code block it points at, SIGSEGV inside compiled code within one
  round of use.
- **The style resolver, thrown away every time the system asked for memory.**
  WebCore's memory-release path clears the resolver, and on a 512 MB device
  running a 250 MB process that path runs constantly. Rebuilding it means
  re-reading every rule of the site's stylesheets: measured at 950 ms a time,
  47 times in a four-minute session - 35 seconds of processor spent
  reconstructing something that had not changed. The compiled selectors are
  still released. Over the same scripted session: 1.4 s of rebuilding instead of
  35.5, and resident memory lower rather than higher, 195 MB against 202.
- **Inline caches, which this architecture had them switched off for.**
  `forceICFailure` — the option that makes every inline cache refuse to install —
  defaults to `is32Bit()` upstream, so on armv7 no call ever linked and no
  property access ever cached. Every call went through the slow path for the life
  of the process: the compiler saw an empty call profile at every site, declined
  to inline anything, and emitted a full call frame for `a + 1`. Measured on the
  device, per operation: a method call 706 ns to 71, a call through a variable
  676 to 33, `Math.abs` 553 to 53, reading `Function.length` 605 to 31; through
  the DOM, `node.nodeType` 1235 ns to 60, `element.firstChild` 1310 to 140,
  `document.getElementById` 3175 to 610, `element.style.top = ...` 17800 to
  11020. The synthetic route-change workload fell from 6300–8000 ms to 4979.
  Resident memory is unchanged for the same amount of page: 224 MB against 224
  over an identical scripted session.
- **A register clobbered by the regular-expression JIT.** Its prologue computed
  the new stack pointer into `regT0` before saving the callee-saved registers,
  and on ARM_THUMB2 `regT0` is `r4`, which is in that set — so the caller's `r4`
  was destroyed, then saved, then restored. `'aaa'.matchAll(/\w+/g)` took SIGBUS
  in `JSRegExpStringIterator::nextImpl`. The registers are saved first now.
- **Text drawn invisibly.** The attributed string carried only a font, so
  CoreText painted its own default colour — black — whatever colour UIKit had
  set. The status bar's clock and carrier were painted black on black; the
  battery and the signal, being images, were fine.
- **Text drawn in the wrong place.** `drawAtPoint:` is given a baseline and
  `drawInRect:` the top of a rectangle; both had the ascent added. Each is
  corrected where it belongs.
- **A process abort inside CoreGraphics** when a page drew text into an
  offscreen canvas: the glyph recorder builds a scratch context through the
  context-delegate interface, which this system's CoreGraphics does not have.
  Glyph runs are recorded whole on this port instead of being taken apart.
- **The promoted bottom bar outliving its site.** It is a view in the window, so
  nothing removed it when the reader left; it was found sitting over another
  site still carrying the first one's items.
- Native chrome promotion is off until it can carry the site's icons rather than
  their labels. Five words where the reader expects five pictures is not a
  promotion.

### Changed
- Style caches restored to their upstream sizes. The port had cut
  `MatchedDeclarationsCache` to two entries per hash and 256 buckets; a miss
  there costs a full cascade rebuild, and the cut cost about 12% of the time to
  `domInteractive` (6508–7010 ms against 7213–12296).
- The repository no longer tracks build trees or dependencies. The port's
  changes to the engine are exported to `patches/engine/` instead of carrying an
  upstream checkout.

### Refuted by measurement
- That the optimising JIT costs more than it returns on armv7: 20 s with it,
  24 s without.
- That WebAssembly was what the bot check needed: its script, 227 KB, does not
  mention WebAssembly at all.
- That the feed stopped loading because of a rate limit: the refusal carried
  `"require_login": true`, and the feed paginates once signed in.
