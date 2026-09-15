#!/usr/bin/env bash
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
B=${ENGINE_BUILD:-$P/build-254-trunk}
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
CACHE="$B/CMakeCache.txt"
[ -f "$CACHE" ] || { echo "no CMakeCache.txt under $B" >&2; exit 1; }
CXXDIR=$(sed -n 's/^WEBKIT_IOS6_LIBCXX_DIR[^=]*=//p' "$CACHE")
[ -n "$CXXDIR" ] && [ -d "$CXXDIR/lib" ] || { echo "WEBKIT_IOS6_LIBCXX_DIR unusable: ${CXXDIR:-unset}" >&2; exit 1; }
cp "$CXXDIR/lib/libc++.1.0.dylib" "$OUT/libc++.1.dylib"
cp "$CXXDIR/lib/libc++abi.1.0.dylib" "$OUT/libc++abi.1.dylib"

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

for entry in "$B/WebCore.framework"/*; do
    name=$(basename "$entry")
    case "$name" in
        WebCore|Headers|PrivateHeaders|Modules|_CodeSignature|Info.plist|en.lproj|modern-media-controls) continue ;;
    esac
    cp -R "$entry" "$OUT/WebCore.framework/$name" 2>/dev/null || true
done

LIBDIR=${LIBCXX_DEVICE_DIR:-/usr/lib}
REVCXX="$LIBDIR/librev-c++.1.dylib"
REVCXXABI="$LIBDIR/librev-c++abi.1.dylib"
mv "$OUT/libc++.1.dylib" "$OUT/librev-c++.1.dylib"
mv "$OUT/libc++abi.1.dylib" "$OUT/librev-c++abi.1.dylib"

install_name_tool -id "$SYS_WK" "$OUT/WebKit.framework/WebKit"
install_name_tool -id "$SYS_WC" "$OUT/WebCore.framework/WebCore"
install_name_tool -id "$SYS_JSC" "$OUT/JavaScriptCore.framework/JavaScriptCore"
install_name_tool -id "$REVCXX" "$OUT/librev-c++.1.dylib"
install_name_tool -id "$REVCXXABI" "$OUT/librev-c++abi.1.dylib"

retarget() {
    binary=$1
    otool -L "$binary" | sed -n 's/^\t\(.*\) (compatibility version.*/\1/p' | tail -n +2 | while read -r ref; do
        case "$ref" in
            */WebCore.framework/WebCore) target=$SYS_WC ;;
            */JavaScriptCore.framework/JavaScriptCore) target=$SYS_JSC ;;
            */libc++.1.dylib) target=$REVCXX ;;
            */libc++abi.1.dylib) target=$REVCXXABI ;;
            *) continue ;;
        esac
        [ "$ref" = "$target" ] && continue
        install_name_tool -change "$ref" "$target" "$binary"
    done
}

for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore" "$OUT/JavaScriptCore.framework/JavaScriptCore" "$OUT/librev-c++.1.dylib" "$OUT/librev-c++abi.1.dylib"; do
    retarget "$binary"
done

for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore" "$OUT/JavaScriptCore.framework/JavaScriptCore" "$OUT/librev-c++.1.dylib" "$OUT/librev-c++abi.1.dylib"; do
    if otool -L "$binary" | grep -q "@rpath/"; then
        echo "unresolved @rpath dependency remains in $binary" >&2
        otool -L "$binary" | grep "@rpath/" >&2
        exit 1
    fi
done

for binary in "$OUT/WebKit.framework/WebKit" "$OUT/WebCore.framework/WebCore" "$OUT/JavaScriptCore.framework/JavaScriptCore"; do
    python3 "$P/tools/set-dylib-version.py" "$binary" 1.0.0
    strip -S -x "$binary" 2>/dev/null || true
    ldid -S "$binary" 2>/dev/null || true
done
ldid -S "$OUT/librev-c++.1.dylib" 2>/dev/null || true
ldid -S "$OUT/librev-c++abi.1.dylib" 2>/dev/null || true

echo "laid out: $OUT"
du -sh "$OUT" | cut -f1
