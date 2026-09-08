# Changelog

All notable changes to this project are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Dates are the day the change was measured on the device, not the day it compiled.

## [Unreleased]

### Added
- **WebP, which was being asked for and could not be read.** The image Accept
  header offered WebP, AVIF, JPEG-XL and HEIC ahead of everything else, and ImageIO
  here decodes none of them - WebP arrived in it with iOS 14, AVIF with iOS 16,
  JPEG-XL never shipped, HEIC needs iOS 11 and HEVC hardware this device lacks. So
  every server that negotiates image formats sent a picture that rendered as
  nothing: The Verge's lead image was an empty grey box and BBC News looked like a
  page without photographs. WebKit's own WebP decoder is built instead, reached
  through `ScalableImageDecoder`, with `scripts/build-libwebp.sh` building the
  decoder and demuxer for armv7. The other three are no longer claimed.
- **A page's own favicon, instead of Google's copy of it.** The start page fetched
  every tile's icon from Google's favicon service by host, disclosing every
  bookmarked host to a third party and bypassing this port's TLS. WebCore's icon
  loader is compiled and was simply switched off for iOS; it now runs, and the
  bytes travel to the application as a notification. Sites' real declared icons
  arrive - Wikipedia's ICO, GitHub's SVG mark - rather than a rasterised guess.

- **Web Crypto that performs every algorithm, through WebKit's own backend.** The
  Cocoa backend works in CryptoKit, whose Swift has no armv7 target, so this port
  had aliased the missing entry points to a no-op and then hand-written AES-GCM,
  AES-KW, HKDF and HMAC over OpenSSL - reimplementing what WebKit already carries
  in `crypto/openssl` for the ports without CryptoKit. The curve algorithms were
  not reimplemented at all; their constructors were aliased to that same no-op,
  which leaves an object with no vtable. That backend is built instead, against
  the OpenSSL 3.0 this port already builds for its TLS. **ECDSA, ECDH, RSA-OAEP,
  RSASSA-PKCS1, PBKDF2 and AES-CBC/CFB/CTR can be performed for the first time.**
  Five reconciliations were needed, since no port had asked a Darwin platform for
  this backend before, and three were genuine version bugs in it: RSA-OAEP was
  compiled out by a `defined()` test on names that became functions in OpenSSL
  3.0, AES-GCM set its padding mode before the cipher was installed, and
  `EVP_PKEY_get0_RSA` now returns a const pointer.

- **Web fonts, in every format the web serves.** No `@font-face` had ever
  produced a font. `FontCustomPlatformData::create` is built on a private CoreText
  parser and on an iOS 7 API, neither of which exists here, so it returned nothing
  and every custom font failed silently - icon fonts included, which is why so
  many sites drew blank squares. It now takes the documented route that predates
  both: a data provider, `CGFontCreateWithDataProvider`,
  `CTFontCreateWithGraphicsFont`, then that font's descriptor. `HAVE_WOFF_SUPPORT`
  claims the system parser reads WOFF, true from iOS 7 but not here, so WebKit's
  own converter is compiled back in for WOFF; WOFF2 needed the library, which
  `scripts/build-woff2.sh` now builds for armv7 alongside the brotli decoder it
  rests on.
- **Scrolling inside a page.** Nothing in a page could be moved with a finger -
  not an overflow block, not the body of a cookie dialog, not a frame. Only the
  main frame scrolled, because only the main frame has a scroll view. The rest of
  the contract was already whole: promote the area, hand the layer to the embedder
  through `LegacyWebKitScrollingLayerCoordinator`, and the embedder wraps it in a
  `UIWebOverflowScrollView` and reports back through
  `-[WebView _overflowScrollPositionChangedTo:forNode:isUserScroll:]`. Nothing was
  ever promoted, so none of it ran. Frames needed three further gates opened, each
  false for its own reason, and their layer is keyed by the element that owns the
  frame.
- `tools/revpid.c`, which lists pids by name. The device has no `ps`, and `revmem`
  takes a pid, so a process's memory could not be measured without it.

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
- **Font feature tags are translated instead of dropped.** `font-feature-settings`
  and every `font-variant-*` were discarded, because features are addressed by
  OpenType tag only from iOS 8 and handing this CoreText a tag-keyed dictionary
  crashes descriptor matching. Apple's own mapping to the numeric AAT
  type/selector pairs - the one that stood in this repository before commit
  `06230e738722` replaced it - is restored for this port. A font carrying AAT
  feature tables now honours the request: `font-variant-caps: small-caps` renders
  in genuine small capitals. A font with only OpenType tables, which is most of
  what the web serves, still will not - this CoreText does not translate an AAT
  selector into a GSUB feature.

- **canPlayType() answers from AVFoundation instead of a list of five.** The
  player factory named five container types, so every other format the framework
  plays was denied - 3GPP, M4V, WAV, AIFF, bare AAC, the `audio/mp3` spelling and
  both spellings of HLS - and a page choosing between `<source>` elements skipped
  formats it could have played. `AVAssetMIMETypeCache` was in the tree for exactly
  this and merely excluded.
- **An asset's description is loaded off the layout path.** `hasVideo()` and
  `hasAudio()` read the asset's tracks synchronously, from layout, before anything
  was ready - which blocks the calling thread on whatever loading remains. They are
  requested asynchronously now, and a failure to load the description is reported
  as a load failure rather than as a decode error, so a missing file no longer
  looks like a corrupt one.

- **A second pass, on what the first one named and could not reach.** String
  hashing on this port no longer runs a mixer built from 64x64 multiplies, which
  armv7 performs in four instructions plus carries; it is a 32-bit mixer, one
  `umull` per eight bytes. That hash is reproduced by three build-time generators
  which emit the static property tables the runtime probes, so all three were
  ported with it and checked against the C++ over 1280 strings and every key of
  all 68 generated tables. The interpreter no longer rebuilds the address of the
  opcode table before each dispatch - it is pinned in a register - which takes
  the generated interpreter from 74,154 instructions to 61,690, and the baseline
  JIT stops emitting two memory barriers for every write to a call frame. The
  collector stops recomputing its heap bounds for every word of the stack it
  scans, and stops suspending every thread twice per collection to measure before
  copying.
- **The compiled form of the site's scripts is now actually written.** The cache
  commits an entry when the engine drops a script's source provider, and the
  provider for a bundle the page holds open is dropped only when the process
  ends - which for this application means never, since it is killed rather than
  asked to quit. The two largest bundles were therefore recompiled at every
  launch. They are written now when the page finishes loading, and again every
  thirty seconds while it is in use - the engine compiles a function the first
  time it is called, so a blob written at load time holds only what had run by
  then, and a third of the launch is that lazy compilation. Twelve entries and
  15 MB after one session of use, against four entries and 3 MB; the feed
  arrives in 20 to 23 s where the same build without the write took 29.5.
- **The engine rewritten for this processor, area by area.** Twelve passes over
  the source, each one looking for work that costs time on an 800 MHz in-order
  core and buys nothing here. Among what came out of it: a structure-consistency
  check that ran in release builds from thirteen call sites on every object shape
  transition, each one reading thread-local storage through `mrc p15`; the
  inspector's `timelineAgentTracking()` called on every JavaScript function
  invocation through the bindings, and 153 other instrumentation points that can
  never fire here; the HTML tokenizer walking `<script>` and `<style>` bodies one
  character at a time; a two kilobyte vector allocated and freed for every CSS
  rule; a namespace map copied for every declaration; `intHash` widening to 64
  bits to run a mixer built from 64x64 multiplies, which armv7 does in four
  instructions; the timer heap removing an element by pushing it to the root and
  then sifting it back down; `Page::updateRendering` walking the frame tree
  twenty eight times per frame and allocating a `WTF::Function` for each walk;
  the tile grid asking CoreAnimation for the layer bounds once per tile per pass.
  Measured after: `element.getAttribute` 810 ns against 930, `document.createElement`
  5.96 us against 6.9, `element.style.top = x` 10.0 us against 11.2, reading
  `className` 195 ns against 240. The launch and the JavaScript benchmark did not
  move.
- Tile coverage is half a screen above and below rather than a whole one. Each
  tile is 1.6 MB at this scale and three screens came to nineteen megabytes of
  layers, not the seven the old note claimed; two screens still cover a flick.
  `WEBKIT_IOS6_TILE_COVERAGE_HALVES` changes it.
- The crash report says how much memory the process was holding, how long it had
  been running and which thread took the signal. Twenty soaks of eight rounds
  produced four deaths with two signatures - a null dereference inside the GPU
  driver and a fault in the allocator - and they appear with the inline caches
  on and off, with the tile coverage large and small, so none of this session's
  changes is behind them.
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
- **Any page using small-caps ended the process.** `Font::supportsSmallCaps()`
  asks CoreText which glyphs a feature covers; this one answers nothing for a
  feature it does not know, and the union of that coverage counted the bits of a
  null vector. Guarded where both coverage queries arrive.

- **Every piece of text the engine supplies read "localized string not found".**
  That string is a sentinel `CFBundleCopyLocalizedString` is asked to return when a
  key is absent, so a debug assertion trips; in a release build it reaches the
  interface instead. The staged framework carries the media controls' strings and
  no `Localizable.strings` beside them, so every key missed - the file chooser
  buttons, a valueless submit or reset button, the context menus, the accessibility
  labels and a multiple select were all labelled with it. A missing key now falls
  back to the key, which is the English string.

- **A software-decoded image drew nothing at all.** `ImageBackingStoreCG` asked
  CoreGraphics for its colour space by name, and this one answers to no name:
  `kCGColorSpaceSRGB` returned nothing, `CGImageCreate` got a null space, and the
  picture decoded, reported its size and painted nothing. It goes through the
  engine's own `sRGBColorSpaceSingleton` now.
- **A playing video told the page nothing about itself.** readyState stayed 0 and
  videoWidth was zero while the movie ran, so anything measuring a video, or
  waiting for loadeddata or canplay, saw a media element that had never loaded. The
  status observation asked for no options and so only heard about a *change*, while
  an item from a fast source is already ready before observation starts; and the
  natural size came only from the item, which is empty until then, rather than from
  the video track, which carries it as soon as metadata is loaded.

- **Form controls were painted entirely in transparent.** Every button, checkbox,
  radio, select, text field and progress bar on every page: no box, no border, no
  label. Only `-webkit-appearance: none` drew. The user agent stylesheet dresses
  controls in the semantic colours, which map to UIColor selectors introduced in
  iOS 13; the lookup correctly declines, and the base `RenderTheme` answers a name
  it does not know with an invalid colour, which is fully transparent. Layout, hit
  testing and events all worked, so a button was clickable and unreadable - which
  is why pages read as frozen. Each name is now answered with the specification
  colour of the same role, so every value still comes from WebKit's own table.
- **Two crashes in image drawing.** Drawing scales the source rectangle by one
  size divided by another, and either can still be empty when frame metadata has
  not arrived; the division put infinities in the rectangle and the draw faulted.
  This was the most frequent crash on this port, ten of fifteen that could be
  symbolicated. Separately, asking for an image's size reached for a frame that
  did not exist yet and re-entered itself until the stack was gone.
- **A constructor that returned without running.** `MediaSampleAVFObjC`'s
  constructor was aliased to a shared no-op, which leaves the object with no
  vtable; six built files reference it. The real file needs none of what forced
  its exclusion and now compiles. Its callers turn out to be unreachable today,
  so this removes a hazard rather than an observed crash.

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
  The code is now deleted only above 160 MB resident, just under the point where
  the app makes its own last-resort release, so deletion happens with a full
  release and never routinely;
  `WEBKIT_IOS6_CODE_DELETION_THRESHOLD_MB` moves the line. This entry previously
  said that deleting only the linked code crashes, an inline cache outliving the
  code block it points at. That was a misdiagnosis. Both variants free machine
  code through the same call, a property cache is owned by its own code block and
  dies with it, and calls into a block are reverted as it is destroyed, so nothing
  is left pointing at freed code. The crash of that session is better explained by
  the two register defects in the compiler fixed in this same batch.
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
- The JIT code-deletion threshold moved from 235 MB to 275 MB, ten megabytes
  above the collector's own absolute band (`JSC_IOS6_GC_ABSOLUTE_MB`), which
  moved from 225 to 265 the same night on live-device evidence that 225 sat
  inside ordinary navigation load and kept releasing full-collection
  suppression that did not need releasing. The two constants were always a
  paired ten-megabyte margin, one always firing just after the other's last
  resort; left at 235 the code-deletion valve would have started firing
  thirty megabytes *before* the collector's, on ordinary load, which is the
  same class of regression this pairing already exists to avoid one order of
  magnitude smaller than the first time it was caught.
- `ENABLE_POINTER_LOCK`, `ENABLE_APPLICATION_MANIFEST` and
  `ENABLE_PICTURE_IN_PICTURE_API` turned off; `OptionsIOS.cmake` force-defaults
  them on for `PORT=IOS` even though the upstream default is off, and this
  port never reaches any of the three. 32 KB of `__TEXT`, confirmed by
  isolating each candidate through source reading rather than the disable-and-
  see-what-breaks pass this repeats from an earlier session: sixteen of that
  earlier session's twenty-five `ENABLE_APPLE_PAY_*`/`ENABLE_WK_WEB_EXTENSIONS`
  flags turn out to be dead code on this tree regardless of their setting, and
  could not have owned any of the 254 KB once credited to the whole batch.
- `Ios6BlockReservationPool`, one shared 2 MB-granularity block-reservation
  pool for JSC's `MarkedBlock`-sized (16 KB) allocations, replacing three
  independently-growing copies in `FastMallocAlignedMemoryAllocator`,
  `GigacageAlignedMemoryAllocator` and `StructureAlignedMemoryAllocator`.
  `Structure`'s `!CPU(ADDRESS64)` `StructureID` encoding does not require its
  blocks to come from a separate address range on this port, so sharing one
  grower across all three is safe. Strictly reduces JSC's own contribution to
  32-bit address-space fragmentation from three families to one.
- `GlyphGeometryCache`'s upstream cap of 500,000 entries per
  `FontCascadeFonts` instance lowered to 20,000, and `ShapedTextCache`'s cap
  of 3,000 to 500. At roughly 176 bytes a slot in a sub-50%-loaded hash
  table, the old glyph-geometry cap alone bounded a single font's worst case
  above 180 MB on a 512 MB device — a valve sized for hardware this port
  does not run on. Neither cache commonly approaches even the lowered
  ceiling in ordinary use; both remain a guard against the pathological
  case (a feed rendering thousands of unique short strings against one
  font), not a limit on the common one.

### Refuted by measurement
- **The JSC optimization cost ceiling.** Upstream lowers it for 32-bit ARM in a
  block gated on Linux whose reasoning is about the architecture. Measured at the
  lower value across SoundCloud, The Verge, Google and Hacker News: 1629 DFG
  dispatches, none refused for cost. No code block on the real web comes near
  either ceiling, so the two values are indistinguishable.
- **A second DFG compiler thread.** The Darwin thread tuning is gated on ARM64, so
  armv7 falls back to one thread while that block would ask for two here. Two is
  worse: the mean age of a plan waiting in the queue rose from 267 ms to 330 ms,
  and the number waiting longer than half a second went from 82 to 195. With two
  cores and a busy main thread, the second compiler takes the time the first one
  needed.

- That the optimising JIT costs more than it returns on armv7: 20 s with it,
  24 s without.
- That WebAssembly was what the bot check needed: its script, 227 KB, does not
  mention WebAssembly at all.
- That the feed stopped loading because of a rate limit: the refusal carried
  `"require_login": true`, and the feed paginates once signed in.
- That the site's own polyfill loading was the memory cost of running an old
  UA: `core-js`, `regeneratorRuntime` and `Zone` are all absent from the live
  page, and every modern JS-language feature a React bundle would plausibly
  feature-detect for is native to the JavaScriptCore in this tree already.
- That decoded image memory could be cut by decoding to display size instead
  of source resolution: the port already does this (`ImageDecoderCG.cpp`,
  committed as part of the port's own baseline patches, not new). 48 cached
  images on a live feed cost 0.9–1.3 MB decoded — under the ideal
  decode-to-shown-size estimate for the same screen, not over it.
- That prefetching the other bottom-tab routes in a hidden iframe during idle
  time would hide their first-visit compile cost: it does not, on this build,
  because the disk bytecode cache only ever covers the four large startup
  bundles — confirmed by the cache directory holding the same four files
  before and after the prefetch ran. The 8 s a tab switch costs is not JS
  compilation; profiling during the transition shows no new bytecode misses
  on either the first or the second visit to a tab.
- That identical code folding could shrink the three shipped frameworks:
  the linker in this toolchain (Apple ld64/ld-prime) has no ICF support at
  all — `-Wl,-icf=all` and the two spellings after it fail with
  `ld: unknown options:`, and `man ld` carries no such entry. Not attempted
  further; there is nothing to attempt it with.
- That WebCore could be compiled `-Os` while keeping the interpreter at
  `-O3`: it already is, at `-Oz`, behind `WEBKIT_IOS6_SIZE_OPTIMIZED`, with
  the interpreter already carved out onto its own flags. Already done, more
  aggressively than proposed.
- That enabling LLVM's hot-cold code splitting would shrink the three
  frameworks: `__TEXT` came back byte-for-byte identical the first time (the
  flag reached the per-file bitcode emission, not the ThinLTO backend that
  actually generates code) and 1.0–1.6% *larger* the second time, once the
  flag was moved to where it does take effect. The pass trades size for
  instruction-cache locality by outlining cold blocks into their own
  functions with their own prologues; it does not reduce total code size on
  this codebase, and reverted cleanly.
- That merging the three independently-growing JSC block-reservation pools
  (Structure, Gigacage, FastMalloc) into one, and cutting `GlyphGeometryCache`
  and `ShapedTextCache`'s upstream desktop-scale caps, were behind a live
  jitter regression in the fixed top/bottom bars: reverting both did not stop
  it. The actual cause is upstream (`RenderLayerCompositor`, see Fixed, below)
  and predates this session. The pool merge and cache caps were real, safe,
  and unrelated to the regression they were first blamed for — reinstated
  the same night once that was established, verified clean on-device a
  second time (no crash, no code-deletion firing, comparable memory profile
  to the first measurement).

### Fixed
- The fixed top and bottom bars losing their position for one frame during a
  scroll that concurrently triggers a relayout (infinite-scroll appending
  content is the common trigger; the bottom bar sees it far more often than
  the top, because this port's layout is always whole-document and
  infinite-scroll appends near the bottom). `RenderLayerCompositor::flushPendingLayerChanges`
  commits new CALayer geometry on the web thread, unlocked, and only
  afterward republishes the UI thread's `ViewportConstraints` snapshot under
  `webFixedPositionContentDataLock`; a scroll tick landing in that gap
  combines a freshly-read layer offset with a stale constraint, producing a
  bar that is torn out of position for a frame. Diagnosed on both the live
  site and a deterministic repro added to `tests/scrollbench.html`. A fix
  exists behind `/tmp/native-flush-race-fix` (holds the existing lock across
  the commit-to-republish window, no measured scroll-performance cost) but is
  not yet merged: the synthetic repro's hit rate under the fix (0.1%, 3 of
  3111) is two orders of magnitude below the live-site visual estimate
  (12.5%, from an 8-frame sample), and that gap is not yet explained. Left as
  a branch pending a wider repro before it is trusted as the whole story.
