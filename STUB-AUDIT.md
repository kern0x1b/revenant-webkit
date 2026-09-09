# Stub audit

Goal: no stub may answer success while doing nothing, and wherever the behaviour physically exists on
this system - or existed in WebKit's own history - the real implementation is used instead of a bridge.

## Scope, and what the first pass missed

The 2026-09-07 pass audited one file, `WebLegacyCompatibilityAPI.mm`, and concluded that "the rest of
the tree is genuinely implemented, not stubbed". That was wrong about `compat/`, which is 2,700 lines
of shims standing in for CoreText, CoreGraphics, Foundation and libdispatch API this release lacks, and
which had never been read end to end. A second pass on 2026-09-09 read all of it; what it found, and
what was done about it, is at the bottom of this file.

## Second pass, 2026-09-09: what `compat/` was doing

Fixed, each verified on the device:

- `vDSP_vaddi` returned zero and wrote nothing to its destination, so mixing 32-bit integer samples in
  the capture ring buffer silently dropped a channel. It adds two vectors now.
- `sqlite3_bind_blob64` answered `SQLITE_OK` and bound nothing - the shape that once made localStorage
  save nothing. Removed: the call site binds through `sqlite3_bind_blob` on this release, and if
  anything reaches for it again the link will say so.
- `kCTFontWeight*` and `kCTFontWidth*` were defined as CFStrings while the headers declare them as
  `CGFloat`. The linker matches by name, so every rung of the weight ladder was a pointer read as a
  float, and every `-apple-system` request resolved at Regular. Real values now.
- `kCTFontVariationAxesAttribute` was `#define`d to `kCTFontVariationAttribute`: an array read out of a
  dictionary, on every `@font-face` load. The port reads no variation axes at all now, which is the
  truth about this CoreText.
- `CTFontCopyColorGlyphCoverage` returns null, and the engine read that as "this font has no colour
  glyphs" rather than "not known". A font declaring the colour trait is now taken at its word - which
  is what WebKit itself did until that query became unconditional in 2025.
- The archive is built from a named list rather than an `ios6_*.o` glob, which had been keeping the
  retired Web Crypto bridge's stale objects as members long after its sources were deleted.

Known and deliberately left, with the reason:

- `CTFontCopyGlyphCoverageForFeature` returns null, so small caps are synthesized rather than real.
  No historical native path ever existed; upstream's own `#else` hardcodes the same answer.
- `CTFontDescriptorCreateWithTextStyle` resolves every Dynamic Type style to Helvetica, and
  `CTFontDescriptorGetTextStyleSize` answers one size for all of them. Dynamic Type is iOS 7; this
  system has two fixed interface sizes and no style scale. Shipping Apple's per-style table would be
  inventing data this system does not have.
- `CTFontGetSbixImageSizeForGlyphAndContentsScale` returns 0. Its only consumer is behind
  `isInGPUProcess()`, and WebKit1 has no GPU process.
- The cookie stubs (`+[WebView _allowCookies]`, `currentCFHTTPCookieStorage`) are untouched on purpose.

Everything below is the first pass, kept as-is.

## IMPLEMENTED (real logic added, builds+links clean)
All in `webkit-254/Source/WebKitLegacy/mac/WebView/WebLegacyCompatibilityAPI.mm`:
1. `+[WebView discardAllCompiledCode]` — was `{}` → `WebThreadRun(^{ GarbageCollectionController::singleton().deleteAllCode(JSC::DeleteAllCodeIfNotCollecting); })`. Reclaims JIT/bytecode under memory pressure (a lever this project actively tunes).
2. `+[WebView releaseFastMallocMemory]` — was `{}` → `WebThreadRun(^{ WTF::releaseFastMallocFreeMemory(); })`. Returns bmalloc free-list to the OS on memory warning.
3. `-[WebView _clearBackForwardCache]` — was `{}` → `WebThreadRun(^{ BackForwardCache::singleton().pruneToSizeNow(0, PruningReason::MemoryPressure); })`.
4. `-[WebFrame _markupStringFromRange:nodes:]` — was `return nil` → serializes the range's HTML via `serializePreservingVisualAppearance(makeSimpleRange(*core(range)), &nodeList, AnnotateForInterchange::Yes)`, returns markup + fills `nodes` with `kit(node)`. Backs rich (HTML) copy from UIWebDocumentView.
5. `-[WebFrame isPageBoxVisible:]` — `PrintContext::isPageBoxVisible(core(self), pageIndex)`.
6. `-[WebFrame pageNumberForElement::]` — `PrintContext::pageNumberForElement(core(element), FloatSize(w,h))`.
7. `-[WebFrame pageProperty::]` — `PrintContext::pageProperty(core(self), String::fromUTF8(name), pageNumber)`.
8. `-[WebFrame pageSizeAndMarginsInPixels:…]` — `PrintContext::pageSizeAndMarginsInPixels(core(self), …)`.
(5–8 = the AirPrint page-geometry group; low call-frequency but now correct.)
9. `-[WebView _setMinimumTimerInterval:]` — was `{}` → `core([self mainFrame])->settings().setMinimumDOMTimerInterval(Seconds(interval))` (used `Frame::settings()` directly, not `Frame::page()` which is a non-exported inline). Imports Page.h/Settings.h.

Second pass 2026-09-07 (WebLegacyCompatibilityAPI.mm, builds+links clean in build-254-rev):
12. `-[WebFrame _stringWithDocumentTypeStringAndMarkupString:]` — was `return markupString` → prepends the real doctype via `WebCore::documentTypeString(*document)` (exported, markup.h) then `stringByAppendingString:`. Backs full-document copy/serialize.
13. `-[WebFrame _suspendAnimations]` / `_resumeAnimations` — were `{}` → `[[self webView] page]->suspendActiveDOMObjectsAndAnimations()` / `resume…` (both WEBCORE_EXPORT on Page). Route via `[self webView] page]` to avoid the non-exported `Frame::page()` inline.
14. `-[WebView cssAnimationsSuspended]` / `setCSSAnimationsSuspended:` — were `return NO` / `{}` → suspend/resume the same Page API via `[self page]`; getter/state held in an objc associated object (category can't add an ivar). No-op when the flag is unchanged.

Safari-compat shims (`scratchpad/safari-compat.mm`, the injected dylib — built+signed, not yet pushed):
10. `WebKit::MemoryMeasure::taskMemory()` — was `return 0` → real resident size via `task_info(TASK_BASIC_INFO)`.
11. `WebCore::systemTotalMemory()` — was hardcoded 512 MB → real device RAM via `sysctlbyname("hw.memsize")` (device-general; falls back to 512 MB).

Imports added: BackForwardCache.h, GarbageCollectionController.h, DeleteAllCodeEffort.h, FastMalloc.h,
WebCoreThreadRun.h, PrintContext.h, FloatSize.h, Range.h, SimpleRange.h, markup.h, DOMElementInternal.h,
DOMNodeInternal.h, DOMRangeInternal.h.

Also removed the dormant `/tmp/native-strings.log` diagnostic from `WebNSStringExtrasIOS6.mm` (was only
for the share-label investigation).

Binary is built + laid out in `dist/rev-sys-fw/`. NOT yet pushed (device offline). Push WebKit when back.

## SKIPPED — with reason (need device or carry risk)
- `+[WebView _allowCookies]` / `_setAllowCookies:` (currently `return YES` / no-op). Real backing exists
  (NSHTTPCookieStorage cookieAcceptPolicy). SKIPPED: changing the cookie-accept policy autonomously risks
  the anti-bot cookie session this project depends on; must verify on device that honoring the toggle
  doesn't break logged-in sessions. Low confidence it is even called on this device.
- `-[WebFrame imageForNode:allowDownsampling:drawContentBehindTransparentNodes:]` (`return nullptr`).
  Real backing: `WebCore::snapshotNode(LocalFrame&, Node&, SnapshotOptions&&)` → `RefPtr<ImageBuffer>`.
  SKIPPED: needs SnapshotOptions construction + an ImageBuffer→CGImageRef bridge with careful CGImage
  ownership/lifetime, unverifiable without device; only exercised by node-image drag/share.
- `WebCore::currentCFHTTPCookieStorage()` (`return 0`, in safari-compat.mm). Could return the process
  default CFHTTPCookieStorage. SKIPPED: same anti-bot cookie-session risk as `_allowCookies`; cookies
  currently work with the NULL fallback (WebCore uses its default), so not worth disturbing without device.

## LEGIT NO-OPS (feature genuinely absent in 2.54 — correct to leave empty)
formElementsCharacterCount, _numberOfActiveAnimations/_pauseAnimation/_pauseTransitionOfProperty (DRT),
clearPPTStats/getPPTStats (perf telemetry removed), counterValueForElement / _computedStyleIncludingVisitedInfo
(DRT/inspector), _allowsRoundingHacks, _shouldUseFontSmoothing, flattened-compositing-to-bitmap,
_shouldFlattenCompositingLayers, _inViewSourceMode, _needsPreHTML5ParserQuirks, _needsUnrestrictedGetMatchedCSSRules,
NPAPI plugin category (_videoProxyPluginForMIMEType, WebPluginController, _web_makePluginSubviewsPerformSelector),
the whole WebApplicationCache class + _transferApplicationCache (AppCache removed), remote-inspector methods +
sharedWebInspectorServer, the WebHTMLView Mac/AppKit category (_autoscroll, _updateControlTints,
attachRootLayer/detachRootLayer/drawLayer:inContext:, layoutToMinimumPageWidth:, highlighters, etc. — iOS
routes through UIKit+WebChromeClientIOS, not WebHTMLView), _shouldDeleteRange: (returns YES = correct default),
WebPDFViewPlaceholder mmap callbacks, WebMIMETypeRegistry +initialize, every `finalize` (GC-only, never called
under MRR), the WebPreferences accessor block (:98–331, actually REAL — persists values faithfully).

## UNCERTAIN — deliberately left, revisit WITH device
- `+drainLayerPool` `{}` — LayerPool::drain() exists but was **deliberately reverted before** (caused live
  fixed-bar jitter; see memory project_legacy_webkit_layerpool_reverted). Do NOT re-enable without re-test.
- `-_touchEventRegions` `nil` — has an on-device comment: reporting a region made UIKit deliver neither mouse
  nor touch events. Deliberate.
- WebFixedPositionContent lockLayers/unlockLayers/removeLayer:insideLayerSync:/addOrUpdateLayer:… — superseded
  by WebChromeClientIOS::updateViewportConstrainedLayers → setViewportConstrainedLayers:stickyContainerMap:
  (real path). Vestigial; confirm nothing calls the old names before deleting.
- _setNetworkStateIsOnline: — NetworkStateNotifier drives online/offline natively; redundant unless Safari
  overrides manually.
- WebHistoryItem visit-count/daily/weekly/transient block, _setGlobalHistoryItem:/_globalHistoryItem,
  _addVisitedLinksToPageGroup: (opaque void* group) — WK history-DB internals. NOTE: `_visitedURL:withTitle:…`
  is ALREADY real (adds to WebHistory), so per-URL visit recording + :visited styling already work; only the
  bulk-seed `_addVisitedLinksToPageGroup:` stays empty (opaque group param, low value). Verified live 2026-09-07:
  new build loads in real Safari, no crash, _commonInitialization 286ms clean.
- WebCache +addImageToCache:forURL:/+removeImageFromCacheForURL: — only matters if the host preloads images.
- _nodesFromList:, _smartDeleteRangeForProposedRange: (returns input → no smart-delete), isSingleLine/set — touch
  the LIVE field editor (address bar); a wrong smart-delete range could over-delete there. Real Editor backing
  exists but defer to device to avoid regressing the now-working keyboard.

Implemented in the 2026-09-07 second pass (were here): _suspendAnimations/_resumeAnimations,
cssAnimationsSuspended/set, _stringWithDocumentTypeStringAndMarkupString: — see IMPLEMENTED #12–14.

## RESOLVED 2026-09-07 — share sheet system-activity labels were blank
Root cause (found by device probes + symbolicating the iOS 6 dyld cache): our UIStringDrawing measurement
returned the glyphs' typographic bounds as the line height (Helvetica 12: `ceil(ascent)+ceil(descent)+ceil(leading)`
= 13) instead of the font's own line height (`UIFont.lineHeight` = 15). `-[UIActivityButton titleRectForContentRect:]`
computes the title's line count as `floor(measuredTitleHeight / UIFontLineHeight)`; a single-line title measured
at 13 gave `floor(13/15)=0` → title label frame height 0 → never drawn (Safari's own "Add to…" activities wrapped
to 2 lines, measured tall enough, so they showed — which is why only the system single-line ones were blank).

Fix (WebNSStringExtrasIOS6.mm, `fontLineHeight()` used by `lineSize` + the drawInRect `step`): when UIKit hands us
a UIFont object (all chrome), take its own `-lineHeight`; raw CTFonts (web content) keep the typographic height,
so web layout is unchanged. Verified live: UIKit itself now returns titleRect height 15 (single) / 30 (two-line),
all labels render, two-line "Add to Home Screen"/"Add to Reading List" now show both lines, status bar/toolbar/
address bar unregressed. NOT a swizzle — the measurement is the root; the temporary UIActivityButton swizzle used
during diagnosis was removed.

## Next (needs the device back online)
1. Push the rebuilt WebKit (`dist/rev-sys-fw/WebKit.framework/WebKit`) and smoke-test the browser still works.
2. Verify the 8 implemented methods do no harm (memory ops fire under memory warning; HTML copy; printing).
3. Revisit the 3 skipped items (cookies, imageForNode, timer) with the device.
4. The share-label SharingUI dive.
