# Substituting the system WebKit

A plain `UIWebView`, created by UIKit's own glue, running on our WebKit 2.54
engine. Measured working on the iPhone 4S (iOS 6.1.3) on 2026-08-27:

    text: hello from the engine
    user agent: Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X)
                AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148

The user agent is the giveaway: iOS 6's own engine is AppleWebKit/536.

## Why this and not the hand-written glue

Every gesture, every scroll, every text-selection behaviour that UIKit's
`UIWebBrowserView` already implements is behaviour we would otherwise write and
maintain ourselves. Substituting the engine underneath UIKit gets all of it at
once, and it is UIKit's code that keeps working when the next case appears.

## How it works

The system engine lives in the dyld shared cache, not on disk, so there is no
file to replace - and replacing it system-wide would put our engine under Safari
and Mail too. Instead `DYLD_FRAMEWORK_PATH` makes dyld prefer our copies, for
one process only:

    DYLD_FORCE_FLAT_NAMESPACE=1 \
    DYLD_FRAMEWORK_PATH=<bundle>/Frameworks \
        ./app

The frameworks have to sit at the names UIKit asks for, with the system install
names, so `WebKitLegacy` is laid out as `WebKit.framework/WebKit`:

| our build | laid out as | install name |
|---|---|---|
| `WebKitLegacy.framework/WebKitLegacy` | `WebKit.framework/WebKit` | `/System/Library/PrivateFrameworks/WebKit.framework/WebKit` |
| `WebCore.framework/WebCore` | same | `/System/Library/PrivateFrameworks/WebCore.framework/WebCore` |
| `JavaScriptCore.framework/JavaScriptCore` | same | unchanged, already matches |

Cross-references between them must use those same system paths, not
`@executable_path`, so that the substitution catches them too.

## The class prefix comes off

`compat/stubs/ios6_class_prefix.h` renames 224 classes so that our engine can
share a process with the system one. Under substitution the system engine is
never loaded, there is nothing to collide with, and UIKit needs the classes
under their real names - it links `_OBJC_CLASS_$_WebView`, not the prefixed
spelling. `configure-webkit-254-sys.sh` configures that build into
`build-254-sys`; `configure-webkit-254.sh` and `build-254` still produce the
prefixed engine the current app uses.

## Why the flat namespace is needed

iOS 6 exported the Objective-C DOM (`DOMElement` and 16 siblings) from WebCore.
2.54 moved those classes to WebKitLegacy. UIKit's undefined symbols record which
library is expected to supply each one, so under the normal two-level namespace
dyld looks for `DOMElement` in our WebCore and does not find it.
`DYLD_FORCE_FLAT_NAMESPACE=1` drops the library ordinal and lets any loaded
image satisfy the symbol.

The cost is a set of "class is implemented in both" warnings: our compat stub
classes (`NSURLSession`, `UITraitCollection`, `LSAppLink` and others) are
compiled into both WebCore and WebKitLegacy, and with a flat namespace the
runtime sees the duplicates. Worth fixing by giving each stub a single home.

## Getting the variables to a SpringBoard-launched app

iOS 6's dyld ignores `LC_DYLD_ENVIRONMENT`, so the variables cannot be baked
into the executable, and SpringBoard does not pass an environment through.
What works, measured: the app sets the variables itself and re-executes:

    if (!getenv("DYLD_FRAMEWORK_PATH")) {
        setenv("DYLD_FRAMEWORK_PATH", <bundle>/Frameworks, 1);
        execv(self, argv);
    }

`execv` keeps the pid, so SpringBoard's launch handshake survives, and dyld
reads the variables on the second exec.

## What UIKit actually needs

Measured from the shared cache, not guessed. Across the 18 system libraries that
import from WebKit, WebCore and JavaScriptCore, **147 symbols** are imported in
total; UIKit itself uses 80. `tools/dsc-imports.py` and `tools/objc-surface.py`
do the counting.

The one thing that is not a symbol: UIKit gets its `WKWindowRef` by sending
`-[WAKWindow _windowRef]`, an accessor 2.54 dropped along with the C window
layer. That was the last stop before the first successful load.

## Not done yet

- The app still drives `WebView` directly; switching it to `UIWebView` is the
  point of all this and has not been done.
- The duplicate compat stub classes should live in one framework.
- Only tested from a command-line binary, not yet from a SpringBoard launch.
