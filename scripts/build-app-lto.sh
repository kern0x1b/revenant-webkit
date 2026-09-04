#!/usr/bin/env bash
# Package the web app on the SYSTEM UIWebView, with our engine substituted for
# the system one.
#
# The app links nothing from WebKit itself: UIKit pulls the engine in, and
# DYLD_FRAMEWORK_PATH decides whose. So the frameworks are laid out under the
# names UIKit asks for - WebKitLegacy becomes WebKit.framework/WebKit - and
# carry the system install names, which is also how they refer to each other.
#
#   ./build-app-sys.sh platform/apps/threads.json
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
B=${ENGINE_BUILD:-$P/build-254-lto}
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
TC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain

MANIFEST=${1:-$P/platform/apps/threads.json}
NAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$MANIFEST")
APP=$P/dist/$NAME-Native.app

rm -rf "$APP" && mkdir -p "$APP/Frameworks"

# The launcher must not link UIKit: it has to get the engine into the process
# before UIKit arrives. The interface is a dylib loaded after that.
"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -fno-objc-arc -O2 \
    -framework Foundation \
    "$P/app/native-main.m" -o "$APP/$NAME-Native"

"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -fno-objc-arc -O2 -dynamiclib \
    -install_name "@executable_path/NativeUI.dylib" \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework ImageIO \
    "$P/app/native-ui.m" "$P/app/StaticAssetCache.m" -o "$APP/NativeUI.dylib"

# The TLS this port speaks, over OpenSSL built for armv7. Inserted at relaunch
# by native-main; see app/tls-openssl.c for why the system's is not enough.
"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -O2 -dynamiclib \
    -install_name "@executable_path/TLS.dylib" \
    -I "$P/third_party/openssl-armv7/include" \
    -framework CoreFoundation -framework Security \
    "$P/app/tls-openssl.c" \
    "$P/third_party/openssl-armv7/lib/libssl.a" \
    "$P/third_party/openssl-armv7/lib/libcrypto.a" -o "$APP/TLS.dylib"

# The memory probe, built beside the TLS library. It is inert unless
# /tmp/native-mem-probe exists, and native-main inserts it only then.
"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -O2 -fno-omit-frame-pointer -dynamiclib \
    -install_name "@executable_path/MemProbe.dylib" \
    "$P/app/mem-probe.c" -o "$APP/MemProbe.dylib"

SYS_WK=/System/Library/PrivateFrameworks/WebKit.framework/WebKit
SYS_WC=/System/Library/PrivateFrameworks/WebCore.framework/WebCore
# iOS 6 carries JavaScriptCore as a private framework; it only became public in iOS 7.
PUBLIC_JSC=/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
SYS_JSC=/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore

mkdir -p "$APP/Frameworks/WebKit.framework" "$APP/Frameworks/WebCore.framework" "$APP/Frameworks/JavaScriptCore.framework"
cp "$B/WebKitLegacy.framework/WebKitLegacy" "$APP/Frameworks/WebKit.framework/WebKit"
cp "$B/WebCore.framework/WebCore" "$APP/Frameworks/WebCore.framework/WebCore"
cp "$B/JavaScriptCore.framework/JavaScriptCore" "$APP/Frameworks/JavaScriptCore.framework/JavaScriptCore"
cp "$P/third_party/libcxx-armv7/lib/libc++.1.0.dylib" "$APP/Frameworks/libc++.1.dylib"
cp "$P/third_party/libcxx-armv7/lib/libc++abi.1.0.dylib" "$APP/Frameworks/libc++abi.1.dylib"

install_name_tool -id "$SYS_WK" "$APP/Frameworks/WebKit.framework/WebKit"
install_name_tool -id "$SYS_WC" "$APP/Frameworks/WebCore.framework/WebCore"
install_name_tool -id "$SYS_JSC" "$APP/Frameworks/JavaScriptCore.framework/JavaScriptCore"
for binary in "$APP/Frameworks/WebKit.framework/WebKit" "$APP/Frameworks/WebCore.framework/WebCore"; do
    install_name_tool -change "@rpath/WebCore.framework/WebCore" "$SYS_WC" "$binary" 2>/dev/null || true
    install_name_tool -change "@rpath/JavaScriptCore.framework/JavaScriptCore" "$SYS_JSC" "$binary" 2>/dev/null || true
    install_name_tool -change "$PUBLIC_JSC" "$SYS_JSC" "$binary" 2>/dev/null || true
done

# dyld compares declared versions, and CMake leaves them at 0.0.0.
for binary in "$APP/Frameworks/WebKit.framework/WebKit" "$APP/Frameworks/WebCore.framework/WebCore" "$APP/Frameworks/JavaScriptCore.framework/JavaScriptCore"; do
    python3 "$P/tools/set-dylib-version.py" "$binary" 1.0.0
done

python3 - "$MANIFEST" "$APP/Info.plist" "$NAME" <<'PY'
import json, plistlib, sys
manifest, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(manifest))
plistlib.dump({
    "CFBundleName": name + "-Native",
    "CFBundleDisplayName": name + " Native",
    "CFBundleIdentifier": m["bundle_id"] + ".native",
    "CFBundleExecutable": name + "-Native",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": m.get("version", "1.0"),
    "CFBundleShortVersionString": m.get("version", "1.0"),
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "UIDeviceFamily": [1],
    "MinimumOSVersion": "6.0",
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "WebAppStartURL": m["start_url"],
    "WebAppUserAgent": m.get("user_agent", {}).get("override") or (
        "Mozilla/5.0 (iPhone; CPU iPhone OS %s like Mac OS X) "
        "AppleWebKit/%s (KHTML, like Gecko) Version/%s Mobile/15E148 Safari/%s" % (
            m.get("user_agent", {}).get("product_version", "18.7").replace(".", "_"),
            m.get("user_agent", {}).get("build_version", "604.1"),
            m.get("user_agent", {}).get("product_version", "18.7"),
            m.get("user_agent", {}).get("build_version", "604.1"))),
    "CFBundleURLTypes": [{
        "CFBundleURLName": m["bundle_id"] + ".native",
        "CFBundleURLSchemes": [m["scheme"] + "native"],
    }],
}, open(out, "wb"))
PY

# The manifest's injected stylesheet and script, the same two the coexisting
# app uses. Without them Threads' install sheet stays up, and while it is up
# the document is one screen tall and the feed cannot be reached at all.
python3 "$P/tools/package-injection.py" "$MANIFEST" "$APP"

# Symbol tables are nineteen megabytes of WebCore alone and are never read at
# runtime; unstripped copies are kept for symbolising crash logs. Done here so it
# cannot be forgotten - a deploy that skipped it cost thirty three megabytes of a
# device that gets killed at a hundred and seventy.
mkdir -p "$P/dist/unstripped"
for _framework in "$APP/Frameworks/WebKit.framework/WebKit" \
                  "$APP/Frameworks/WebCore.framework/WebCore" \
                  "$APP/Frameworks/JavaScriptCore.framework/JavaScriptCore"; do
    cp "$_framework" "$P/dist/unstripped/$(basename "$_framework")"
    strip -S -x "$_framework" 2>/dev/null || true
done

find "$APP" -type f -perm +111 -exec ldid -S {} \; 2>/dev/null
ldid -S "$APP/$NAME-Native"
echo "built: $APP"
du -sh "$APP" | cut -f1
