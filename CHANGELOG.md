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

### Fixed
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
