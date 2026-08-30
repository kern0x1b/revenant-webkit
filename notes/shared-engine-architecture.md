# Shared engine architecture

Status: design, not built. Written 2026-08-26 so the shape is not lost.

## The name

Proposed: **Basalt** — the engine framework is `Basalt.framework`, the app-facing
facade is `BasaltKit.framework`. Dense volcanic rock: the thing you build on,
and it survives heat. Short, no toy connotation, and it reads well in a path
(`/Library/Frameworks/Basalt.framework`).

Alternatives considered, kept here so the decision can be revisited: *Lodestone*
(what navigators used before instruments — thematically apt for a browser, but
long), *Meridian* (elegant, less concrete), *Anvil* (solid, already common in
tooling names).

Nothing below depends on the name; substitute freely.

## Why

Today every web app bundle carries its own copy of the engine:

    dist/Threads.app/Frameworks/
        JavaScriptCore.framework   58 MB
        WebCore.framework         101 MB
        WebKitLegacy.framework    3.8 MB
        libc++.1.dylib            1.0 MB
        libc++abi.1.dylib         280 KB
                                 ~164 MB per app

Three apps is roughly half a gigabyte of identical bytes on a device that has
14 GB total and 512 MB of RAM. Worse, an engine improvement means rebuilding and
reinstalling every app, and each install is a multi-minute tar over USB.

The binaries are also linked `@executable_path/Frameworks/...` with an
`LC_RPATH` of `@executable_path/Frameworks`, so they are structurally bound to
living inside the app.

## Target shape

Three layers, each with a job:

1. **`Basalt.framework`** — the engine. WebKitLegacy, WebCore, JavaScriptCore
   and the C++ runtime, installed once at a fixed absolute path. Private: apps
   never link it directly.
2. **`BasaltKit.framework`** — a thin Objective-C facade with a deliberately
   small, versioned surface. This is the only thing apps link. It owns the
   `WebView` setup, the manifest reading, the network protocol, the injection
   points and the debug affordances that currently live in `app/main.m`.
3. **The web apps** — a bundle with an `Info.plist`, an icon, a manifest, and
   optional injected CSS/JS. Ideally no unique executable at all.

### Install location

`/Library/Frameworks/Basalt.framework` and `/Library/Frameworks/BasaltKit.framework`.

Not `/System/Library` — that is inside the dyld shared cache and on the root
partition; keeping out of it means no cache surgery, no signature problems, and
a clean uninstall.

Use the versioned-bundle layout so a bad update is one symlink swap away:

    Basalt.framework/
        Versions/
            A/Basalt
            B/Basalt
            Current -> A
        Basalt -> Versions/Current/Basalt

### Linking

Apps and `BasaltKit` link `Basalt` by absolute install name
(`/Library/Frameworks/Basalt.framework/Versions/Current/Basalt`), not
`@executable_path`. `build-app.sh` currently rewrites install names with
`install_name_tool`; that step becomes "point at the shared path" instead of
"copy into the bundle".

### The ABI problem, which is the whole problem

Dropping in a new engine without reinstalling apps only works if what the apps
bind to does not move. Today apps bind directly to WebKitLegacy's Objective-C
SPI and, transitively, to C++ symbols — an unstable surface that changes
whenever the engine is touched.

So the facade is not decoration, it is the mechanism:

- `BasaltKit` exports only Objective-C, only classes and methods we define.
- Its `compatibility_version` is bumped only on a real break; `current_version`
  tracks builds.
- `Basalt` is re-exported by nobody. Apps have no `LC_LOAD_DYLIB` on it.
- Everything C++ stays behind the facade.

Then an engine update is: build `Basalt`, replace it, apps keep running. An
update that changes the facade's ABI requires rebuilding apps — and the version
bump makes that loud rather than silent.

The existing ObjC class-prefix machinery (`compat/stubs/ios6_class_prefix.h`,
see `notes/class-collisions.md`) becomes more important, not less: one shared
copy of the engine means one registration of each class, which also removes the
double-registration the current per-app copies cause.

## Web app packaging

The manifest already exists and is the right idea — `platform/apps/*.json`,
read at runtime by `platform/runtime/WebAppManifest.m`. Today it carries name,
bundle id, scheme, start URL, internal hosts, shell hosts, precache list, user
agent, orientation, status bar style, colours, injected CSS/JS, and external
link policy.

The goal is that adding a web app, or adding a capability to one, never means
editing the engine. Extensions worth having:

- `hide_selectors` — CSS selectors removed at document start. This is the
  "hide the Get app button" case; doing it declaratively beats another hand
  written snippet per site.
- `inject_css` / `inject_js` gain a timing field (`document-start` vs
  `document-end`). Document-start needs a real user-script mechanism rather
  than a post-load `stringByEvaluatingJavaScriptFromString:`.
- `block_rules` — per-app ContentExtensions JSON, compiled through WebCore's
  own compiler. The plumbing landed 2026-08-26; today the list is global
  (`app/blockrules.json`), and it should be per-app.
- `preferences` — a whitelisted map of `WebPreferences` overrides, so a site
  that needs (say) media playback enabled does not force a code change.
- `jsc_options` — same idea for JSC options; a per-app version of the
  `/tmp/jsc-env` override file that exists today for A/B testing.

### Promoting page chrome to system controls

Raised 2026-08-26. A site's own bottom bar is a `position: fixed` element: it
lives in a composited layer that the tile path has to carry through every
scroll, and it is exactly the thing observed drifting and snapping back when the
web thread falls behind. Rendering it as a real `UITabBar` instead removes it
from that path altogether rather than making the path faster.

Shape, all of it manifest-driven so no site knowledge lands in the engine:

    "native_chrome": {
        "bottom_bar": {
            "selector": "nav[role=navigation]",
            "items": "a",
            "label_from": "aria-label",
            "icon_from": "svg"
        }
    }

A document-end user script reads the matched elements, extracts label, icon and
target for each item, and hands the list to the native side through
`WebAppBridge`. The native side builds the control; `hide_selectors` removes the
original. A tap dispatches a synthetic click on the element the item came from,
so the site's own routing still does the navigation and nothing has to know how
that site works.

Worth having beyond the drift: the bar stops being repainted with the document,
it gets real system hit-testing and animation, and it looks native because it is.

The risk is the obvious one - the mapping is markup-dependent and breaks when
the site restyles. That argues for keeping it declarative and per-app, which is
what the manifest is for, and for falling back to the page's own bar when the
selector matches nothing.

### One host binary

If the app binary is `BasaltKit`'s host and reads everything from the manifest,
then every app's executable is byte-identical. Ship it once and hard-link or
copy it into each bundle. `tools/generate-webapp-plist.py` already generates the
`Info.plist`; the same generator can lay down the whole bundle.

At that point installing a new web app is: write a JSON file, run the generator,
copy a few kilobytes to the device.

## Replacing the system WebKit

The final stage, and the only genuinely risky one. The aim is that Safari, Mail
and anything else using UIWebView run on our engine, so the whole device
benefits and there is only ever one engine on disk.

Mechanism would be dylib substitution over
`/System/Library/PrivateFrameworks/WebCore.framework` and friends. Constraints:

- Must be reversible from a shell without a restore. Keep the originals and a
  one-command revert.
- The system's callers use far more of the old ABI than our apps do, and iOS 6's
  WebKit is not our 2.54 fork's ABI. This is not a drop-in; it needs a real
  compatibility shim, and it may turn out not to be worth it.
- Do it only after the shared framework has been running our own apps for a
  while.

Honest assessment: stages 1-3 are engineering. This stage is research, and it
may end in "not worth the risk". It should not block the rest.

## Order of work

1. Define the `BasaltKit` surface. Move everything in `app/main.m` that is not
   process bootstrap behind it. This is the real work and it is independent of
   where the frameworks live.
2. Install the engine to `/Library/Frameworks`, point one app at it, keep the
   other two as they are. Verify launch, and verify that replacing the engine
   without touching the app works.
3. Convert the remaining apps. Delete the per-bundle framework copies.
4. Collapse to a single host binary and a bundle generator.
5. Manifest schema extensions, one at a time, each replacing a hard-coded case.
6. Only then look at the system WebKit.

## Open questions

- Code signing and entitlements for a framework outside an app bundle on a
  jailbroken iOS 6. `ldid`/`jtool` signing works for the binaries we ship today;
  a shared framework in `/Library` should be the same, but it is unverified.
- Whether `Basalt` should be one merged dylib rather than three. Fewer images
  means less rebase/bind work for iOS 6's dyld and better locality; against
  that, the three-way split is what the build system produces naturally.
- Storage isolation. Each app has its own WebKit storage path today
  (`/var/mobile/Library/WebKitStorage/<bundle-id>`); a shared engine must keep
  that per-app, not per-engine.
- Update atomicity: replacing a framework while an app is running. The versioned
  layout plus a symlink swap handles it for new launches; running processes keep
  the old image mapped, which is correct.
