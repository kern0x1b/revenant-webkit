#!/usr/bin/env bash
# Lay out the non-prefixed engine (build-254-lto) as the system frameworks a
# process expects, into a standalone directory that DYLD_FRAMEWORK_PATH can point
# at - so any process (Mobile Safari) loads our WebKit 2.54 instead of the shared
# cache's, and not tied to an app bundle.
#
#   ./layout-sys-frameworks.sh [out-dir]
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
B=${ENGINE_BUILD:-$P/build-254-lto}
OUT=${1:-$P/dist/rev-sys-fw}

SYS_WK=/System/Library/PrivateFrameworks/WebKit.framework/WebKit
SYS_WC=/System/Library/PrivateFrameworks/WebCore.framework/WebCore
SYS_JSC=/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore
PUBLIC_JSC=/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore

rm -rf "$OUT"
mkdir -p "$OUT/WebKit.framework" "$OUT/WebCore.framework" "$OUT/JavaScriptCore.framework"
cp "$B/WebKitLegacy.framework/WebKitLegacy" "$OUT/WebKit.framework/WebKit"
cp "$B/WebCore.framework/WebCore" "$OUT/WebCore.framework/WebCore"
cp "$B/JavaScriptCore.framework/JavaScriptCore" "$OUT/JavaScriptCore.framework/JavaScriptCore"
cp "$P/third_party/libcxx-armv7/lib/libc++.1.0.dylib" "$OUT/libc++.1.dylib"
cp "$P/third_party/libcxx-armv7/lib/libc++abi.1.0.dylib" "$OUT/libc++abi.1.dylib"

# WebCore resolves media-controls scripts, localized strings and button icons
# from the framework bundle ([NSBundle bundleForClass:] + pathForResource:), so
# the framework must carry those resources, not just the binary. Copy them, and
# flatten the iOS icon set up into modern-media-controls/images/ because the
# resource lookup does not include the per-platform subdirectory.
cp "$B/WebCore.framework/Info.plist" "$OUT/WebCore.framework/Info.plist" 2>/dev/null || true
if [ -d "$B/WebCore.framework/en.lproj" ]; then
    mkdir -p "$OUT/WebCore.framework/en.lproj"
    cp "$B/WebCore.framework/en.lproj/"*.js "$OUT/WebCore.framework/en.lproj/" 2>/dev/null || true
fi
if [ -d "$B/WebCore.framework/modern-media-controls" ]; then
    cp -R "$B/WebCore.framework/modern-media-controls" "$OUT/WebCore.framework/modern-media-controls"
    cp -f "$OUT/WebCore.framework/modern-media-controls/images/iOS/"*.svg \
          "$OUT/WebCore.framework/modern-media-controls/images/iOS/"*.png \
          "$OUT/WebCore.framework/modern-media-controls/images/" 2>/dev/null || true
fi

# Every other file the framework carries at its top level: the images the engine
# loads by name through ImageAdapter::loadPlatformResource, the colour profile,
# the blocked-page markup. Leaving them out is not cosmetic - a page with a
# broken image asks for missingImage@2x.png, the load fails, the engine falls
# back to an empty image, and drawing that took the browser down. Headers and
# the signature are build products and stay behind.
for entry in "$B/WebCore.framework"/*; do
    name=$(basename "$entry")
    case "$name" in
        WebCore|Headers|PrivateHeaders|Modules|_CodeSignature|Info.plist|en.lproj|modern-media-controls) continue ;;
    esac
    cp -R "$entry" "$OUT/WebCore.framework/$name" 2>/dev/null || true
done

install_name_tool -id "$SYS_WK" "$OUT/WebKit.framework/WebKit"
install_name_tool -id "$SYS_WC" "$OUT/WebCore.framework/WebCore"
install_name_tool -id "$SYS_JSC" "$OUT/JavaScriptCore.framework/JavaScriptCore"
for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore"; do
    install_name_tool -change "@rpath/WebCore.framework/WebCore" "$SYS_WC" "$binary" 2>/dev/null || true
    install_name_tool -change "@rpath/JavaScriptCore.framework/JavaScriptCore" "$SYS_JSC" "$binary" 2>/dev/null || true
    install_name_tool -change "$PUBLIC_JSC" "$SYS_JSC" "$binary" 2>/dev/null || true
done

# The engine references libc++ as @executable_path/Frameworks/... which is right
# for our own app bundle but wrong under an arbitrary host. Two constraints under
# Mobile Safari: (1) its sandbox denies loading dylibs from /var/mobile, so libc++
# must sit at a trusted system path - /usr/lib; (2) iOS 6 ships its own libc++ in
# the shared cache at /usr/lib/libc++.1.dylib, and dyld prefers the cache for any
# install name that matches it - which shadows our newer copy and its extra
# symbols. So our libraries take UNIQUE names the cache has nothing to match.
# (The frameworks load through DYLD_FRAMEWORK_PATH, which dyld treats specially,
# so they can stay in the deploy dir under their system names.)
LIBDIR=${LIBCXX_DEVICE_DIR:-/usr/lib}
REVCXX="$LIBDIR/librev-c++.1.dylib"
REVCXXABI="$LIBDIR/librev-c++abi.1.dylib"
mv "$OUT/libc++.1.dylib" "$OUT/librev-c++.1.dylib"
mv "$OUT/libc++abi.1.dylib" "$OUT/librev-c++abi.1.dylib"
for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore" "$OUT/JavaScriptCore.framework/JavaScriptCore"; do
    install_name_tool -change "@executable_path/Frameworks/libc++.1.dylib" "$REVCXX" "$binary" 2>/dev/null || true
    install_name_tool -change "@executable_path/Frameworks/libc++abi.1.dylib" "$REVCXXABI" "$binary" 2>/dev/null || true
done
install_name_tool -id "$REVCXX" "$OUT/librev-c++.1.dylib"
install_name_tool -id "$REVCXXABI" "$OUT/librev-c++abi.1.dylib"
install_name_tool -change "@executable_path/Frameworks/libc++abi.1.dylib" "$REVCXXABI" "$OUT/librev-c++.1.dylib" 2>/dev/null || true

for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore" "$OUT/JavaScriptCore.framework/JavaScriptCore"; do
    python3 "$P/tools/set-dylib-version.py" "$binary" 1.0.0
    strip -S -x "$binary" 2>/dev/null || true
    ldid -S "$binary" 2>/dev/null || true
done
# libc++ is NOT stripped: stripping is fine for symbols but we keep the pair
# whole here to avoid disturbing their export tries. Just sign.
ldid -S "$OUT/librev-c++.1.dylib" 2>/dev/null || true
ldid -S "$OUT/librev-c++abi.1.dylib" 2>/dev/null || true

echo "laid out: $OUT"
du -sh "$OUT" | cut -f1
