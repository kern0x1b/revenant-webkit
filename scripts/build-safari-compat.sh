#!/usr/bin/env bash
# Build the injected compatibility dylib for the Mobile Safari substitution:
# /usr/lib/rev-safari-compat.dylib. It carries the ~15 Foundation/WebKit ABI
# stubs iOS 6 predates, plus the two Substrate hooks (bookmarks start page on a
# blank tab, and blanking the address field for about:blank).
#
#   ./build-safari-compat.sh [source.mm] [out.dylib]
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-$P/platform/safari/safari-compat.mm}
OUT=${2:-$P/dist/rev-safari-compat.dylib}
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain

mkdir -p "$(dirname "$OUT")"

# window.WebAssembly for Safari comes from the wasm3 interpreter (JSC's WASM is
# 64-bit only): RevWasm.m is the bridge, installed at window-object-clear by the
# hook in safari-compat.mm; the wasm3 interpreter core is compiled in alongside.
W3="$P/third_party/wasm3/source"
WASM3_CORE="$W3/m3_bind.c $W3/m3_code.c $W3/m3_compile.c $W3/m3_core.c $W3/m3_env.c $W3/m3_exec.c $W3/m3_function.c $W3/m3_info.c $W3/m3_module.c $W3/m3_parse.c $W3/m3_validate.c"

"$TC/usr/bin/clang" \
    -target armv7-apple-ios6.0 -isysroot "$SDK" -O2 -fno-objc-arc \
    -Wno-deprecated-declarations -Wno-unused \
    -I "$W3" -I "$P/app" \
    -dynamiclib -install_name /usr/lib/rev-safari-compat.dylib \
    -framework Foundation -framework CoreFoundation -lobjc -lsqlite3 \
    "$SRC" "$P/app/RevWasm.m" $WASM3_CORE -o "$OUT"
ldid -S "$OUT" 2>/dev/null || true
echo "built $OUT"
