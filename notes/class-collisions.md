# Two WebKits in one process

The headless harness died with SIGBUS inside `WebKitInitialize()`. The cause was
visible in the objc runtime warnings printed just before it:

```
objc[9248]: Class WebPreferences is implemented in both
  /System/Library/PrivateFrameworks/WebKit.framework/WebKit and
  .../LegacyBrowser.app/Frameworks/WebKitLegacy.framework/WebKitLegacy.
  One of the two will be used. Which one is undefined.
```

221 classes collide: 88 `Web*` from WebKitLegacy against the system
`WebKit.framework`, and 133 more — the whole `DOM*` binding surface plus `WAK*`,
`WebEvent`, `WebScriptObject`, `WebLayer`, `WebAccessibilityObjectWrapper` —
against the system `WebCore.framework`.

Both system frameworks are in the process because the app links UIKit, and iOS 6
UIKit pulls in WebKit for `UIWebView`. dyld loads dependencies before the app's
own frameworks, so iOS 6's classes register first and ours lose. Every
`[WebView …]`, `[WAKWindow …]` and `[WebPreferences …]` call then lands in a 2012
implementation while our C++ expects a 2026 object layout.

## Fix

Rename ours, as LightKit did — its classes are `LegacyIOSWebView`,
`LegacyIOSWAKWindow`, `LegacyIOSWebEvent`.

`compat/stubs/ios6_class_prefix.h` is one `#define X LegacyIOSX` per colliding
class, force-included into every compile (C, C++, ObjC, ObjC++) and into the app.
The list is not guessed: it is the collision set the runtime itself reported.

Four places look a class up by name rather than by identifier, and a macro does
not reach inside a string literal:

- `WebCore/bridge/objc/objc_runtime.mm` — `WebScriptObject`, `WebUndefined`
- `WebCore/accessibility/ios/WebAccessibilityObjectWrapperIOS.mm` — `WebView`
- `WebCore/testing/Internals.mm` — `WebCoreBundleFinder`

They now use `IOS6_CLASS_NAME(x)`, which expands the macro before stringifying.

## Still duplicated, harmless

Eight compat stubs (`NSURLSession`, `NSItemProvider`, `CABackdropLayer`,
`LSAppLink`, `LSBundleProxy`, `NSPresentationIntent`, `NSDateComponentsFormatter`,
`_LSOpenConfiguration`) appear in both WebCore and WebKitLegacy because
`libios6compat.a` is linked into both. Neither exists on iOS 6, the two copies are
the same code, so whichever wins behaves identically.
