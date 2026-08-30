# Tuning WebKit for 512 MB and no JIT

Findings from reading WebKit trunk. File paths are as of August 2026.

## The three knobs that matter most

### 1. The JavaScript heap never collects early enough

WebCore creates its VM with `JSC::HeapType::Large` (`Source/WebCore/bindings/js/CommonVM.cpp`).
`Heap::Heap` then sets the first-collection threshold to
`min(Options::largeHeapSize() /* 32 MB */, ramSize * Options::smallHeapRAMFraction())`.
On iOS, `Options.cpp`'s `overrideDefaults()` raises `smallHeapRAMFraction` to **0.8**, so on a
512 MB device the threshold is a flat **32 MB — no garbage collection at all until the JS heap
reaches 32 MB**.

Set through the environment before the first VM exists. `Options::initialize()` reads
`*_NSGetEnviron()`, which is live, and none of the three frameworks has a `__mod_init_func`
section — nothing of WebKit runs before `main()`, so the app's own `setenv()` is seen:

    JSC_largeHeapSize=4194304          # 4 MB instead of 32 MB

That is the whole list. The others do not earn their place:

- `smallHeapRAMFraction` only enters as `min(largeHeapSize, ramSize * fraction)`. Once
  `largeHeapSize` is 4 MB the fraction would have to drop below 0.008 to bind. Inert.
- `mediumHeapRAMFraction` and the small/medium/large growth factors are read only by the
  non-mini branch of `proportionalHeapSize()`, which we never reach.
- `criticalGCMemoryThreshold` is **counterproductive to lower**. Its three effects are forcing a
  full collection, sweeping synchronously, and capping eden at `m_maxEdenSizeWhenCritical`. In
  mini mode the first two are already unconditionally on, and the third is
  `ramSize * (1 - threshold) / 4` — so lowering the threshold *raises* the allowance. At the
  0.80 default that cap is 25.6 MB; at 0.55 it would be 57.6 MB.
- `miniVMHeapGrowthFactor` (1.20) is the live growth factor, but it applies to a heap that now
  starts at a 4 MB floor: 20% of a live heap of a few MB is noise next to the 32 MB floor it
  replaces, and halving it doubles the number of full, synchronously-swept collections on one
  slow core. Left alone.

`VM::isInMiniMode()` is true whenever `!Options::useJIT()`, and `proportionalHeapSize()` then
short-circuits to `miniVMHeapGrowthFactor`.

Two consequences of mini mode worth planning around: `Heap::useGenerationalGC()` returns false, so
**every collection is a full collection**, and sweeping is synchronous. Collecting less often
matters more than usual.

### 2. Cache model

`+[WebView _setCacheModel:]` derives everything from the model and the RAM size. At 512 MB:

| | DocumentViewer | DocumentBrowser | PrimaryWebBrowser |
|---|---|---|---|
| back-forward cache pages | 0 | 2 | 2 |
| MemoryCache total | 16 MB | 16 MB | 32 MB |
| NSURLCache memory | 0 | 1 MB | 8 MB |
| tile layer pool | 12 MB | 12 MB | 24 MB |

**Do not set a cache model at all.** This reverses the earlier advice. `+_setCacheModel:` runs only
off the cache-model-changed notification, and on iOS `+standardPreferences` — what an unnamed
`WebView` gets — is built with `sendChangeNotification:NO` and never posts it. So on this app the
model has never been applied, and WebCore's own constructor defaults are tighter than every rung of
the ladder above: `MemoryCache` 8 MB total, `BackForwardCache::m_maxSize` 0, tile layer pool 0.

`DocumentViewer`'s appeal is its dead capacity of zero, but that is worth nothing here.
`deadCapacity()` is `clamp(m_capacity - m_liveSize, m_minDead, m_maxDead)`, so under the 8 MB
default a page whose live resources already exceed 8 MB *also* gets a dead capacity of zero. What
changes is `liveCapacity()`, which is what `pruneLiveResources` destroys decoded image data against:
8 MB today, 16 MB under `DocumentViewer`. On a heavy page the model would retain roughly 7.6 MB
**more** decoded image data, and hand the tile layer pool 12 MB it does not have today.

`setAutomaticallyDetectsCacheModel:NO` is **not** required on iOS either, correcting the same note.
The promotion happens in `-_checkDidPerformFirstNavigation`, which sits inside
`#if !PLATFORM(IOS_FAMILY)`; the iOS `-_didCommitLoadForFrame:` does not call it.

If a model ever is set: it is process-global, ratcheting up on any higher value and only recomputing
a maximum when a preference goes down, and it never shrinks the `NSURLCache` capacities — `std::max`
against the existing value on both memory and disk.

`setUsesPageCache:` decides nothing while the capacity is zero: `BackForwardCache::canCache()`
returns false on `!m_maxSize` before it looks at `Settings::usesBackForwardCache()`.

### 3. Tiles

`LegacyTileCache` uses a hardcoded 512×512 logical tile (`LegacyTileCache.h`, `m_tileSize`) with no
setter anywhere. Tiles are clipped to the host layer's bounds, so on a 320-point-wide viewport a
tile is 320×512 points — 640×1024 px at 2× screen scale, **2.5 MB of backing store**. The grid's
own accounting still charges the unclipped 4 MB.

The speculative cover rect is the visible rect inflated by half a width each side and a full height
above and below — 2w × 3h, so 320×1440 here, three to four tiles.

    [wakWindow setTilingMode:kWAKWindowTilingModeMinimal];

collapses the cover rect to exactly the visible rect and centres the grid so 480 points fall inside
one 512-point row: one tile. `removeAllNonVisibleTiles` gives manual control. `keepsZoomedOutTiles`
already defaults to NO, which is what keeps the second grid from ever being allocated.

Dropped tile layers go to `LegacyTileLayerPool` rather than being freed, so the pool capacity has to
be zero for the drop to return memory promptly. It already is: the only caller of
`setLayerPoolCapacity` is `+_setCacheModel:`, which never runs here.

## Bytecode caching is not available to us

This corrects an earlier assumption. `-[JSScript cacheBytecodeWithError:]` exists, but:

- **WebCore never uses it.** `CachedScriptSourceProvider` does not override `cachedBytecode()`, so
  script loads always return null. There are zero references to `CachedBytecode` in `Source/WebCore`
  and zero to "bytecode" in `Source/WebKitLegacy`.
- **A cache cannot be shipped in a bundle.** `GenericCacheEntry::isUpToDate` validates the Mach-O
  UUID of the JavaScriptCore binary *and* `kern.bootsessionuuid` — so any cache is invalidated on
  every reboot.

What remains is the in-memory `CodeCacheMap` (10 s working set, 16 MB, 2000 entries, all
hardcoded). Keep `useCodeCache` and `useSourceProviderCache` on.

The only way to get precompiled bytecode is to run our own scripts through the `JSScript` API in a
`JSContext` we control, and accept one warm-up write per boot.

## Preferences worth setting

| Knob | Effect |
|---|---|
| `setCacheModel:` + `setAutomaticallyDetectsCacheModel:NO` | see above |
| `setUsesPageCache:` | admission to the back-forward cache; capacity still comes from the model |
| `_setMaxParseDuration:` | overrides the 500 ms parser yield limit. Raise to cut runloop overhead on a slow core, lower for responsiveness |
| `setWebGLEnabled:NO`, `setWebAudioEnabled:NO` | both default to YES in WebKitLegacy |
| `setAcceleratedDrawingEnabled:NO`, `setCanvasUsesAcceleratedDrawing:NO` | default YES on iOS; drops GPU-backed backing stores |
| `setAcceleratedCompositingEnabled:NO` | each composited layer is a backing store outside the tile budget |
| `setAllowsAnimatedImages:NO` | stops per-frame decode churn |
| `setHiddenPageDOMTimerThrottlingEnabled:YES` | defaults to NO in WebKitLegacy |
| `_setTextAutosizingEnabled:NO` | removes a style and layout pass |

Dead knobs — hardcoded stubs in current trunk, do not bother: DNS prefetching, offline application
cache (removed from WebKit entirely), `requestAnimationFrameEnabled`, `linkPreloadEnabled`.

Any generated preference not exposed in the header is still reachable through
`-[WebPreferences _setBoolPreferenceForTestingWithValue:forKey:]` with the key from
`UnifiedWebPreferences.yaml`.

## Memory pressure

`WebInstallMemoryPressureHandler()` is already called from `-[WebView _commonInitialization]`, so
the low-memory handler is registered — only the trigger was missing. This system refuses the
ungraded VM pressure source (`dispatch_source_create` returns nothing rather than failing) and the
graded one is iOS 8, so nothing ever reached the handler.

The signal this kernel does export is `kern.memorystatus_level`, the system-wide free-memory
percentage jetsam itself decides on; `LegacyTileCache` already sizes its tile budget from the same
sysctl. `MemoryPressureHandler::install()` now polls it on `s_minimumHoldOffTime` and grades it by
the bands `LegacyTileCache` uses: below 15% critical, below 30% a warning.

Both `WTF::memoryFootprint()` and `WTF::memoryStatus()` were reading `phys_footprint` out of
`task_vm_info`, which this kernel answers at revision 0 — the field is never written and the
returned value was uninitialised stack. They read `MACH_TASK_BASIC_INFO`'s `resident_size` here,
which is also what jetsam judges by on this release. That mattered beyond the pressure handler:
`memoryStatus()` feeds JSC's `Heap::overCriticalMemoryThreshold()`.

`UIApplicationDidReceiveMemoryWarningNotification` is the same pressure graded by the kernel rather
than by us, and is wired to `+[WebView _releaseMemoryNow]` in the app.

Also available: `+[WebCoreStatistics garbageCollectJavaScriptObjects]`, `returnFreeMemoryToSystem`,
`purgeInactiveFontData`, `+[WebCache empty]`.
