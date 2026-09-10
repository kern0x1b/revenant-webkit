#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
OUT=$P/third_party/openssl-armv7

cd $P/third_party/src/openssl
make clean > /dev/null 2>&1 || true

export CC="$TC/usr/bin/clang"
export CFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK -O2 -DBROKEN_CLANG_ATOMICS"
export LDFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK"

./Configure ios-cross \
    --prefix=$OUT \
    no-shared no-tests no-ui-console no-engine no-async \
    > /tmp/openssl-configure.log 2>&1

make -j$(sysctl -n hw.ncpu) build_libs > /tmp/openssl-build.log 2>&1
mkdir -p $OUT/lib $OUT/include
cp libssl.a libcrypto.a $OUT/lib/
cp -R include/openssl $OUT/include/
echo "libssl.a $(ls -l $OUT/lib/libssl.a | awk '{print $5}') bytes"
lipo -info $OUT/lib/libssl.a 2>/dev/null | tail -1
