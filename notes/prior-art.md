# Prior art, and what it changes

## TLS is already solved — and already installed on the device

`com.skyglow.tlsfix` v1.1 is installed on the target iPhone 4S. It is a MobileSubstrate filter on
`com.apple.CFNetwork` that hooks `SSLSetIOFuncs`, `SSLHandshake`, `SSLRead`, `SSLWrite` and friends,
keeps the real `SSLContextRef` alive, and attaches an OpenSSL 1.1.1 shadow to it. CFNetwork keeps
driving the socket; OpenSSL does the crypto, negotiating TLS 1.0 through 1.3. The received chain is
rebuilt into a `SecTrustRef` and evaluated against the live system store, so certificate pinning
still works and installed profiles take effect.

Covers iPhoneOS 2 through iOS 9, built for armv6 and armv7.
Source: https://github.com/nfzerox/TLSFix — an independent second implementation using fishhook and
mbedTLS instead is at https://github.com/sqmrak/senko.
Root store refresh (the 2012 trust store is the other half of the problem):
https://tlsroot.litten.ca/

**Measured on the device**, through CFNetwork:

    https://www.threads.com/  -> HTTP 200, 525378 bytes, 0.48 s
    https://www.google.com/   -> HTTP 200,   2087 bytes, 0.20 s

Network and TLS are not a problem for this project. Note that command-line `curl` on the device
still fails — it does not go through CFNetwork, so the hook does not apply to it.

## The ARMv7 JIT is further away than it looked

Correcting an earlier assumption. Reverting the two 2026 commits is **not** sufficient, because
ARMv7 JIT on Darwin had already been switched off years earlier. From `safari-607-branch`
(January 2019) the gate reads:

    #if CPU(ARM_THUMB2) && OS(LINUX)

— Linux only. Everything else got `ENABLE_JIT 0` and `ENABLE_C_LOOP 1`. The last WebKit with a
working ARMv7-on-iOS JIT is `safari-605-branch` and earlier.

The 2026 removals were the end of a year-long teardown, not a sudden decision:

| Bug | Date | What went |
|---|---|---|
| 297353 | 2025-08 | ARMv7 IPInt disabled |
| 300320 | 2025-10 | OMG not built on ARMv7 |
| 303392 | 2025-12 | YARR JIT disabled |
| 305868 | 2026-01 | OMG/B3 dropped |
| 307206 | 2026-02 | caches disabled to cut memory |
| 309496 | 2026-03 | **JIT disabled** — *"no longer working after recent breakage"* |
| 320416 | 2026-08 | **ARMv7 JIT removed** — *"ARMv7 runs on CLoop now"* |

Restoring it therefore means: revert both removals, then also flip the Linux-only gate to include
Darwin, then fix whatever the March breakage was. Nobody has attempted this publicly — a search of
WebKit PRs, forks and issues turns up only the removal work itself.

## CyberKit — the closest real precedent

https://github.com/CyberKitGroup/CyberKit — a WebKit fork backported to older iOS, 255 stars,
development on hiatus since March 2025. **arm64 only, iOS 12 and up**, so not directly reusable, but
the techniques match what this port has had to do independently:

- Hand-written `.tbd` stubs for missing private frameworks, kept in an SDK-additions directory.
- Large edits to `PlatformHave.h` reverting `HAVE()` macros to historical values — the author calls
  this "probably the majority of CyberKit effort".
- ICU built from source and bundled (`Source/WTF/icu/compile_icu.sh`, ICU 76.1).
- Symbol and bundle-identifier renaming so the fork can coexist with the system WebKit.

Two things it does that this port has not yet done:

- **Raising the jetsam limit** with `memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES)`
  from a library constructor. Directly relevant at 512 MB.
- A note on size: their MobileMiniBrowser goes from 202 KB to 1.65 GB decompressed, because nothing
  can come from the dyld shared cache.

CyberKit does no libc++ work and no TLS work — on iOS 12 arm64 neither is needed.

## LightKit has no public source

Exhaustive search of GitHub and Canister (which indexes essentially every public Cydia repo) returns
nothing for `org.webkit.LightweightBrowser`, `LightKit`, or `libLegacyIOSRuntime`. WebKit's own
`Tools/` has never contained a `LightweightBrowser`. It is a private build using a bundle identifier
it does not own. Its binaries remain useful as a specification; there is nothing to read.

## What Threads actually costs

Measured by fetching the page and its scripts:

| | |
|---|---|
| initial HTML | 531 606 bytes |
| inline script inside that HTML | 414 724 bytes |
| external JavaScript | 5 536 699 bytes across 9 files, largest 1 165 862 |

Roughly **6 MB of JavaScript** before the first pixel of interface. Against a measured throughput of
about a million simple operations per second on the interpreter, this is the number that decides the
project.

## LightKit, re-examined (2026-08-24)

Installed at `/var/mobile/Applications/8A9AF981-…/LightKit.app` — a user app, not
a system one, which is why it is absent from `/Applications`.

Bundle layout is the same shape this port is building, only split further:
`JavaScriptCore.framework`, `WebCore.framework`, `WebKitLegacy.framework`, plus
`libWTF.dylib`, `libPAL.dylib`, `libbmalloc.dylib` and the 31 MB
`libLegacyIOSRuntime.dylib`.

### It ships an ARMv7 JIT

`nm` on its `JavaScriptCore` (16 MB, armv7):

| symbols | |
|---|---|
| `ARMv7Assembler` | 575 |
| `MacroAssemblerARMv7` | 386 |
| `LinkBuffer` | 246 |
| Baseline | 88 |
| `Yarr::YarrJIT` | 130 |
| DFG | 15 |
| FTL | 6 |

Baseline JIT and the regular-expression JIT are real; DFG/FTL are only
incidental references. So a JIT-enabled JSC does run on an iPhone 4S under
iOS 6 — the question is answered by a working binary, not by inference. Its
WebCore still carries 2025 features, so it is built from a checkout made before
trunk force-disabled `ENABLE_JIT` for `USE(JSVALUE32_64)` in March 2026, which is
exactly the plan already written down in `patches/armv7-jit/`.

### What it tunes

Very little. From its app binary:

- `setUsesPageCache:`
- `setTilingMode:` / `setTilingDirection:` with
  `restoreNormalTilingAfterScrollingOnMainThread:` — drop to minimal tiling while
  scrolling, restore afterwards
- `_setBrowserUserAgentProductVersion:buildVersion:bundleVersion:`

No `JSC_*` environment tuning, no cache-model calls.
