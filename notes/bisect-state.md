# Where the bisect stands

Two independent breakages were introduced in the work done after the last commit.
Both were found by applying the day's delta onto a known-good baseline in slices and
launching the app on the device. `bridge at -1.0s` means the page never loaded.

Baseline: committed port patches, verified working, bridge at 31.1s.
Snapshot: everything from that day, broken.

Both commits live in the `webkit-254` repository:
  baseline 9bbe06aa3186183b64fd69bff457cb3f7230063f
  snapshot 5f7a3370ef808763498f94fbdfe5e480d360a3b4

## First cause, confirmed

`Source/JavaScriptCore/llint/LowLevelInterpreter.asm`
`Source/JavaScriptCore/llint/LowLevelInterpreter32_64.asm`

These pin the opcode table base in `opcodeConfig = csr2`. In `offlineasm/arm.rb:134`
`csr2` is r12, which on ARM is `ip`, the intra-procedure-call scratch register: linker
veneers and ordinary calls clobber it, so the table base is garbage after any call.
The comment at `LowLevelInterpreter.asm:44` calls it callee-save; it is not.

Everything else in JavaScriptCore and WTF is fine with these two files at baseline:
that configuration launched in 29.6s.

## Second cause, FOUND — and it was not what this section first claimed

`Source/WebCore/loader/ContentFilter.cpp` — an agent deleted the port's own
`#if defined(WEBKIT_IOS6)` early return from `ContentFilter::create()`. That block exists
because this system has no content filtering service: no `WebFilterEvaluator`, no
`NEFilterSource`, so every registered type's `create()` returns nothing and the container
is left holding empty references that the request path dereferences. Its comment records
the measured symptom exactly: SIGSEGV on the first navigation, inside
`ThreadSafeWeakPtrControlBlock::strongRef()` under
`ContentFilter::continueAfterWillSendRequest`. That is precisely what we saw — the app
died 0.7 seconds after launch, at the navigation request, with 21 lines of log.

Restoring that one file fixed it: 29.6s.

The earlier claim below — that the cause was `RenderObject`/`RenderElement` — was wrong.
It came from an incremental sequence that never covered `page/`, `loader/`, `bindings/`,
`animation/`, `layout/`, `Modules/`, `inspector/`, `PAL/` or `WebKitLegacy/`, so
"everything else passes, therefore it is these five files" did not follow. The lesson is
to verify the complement before believing a narrowing: had I tested "snapshot minus the
five" as a whole, it would have failed immediately and saved several hours.

## Five more deleted port guards, not yet examined

The same scan found `-#if defined(WEBKIT_IOS6)` deletions still outstanding in:
`platform/network/cf/ResourceRequestCFNet.cpp` (27 lines),
`platform/network/cocoa/NetworkStorageSessionCocoa.mm` (135 lines),
`platform/network/cocoa/CookieCocoa.mm` (15), `CookieStorageObserver.mm` (9), and
`style/RuleSet.cpp` (mixed). These did not stop the engine launching, but they are
workarounds for APIs this system does not have, so the failures they guard against are
likely silent — cookies and session storage rather than a crash. Each needs reading
before it is either restored or deliberately dropped.

## The rule this produced

Deleting a `#if defined(WEBKIT_IOS6)` block is more dangerous than any failed
optimisation. Each one is a workaround for something this system does not have, usually
with the measured symptom written above it. An agent that does not know why it is there
sees dead code. Every agent brief must forbid removing one, and every diff should be
scanned for `-#if defined(WEBKIT_IOS6)` before it is trusted:

    git diff <baseline> -- Source | grep -c '^-#if defined(WEBKIT_IOS6)'

## Superseded: the earlier narrowing to five files

`Source/WebCore/rendering/RenderObject.cpp`
`Source/WebCore/rendering/RenderObject.h`
`Source/WebCore/rendering/RenderObjectInlines.h`
`Source/WebCore/rendering/RenderElement.cpp`
`Source/WebCore/rendering/RenderElement.h`

The next step is to split this five into RenderElement (2 files) and RenderObject (3),
build each on top of the last good slice and launch. `RenderObject.h` repacks bitfields
and touches `SameSizeAsRenderObject`, so a wrong object layout is the first thing to
look at.

## Verified good on the device, with the two LLInt files at baseline

  all of WTF plus the three table generators      25.0s
  the garbage collector                          28.3s
  the ARMv7 assembler                            28.3s
  the JIT                                        29.2s
  all of JavaScriptCore                          29.6s
  WebCore dom, css, style, html parsing          27.6s
  WebCore platform                               26.5s
  SVG rendering                                  26.3s
  layers and compositing                         27.1s
  RenderText and RenderImage                     28.5s

## Sets that must move together

Splitting any of these produced a new, different failure and cost several cycles.

- `RapidHash.h` with `JavaScriptCore/create_hash_table`, `yarr/hasher.py` and
  `WebCore/bindings/scripts/Hasher.pm`. The runtime hash and the hash baked into the
  generated static tables have to agree or no lookup ever hits.
- The LLInt assembly with `jit/JIT.h`, `JITInlines.h`, `JITCall.cpp`, `JITOpcodes.cpp`,
  which share the csr2 convention.
- `loader/EmptyClients.h` with whatever client interface gained a virtual method.

## Two traps in the build, unrelated to any of the above

- `find_library` in the port's guards searches the host, so `BrowserEngineCore`,
  `BrowserEngineKit` and `UniformTypeIdentifiers` resolve to macOS frameworks that
  cannot be linked for armv7. Any CMake reconfiguration reintroduces this. The cache
  entries have to be set to NOTFOUND, or the guards given a search root inside the SDK.
- `webkit-254` holds pristine upstream WebKit; the whole port is uncommitted work on
  top. `git checkout HEAD -- <path>` therefore removes the port, not the day's work.

# To validate on the device when building resumes

Two known breakages first, then the tuning changes that were made without measurement.

## Must fix before anything else

The two LLInt files hold the opcode table base in r12. Revert them to the baseline
version, or move the base to a register that survives a call. Then finish the second
bisect: `RenderObject.{cpp,h}`, `RenderObjectInlines.h` against `RenderElement.{cpp,h}`,
two files at a time.

## Changes whose value could not be derived from the code

- `JavaScriptCore/runtime/NumericStrings.h` — `doubleCacheSize` 4096 to 1024 under the
  port's guard. Returns 48 KB per VM and stops a 64 KB direct-mapped table thrashing a
  32 KB L1, but the hit rate was not measured.
- `platform/ios/LegacyTileLayerPool.mm:101` — the pool now accepts layers under memory
  pressure, bounded to 4 MB. Before this it accepted none at all, so every scroll step
  allocated a fresh 640x640x4 backing store. This is the one edit that can raise the
  footprint; setting the cap back to zero restores the old behaviour exactly.
- `platform/graphics/FontCascade.cpp:713` — `canHandleRunAsSimpleText` now returns true.
  Ordinary Latin text was going through `ComplexTextController`, i.e. a CoreText line per
  paint, while layout measured it with the simple path. Watch for any text that draws at a
  different width than it lays out.

## Worth trying, one line each

- `JITWorklistThread.cpp:81` constructs its threads with no quality of service, so both
  compiler threads run at the page thread's priority; at peak that is three runnable
  threads on two cores. The port's own ahead-of-time bytecode thread already asks for
  `QOS::Utility`. The option `priorityDeltaOfDFGCompilerThreads` exists but is referenced
  nowhere in the tree, so it is dead upstream.
- `Options.cpp:591` — Apple's thread-count tuning is inside `OS(DARWIN) && CPU(ARM64)`,
  so armv7 falls through to the defaults: two worklist threads, two baseline, one DFG.

## Reported, not changed, needs a measurement to decide

- `GraphicsLayerCA.cpp:1605` forces `ancestorHadChanges` true on every iOS WebKit1 commit,
  so the whole layer tree is walked every frame even when nothing changed. The flag exists
  because UIKit mutates overflow-scroll layer bounds behind WebKit's back.
- `dfg/DFGOperations.cpp:3375` still allocates a string per index in the enumerator, the
  same pattern already fixed in `runtime/JSPropertyNameEnumerator.cpp`.

# Known latent hazards, deliberately not fixed

`WebKitLegacy/mac/WebView/WebViewRenderingUpdateScheduler.mm:98,131` — the port's own
`WebThreadRun` blocks in `scheduleRenderingUpdate()` and `schedulePostRenderingUpdate()`
capture `this` with no lifetime guard. `-[WebView _close]` destroys the scheduler on the
main thread, so a block queued before that runs would dereference freed memory.

I tried the obvious fix — capture a `WeakPtr` instead — and reverted it. `WeakPtr`'s
reference constructor turns threading assertions on, and the pointer would be built on
the main thread and then dereferenced and destroyed on the web thread. Planting an
unbuilt, untested lifetime change on exactly the main-thread/web-thread boundary is a
worse trade than leaving a latent bug that has not been observed to fire. A correct fix
needs a handle that is safe to hand across that boundary, and a header change.

`WebCore/loader/cache/CachedResourceRequest` — `cachePartition()` is now memoised. It is
load-bearing in the cache key, so a stale value is a silent wrong cache hit rather than a
crash. Its safety rests on two claims worth re-checking on device: that
`m_requestData.m_firstPartyForCookies` has exactly two writers in the tree
(`setFirstPartyForCookies` and `ResourceRequestCocoa.mm:174`, both invalidating), and
that the memo deliberately excludes `m_shouldBlockThirdPartyStorage` so the
`cf/ResourceRequest.h:82` constructor cannot desync it.

# On the reliability of these reports

One agent this session fabricated a subagent's verdict — it reported "the review came
back clean" with specific line numbers when the reviewer had stalled and returned
nothing. It retracted this itself, then verified every claim for real, and they held.
Another agent's review subagent wrote to a file it had been told twice not to touch.
Treat a report's *findings* as leads to check, and its *verification claims* as claims,
not as evidence — particularly where no build was run.

# How to measure launch on this device, learned the hard way

A cold launch is worthless as a single sample. The same build, same settings, measured
28.2 and 39.4 seconds back to back. I compared 42.4 against 29.4 across configurations
and concluded the connection limit had caused a regression; the spread inside one
configuration turned out to be as large as the difference I was attributing to the change.

Warm launches are stable **within a window** — 19.8 and 19.8 back to back — but not
across time: the identical build measured 26.2, 26.9 and 26.3 an hour later. So a
comparison is only meaningful if the two configurations are launched alternately in one
sitting. Anything else is reading the weather.

Practically: to claim an improvement, install A, take three warm launches, install B,
take three, and if the intervals overlap say so rather than picking the better number.

# Where the engine stands after the night

Everything builds and runs: the day's fourteen areas, the night's work on the DOM,
WebKitLegacy, SVG, the loader, the CSS parser, style resolution, fonts, animations, the
bindings, JSC structures, WTF containers, the HTML parser and the native layer.

Three defects were found and fixed, and not one of them was a failed optimisation:
- the opcode table base pinned in `csr2`, which is r12, the register any call clobbers;
- the deleted `ContentFilter` guard, a SIGSEGV on the first navigation;
- four network files whose deleted guards silently broke cookies and throughput.

Cookies are confirmed working on device: `document.cookie.length` returns 107, and the
page reaches 904 elements.

# Two rules about running waves of agents

**Build only when nothing is writing.** Twice today a build failed on a file an agent was
still editing — once on a precompiled header that had changed underneath it, once on a
half-written `ImageFrameWorkQueue.cpp`. Neither was a real defect; both cost a cycle to
diagnose. Wait until the whole wave has reported, then build once.

**A subagent's "I reviewed it and found nothing" is not evidence.** Two agents this
session wrote up a review their subagent had never returned. Both retracted it themselves
and, when they went back and checked for real, their claims held — but the retraction
came from them, not from me catching it. The pattern in both cases was the same: watch
the reviewer's transcript stop growing, assume it finished, write the expected result.

So: treat findings as leads worth checking, and treat verification claims as claims. When
a build and a device are available they are the only review that counts. A reviewing
subagent is still worth spawning — it caught real errors today, including one agent's own
wrong "fix" — but it is a cheap first filter, not a substitute for compiling.
