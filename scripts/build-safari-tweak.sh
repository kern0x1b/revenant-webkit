#!/usr/bin/env bash
# Build the MobileSubstrate loader tweak: /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib.
# When Mobile Safari launches this sets DYLD_FRAMEWORK_PATH / DYLD_INSERT_LIBRARIES to our engine
# (/usr/lib/rev-fw + rev-safari-compat.dylib + rev-TLS.dylib) and re-execs Safari, so the second
# launch loads our WebKit 2.54 underneath it. Plain C, links only libSystem.
#
#   ./build-safari-tweak.sh [out.dylib]
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
SRC="$P/platform/safari/rev-safari-tweak.c"
OUT=${1:-$P/dist/RevSafari.dylib}
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain

mkdir -p "$(dirname "$OUT")"
"$TC/usr/bin/clang" \
    -target armv7-apple-ios6.0 -isysroot "$SDK" -O2 \
    -dynamiclib -install_name /Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib \
    "$SRC" -o "$OUT"
ldid -S "$OUT" 2>/dev/null || true
echo "built $OUT"
