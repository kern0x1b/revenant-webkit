# Memory and caches on a 512 MB phone

What WebKit's memory machinery does on this device, and which knobs earn their
place. Written against WebKit 2.54; the values the port actually ships are in the
code, and the reasoning for each change is in its commit.

## The JavaScript heap

WebCore creates its VM with `JSC::HeapType::Large` (`Source/WebCore/bindings/js/CommonVM.cpp`).
`Heap::Heap` sets the first-collection threshold to
`min(Options::largeHeapSize() /* 32 MB */, ramSize * Options::smallHeapRAMFraction())`, and on
iOS `Options.cpp`'s `overrideDefaults()` raises `smallHeapRAMFraction` to 0.8 — so on a 512 MB
device the threshold is a flat 32 MB, and nothing is collected until the JS heap reaches it.

Every JSC option can be set from the environment before the first VM exists.
`Options::initialize()` reads `*_NSGetEnviron()`, which is live, and none of the three
frameworks has a `__mod_init_func` section, so nothing of WebKit runs before `main()` and the
loader's own `setenv()` is seen:

    JSC_largeHeapSize=4194304          # 4 MB instead of 32 MB

The related knobs do not earn their place:

- `smallHeapRAMFraction` only enters as `min(largeHeapSize, ramSize * fraction)`. Once
  `largeHeapSize` is 4 MB the fraction would have to drop below 0.008 to bind. Inert.
- `criticalGCMemoryThreshold` is counterproductive to lower. Its third effect caps eden at
  `ramSize * (1 - threshold) / 4`, so lowering the threshold *raises* the allowance: 25.6 MB at
  the 0.80 default, 57.6 MB at 0.55.

### Mini mode, and why it no longer applies

`VM::isInMiniMode()` is true whenever `!Options::useJIT()`. In mini mode
`Heap::useGenerationalGC()` returns false — every collection is a full collection — and sweeping
is synchronous, which is why collecting less often mattered more than usual.

This port restores the ARMv7 JIT, so the VM is **not** in mini mode: generational collection is
back, eden collections do most of the work, and the growth factors that mini mode short-circuits
are live again. Any advice written for the interpreter-only build — including the 4 MB heap floor
above — has to be re-measured before it is believed.

## Cache model

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

## Tiles

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

## Preferences

`+[WebView _setCacheModel:]` and the tile knobs above are reached through
`WebPreferences`. Any generated preference not exposed in a header is still reachable through
`-[WebPreferences _setBoolPreferenceForTestingWithValue:forKey:]` with the key from
`UnifiedWebPreferences.yaml` — and the defaults themselves are set in that file's WebCore column,
which is what the port edits rather than calling setters at runtime.

`_setMaxParseDuration:` overrides the 500 ms parser yield limit: raise it to cut runloop overhead
on a slow core, lower it for responsiveness.

Some knobs are dead in current trunk — hardcoded stubs that decide nothing: DNS prefetching, the
offline application cache (removed from WebKit entirely), `requestAnimationFrameEnabled`,
`linkPreloadEnabled`.

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
