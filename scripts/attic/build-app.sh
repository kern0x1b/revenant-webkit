#!/usr/bin/env bash
# Package the browser: the app binary plus the three frameworks and the C++
# runtime, all loaded from inside the bundle by @executable_path.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
# build-254 is the JIT-enabled engine and is what ships. build-cocoa is the older
# CLoop build, kept for comparison; ask for it by name when you want it.
# Defaulting to it silently packaged the wrong engine three times in one night.
B=${WEBKIT_BUILD_DIR:-$P/build-254}   # WEBKIT_BUILD_DIR=$P/build-cocoa for the older CLoop engine
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
TC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain

# WEBAPP_MANIFEST=platform/apps/threads.json packages that site as its own
# app (Threads.app, its own bundle id/scheme/icon) instead of the plain
# browser. Same binary, same engine - only the bundle identity and the
# WebApp.plist WebAppManifest.m reads at runtime differ.
if [ -n "${WEBAPP_MANIFEST:-}" ]; then
    APP_NAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$WEBAPP_MANIFEST")
    APP=$P/dist/$APP_NAME.app
else
    APP_NAME=LegacyBrowser
    APP=$P/dist/LegacyBrowser.app
fi

rm -rf "$APP" && mkdir -p "$APP/Frameworks"

"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -fno-objc-arc -O2 -flto -include "$P/compat/stubs/ios6_class_prefix.h" \
    -I"$B/WebKitLegacy/Headers" \
    -F"$B" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework MobileCoreServices \
    -framework WebKitLegacy \
    -Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip \
    "$P/app/main.m" "$P/app/ModernTLSURLProtocol.m" \
    "$P/platform/runtime/WebAppManifest.m" "$P/platform/runtime/WebAppCookieJar.m" \
    "$P/platform/runtime/WebAppBridge.m" "$P/platform/runtime/WebAppContentBlocker.m" \
    "$P/platform/runtime/WebAppBytecodeCache.m" \
    "$P/app/WebKitUIKitDelegate.m" \
    -I"$P/third_party/openssl-armv7/include" \
    "$P/third_party/openssl-armv7/lib/libssl.a" "$P/third_party/openssl-armv7/lib/libcrypto.a" -lz \
    -o "$APP/LegacyBrowser"

# A second entry point that drives WebKit without UIApplicationMain, for
# measurements over ssh where SpringBoard is not involved.
"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -fno-objc-arc -O2 -flto -include "$P/compat/stubs/ios6_class_prefix.h" \
    -I"$B/WebKitLegacy/Headers" -F"$B" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework MobileCoreServices \
    -framework WebKitLegacy \
    -Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip \
    "$P/app/headless.m" "$P/app/ModernTLSURLProtocol.m" \
    "$P/platform/runtime/WebAppManifest.m" "$P/platform/runtime/WebAppBridge.m" \
    "$P/platform/runtime/WebAppContentBlocker.m" \
    "$P/platform/runtime/WebAppBytecodeCache.m" \
    -I"$P/third_party/openssl-armv7/include" \
    "$P/third_party/openssl-armv7/lib/libssl.a" "$P/third_party/openssl-armv7/lib/libcrypto.a" -lz \
    -o "$APP/headless"

for fw in JavaScriptCore WebCore WebKitLegacy; do
    cp -R "$B/$fw.framework" "$APP/Frameworks/"
done
for lib in libc++.1.0.dylib libc++abi.1.0.dylib; do
    base=$(echo "$lib" | sed "s/\.1\.0\./.1./")
    cp "$P/third_party/libcxx-armv7/lib/$lib" "$APP/Frameworks/$base"
done

# The frameworks carry Apple's system install names, so every reference — the
# app's, and the ones between frameworks — is rewritten to load from the bundle.
SYS_JSC=/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
SYS_WC=/System/Library/PrivateFrameworks/WebCore.framework/WebCore
SYS_WKL=/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy
for fw in JavaScriptCore WebCore WebKitLegacy; do
    bin="$APP/Frameworks/$fw.framework/$fw"
    install_name_tool -id "@executable_path/Frameworks/$fw.framework/$fw" "$bin"
    install_name_tool -change "$SYS_JSC" "@executable_path/Frameworks/JavaScriptCore.framework/JavaScriptCore" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WC"  "@executable_path/Frameworks/WebCore.framework/WebCore" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WKL" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$bin" 2>/dev/null || true
    # Some references are recorded through @rpath rather than an absolute path.
    for dep in JavaScriptCore WebCore WebKitLegacy; do
        install_name_tool -change "@rpath/$dep.framework/$dep" \
            "@executable_path/Frameworks/$dep.framework/$dep" "$bin" 2>/dev/null || true
    done
done
# dyld compares declared versions, and CMake leaves them at 0.0.0.
for fw in JavaScriptCore WebCore WebKitLegacy; do
    python3 "$P/tools/set-dylib-version.py" "$APP/Frameworks/$fw.framework/$fw" 1.0.0
done

for binary in LegacyBrowser headless; do
    install_name_tool -change "$SYS_WKL" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$APP/$binary" 2>/dev/null || true
    install_name_tool -change "@rpath/WebKitLegacy.framework/WebKitLegacy" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$APP/$binary" 2>/dev/null || true
done
install_name_tool -change "$SYS_WC"  "@executable_path/Frameworks/WebCore.framework/WebCore" "$APP/LegacyBrowser" 2>/dev/null || true
install_name_tool -change "$SYS_JSC" "@executable_path/Frameworks/JavaScriptCore.framework/JavaScriptCore" "$APP/LegacyBrowser" 2>/dev/null || true

cp "$P/app/cacert.pem" "$APP/cacert.pem"
cp "$P/app/blockrules.json" "$APP/blockrules.json"

if [ -n "${WEBAPP_MANIFEST:-}" ]; then
    python3 "$P/tools/write-info-plist.py" "$APP/Info.plist" "$WEBAPP_MANIFEST"
    python3 "$P/tools/generate-webapp-plist.py" "$WEBAPP_MANIFEST" "$APP/WebApp.plist"
    # inject_css/inject_js are paths relative to platform/apps/; WebAppManifest.m
    # looks them up by basename in the bundle's own Resources, so that is the
    # only thing that has to match between the manifest and what is copied here.
    for key in inject_css inject_js; do
        rel=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$WEBAPP_MANIFEST" "$key")
        [ -n "$rel" ] || continue
        src=$(cd "$(dirname "$WEBAPP_MANIFEST")" && cd "$(dirname "$rel")" && pwd)/$(basename "$rel")
        cp "$src" "$APP/$(basename "$rel")"
    done
else
    python3 "$P/tools/write-info-plist.py" "$APP/Info.plist"
fi


# CMake leaves the local symbol table in the frameworks: WebCore ships 314,000
# symbols and 45 MB of __LINKEDIT, more than its 39 MB of code. dyld reads that
# at load and the pages stay resident, on a device with 512 MB of RAM. -x drops
# local symbols and keeps the exports the bundle links against.
for binary in \
    "$APP/Frameworks/JavaScriptCore.framework/JavaScriptCore" \
    "$APP/Frameworks/WebCore.framework/WebCore" \
    "$APP/Frameworks/WebKitLegacy.framework/WebKitLegacy" \
    "$APP/LegacyBrowser" "$APP/headless"; do
    [ -f "$binary" ] || continue
    before=$(stat -f%z "$binary")
    strip -x "$binary" 2>/dev/null || true
    after=$(stat -f%z "$binary")
    printf "stripped %-14s %.1f -> %.1f MB\n" "$(basename "$binary")" \
        "$(echo "$before" | awk '{print $1/1048576}')" \
        "$(echo "$after" | awk '{print $1/1048576}')"
done

find "$APP" -type f \( -name "*.dylib" -o -perm +111 \) -exec ldid -S {} \; 2>/dev/null
# The application binary carries entitlements the frameworks do not need.
ldid -S"$P/app/entitlements.xml" "$APP/LegacyBrowser" 2>/dev/null
ldid -S"$P/app/entitlements.xml" "$APP/headless" 2>/dev/null
echo "built: $APP"
du -sh "$APP" | cut -f1
