# First page load on the device

`example.com` over HTTPS, iPhone 4S, iOS 6.1.3, headless harness:

```
[headless] WebKit initialised          6.1 MB
[headless] loading https://example.com
[headless] provisional load started   17.6 MB
[headless] load committed   0.54 s    19.6 MB
[headless] load finished    0.87 s    24.1 MB
```

TLS is handled by the pre-installed TLSFix; nothing in this build negotiates it.

## What it took

The crash that blocked everything was not in WebKit. Five separate faults, each
found by making the harness print its own backtrace — the device writes no crash
reports for this process:

1. **Two WebKits in one process.** UIKit pulls in iOS 6's WebKit, dyld loads it
   before the bundle's frameworks, and the runtime kept the 2012 classes. 221
   collisions. Fixed by prefixing ours `LegacyIOS`, as LightKit does — see
   [class-collisions.md](class-collisions.md).
2. **`WebCoreWebThreadLock` as a function.** WTF declares it as a function
   *pointer*; the compatibility layer defined a function with that name, the
   linker preferred it, and `InitWebCoreThreadSystemInterface` stored into
   `__TEXT`. Bus error.
3. **Constants declared as functions.** `NSProcessInfoPowerStateDidChangeNotification`
   and nine others were function stubs. CoreFoundation received the address of a
   stub where it expected a string.
4. **`icudt74_dat` stubbed.** A one-line stub shadowed the real 30 MB ICU data
   blob, so every data-driven ICU call failed — the first to notice was
   `uidna_openUTS46`, which WebKit asserts on.
5. **Soft links that trap.** PAL soft-links `UIAccessibilityDarkerSystemColorsEnabled`,
   `UITraitCollection`, and the semantic `UIColor`s. A missing one is not a
   degraded feature, it is `RELEASE_ASSERT` or an unrecognised selector.

Three of the five were self-inflicted: stubs written to satisfy the linker that
then shadowed something real. `build-compat.sh audit` now refuses to build a
compatibility archive that defines any symbol WebKit or ICU already defines.

## Left running degraded

Stubbed and reported once each at runtime:

- `CTFontShapeGlyphs`, `CTFontIsAppleColorEmoji`, `CTFontHasTable`,
  `CTFontGetPhysicalSymbolicTraits`, `CTFontIsSystemUIFont` — text shaping.
  Worth checking what the fallback path actually renders.
- `SecTrustGetTrustResult`, `_CFHostIsDomainTopLevel`
- `MGGetBoolAnswer`, `MGGetSInt32Answer` — device capability queries
- `dispatch_queue_attr_make_with_qos_class` — no QoS classes on iOS 6
- The AVFoundation media engine
- Memory pressure: `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` is iOS 8 and its
  predecessor `DISPATCH_SOURCE_TYPE_VM` returns no source here, so nothing
  notifies WebKit of pressure. On a 512 MB device this needs a real answer.
