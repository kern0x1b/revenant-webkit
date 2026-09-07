#!/usr/bin/env bash
# Package the standalone RevWebView hosting test: app/rev-webview-host.m linked
# directly against build-254-rev's Rev-prefixed WebKitLegacy, the way
# scripts/attic/build-app.sh linked directly against the unprefixed engine -
# not the DYLD_FRAMEWORK_PATH substitution scripts/build-app-lto.sh uses. The
# frameworks keep their own real names (WebKitLegacy.framework etc, not
# WebKit.framework) and are not diverted to a system path: this app coexists
# with the system's own WebKit in one process rather than replacing it, so
# there is nothing here for the system engine to collide with by path or by
# class name.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
B=$P/build-254-rev
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
TC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain

APP_NAME=RevWebViewHost
APP=$P/dist/$APP_NAME.app

rm -rf "$APP" && mkdir -p "$APP/Frameworks"

"$TC/usr/bin/clang" -target armv7-apple-ios6.0 -isysroot "$SDK" -fno-objc-arc -O0 -g \
    -include "$P/compat/stubs/ios6_class_prefix.h" \
    -I"$B/WebKitLegacy/Headers" \
    -F"$B" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework MobileCoreServices \
    -framework WebKitLegacy \
    -Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip \
    "$P/app/rev-webview-host.m" "$P/app/ModernTLSURLProtocol.m" \
    "$P/app/WebKitUIKitDelegate.m" \
    -I"$P/third_party/openssl-armv7/include" \
    "$P/third_party/openssl-armv7/lib/libssl.a" "$P/third_party/openssl-armv7/lib/libcrypto.a" -lz \
    -o "$APP/$APP_NAME"

for fw in JavaScriptCore WebCore WebKitLegacy; do
    cp -R "$B/$fw.framework" "$APP/Frameworks/"
done
for lib in libc++.1.0.dylib libc++abi.1.0.dylib; do
    base=$(echo "$lib" | sed "s/\.1\.0\./.1./")
    cp "$P/third_party/libcxx-armv7/lib/$lib" "$APP/Frameworks/$base"
done

# The frameworks carry Apple's system install names; every reference is
# rewritten to load from inside the bundle instead, at a private path the
# system's own WebKit is never loaded from - this is what keeps the two
# engines from being "the same library" to dyld, on top of the Rev prefix
# keeping them from being "the same class" to the Objective-C runtime.
SYS_JSC=/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
SYS_WC=/System/Library/PrivateFrameworks/WebCore.framework/WebCore
SYS_WKL=/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy
for fw in JavaScriptCore WebCore WebKitLegacy; do
    bin="$APP/Frameworks/$fw.framework/$fw"
    install_name_tool -id "@executable_path/Frameworks/$fw.framework/$fw" "$bin"
    install_name_tool -change "$SYS_JSC" "@executable_path/Frameworks/JavaScriptCore.framework/JavaScriptCore" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WC"  "@executable_path/Frameworks/WebCore.framework/WebCore" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WKL" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$bin" 2>/dev/null || true
    for dep in JavaScriptCore WebCore WebKitLegacy; do
        install_name_tool -change "@rpath/$dep.framework/$dep" \
            "@executable_path/Frameworks/$dep.framework/$dep" "$bin" 2>/dev/null || true
    done
done
for fw in JavaScriptCore WebCore WebKitLegacy; do
    python3 "$P/tools/set-dylib-version.py" "$APP/Frameworks/$fw.framework/$fw" 1.0.0
done

install_name_tool -change "$SYS_WKL" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$APP/$APP_NAME" 2>/dev/null || true
install_name_tool -change "@rpath/WebKitLegacy.framework/WebKitLegacy" "@executable_path/Frameworks/WebKitLegacy.framework/WebKitLegacy" "$APP/$APP_NAME" 2>/dev/null || true
install_name_tool -change "$SYS_WC"  "@executable_path/Frameworks/WebCore.framework/WebCore" "$APP/$APP_NAME" 2>/dev/null || true
install_name_tool -change "$SYS_JSC" "@executable_path/Frameworks/JavaScriptCore.framework/JavaScriptCore" "$APP/$APP_NAME" 2>/dev/null || true

cp "$P/app/cacert.pem" "$APP/cacert.pem"

python3 - "$APP/Info.plist" "$APP_NAME" <<'PY'
import plistlib, sys
out, name = sys.argv[1], sys.argv[2]
plistlib.dump({
    "CFBundleName": name,
    "CFBundleDisplayName": name,
    "CFBundleIdentifier": "space.kern0x1b.revwebviewhost",
    "CFBundleExecutable": name,
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1.0",
    "CFBundleShortVersionString": "1.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "UIDeviceFamily": [1],
    "MinimumOSVersion": "6.0",
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "CFBundleURLTypes": [{
        "CFBundleURLName": "space.kern0x1b.revwebviewhost",
        "CFBundleURLSchemes": ["revwebviewhost"],
    }],
}, open(out, "wb"))
PY

find "$APP" -type f \( -name "*.dylib" -o -perm +111 \) -exec ldid -S {} \; 2>/dev/null
ldid -S"$P/app/entitlements.xml" "$APP/$APP_NAME" 2>/dev/null
echo "built: $APP"
du -sh "$APP" | cut -f1
