#!/usr/bin/env bash
# Build /usr/lib/rev-TLS.dylib, the TLS the substitution speaks.
#
# The loader inserts this into Mobile Safari alongside the engine, so it is what
# actually secures every https connection the browser makes. It was previously
# built by hand, which is why the repository had no recipe for it; see
# app/tls-openssl.c for why the system's TLS is not enough on this release.
#
#   ./build-safari-tls.sh [out.dylib]
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
SRC="$P/app/tls-openssl.c"
OUT=${1:-$P/dist/rev-TLS.dylib}
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain

mkdir -p "$(dirname "$OUT")"
"$TC/usr/bin/clang" \
    -target armv7-apple-ios6.0 -isysroot "$SDK" -O2 -dynamiclib \
    -install_name /usr/lib/rev-TLS.dylib \
    -I "$P/third_party/openssl-armv7/include" \
    -framework CoreFoundation -framework Security \
    "$SRC" \
    "$P/third_party/openssl-armv7/lib/libssl.a" \
    "$P/third_party/openssl-armv7/lib/libcrypto.a" \
    -o "$OUT"
ldid -S "$OUT" 2>/dev/null || true
echo "built $OUT"
