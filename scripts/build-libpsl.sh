#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
OUT=$P/third_party/libpsl-armv7
SRC=$P/third_party/src/libpsl
VERSION=0.23.3

if [ ! -d "$SRC" ]; then
    mkdir -p $P/third_party/src
    curl -sfL -o /tmp/libpsl.tar.gz https://github.com/rockdaboot/libpsl/releases/download/$VERSION/libpsl-$VERSION.tar.gz
    mkdir -p $SRC && tar xzf /tmp/libpsl.tar.gz -C $SRC --strip-components=1
fi

cd $SRC
[ -f Makefile ] && make distclean > /dev/null 2>&1 || true

export CC="$TC/usr/bin/clang"
export CFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK -O2"
export LDFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK"

./configure \
    --host=arm-apple-darwin --build=$(build-aux/config.guess) \
    --prefix=$OUT \
    --disable-shared --enable-static \
    --disable-runtime --disable-nls \
    > /tmp/libpsl-configure.log 2>&1

make -j$(sysctl -n hw.ncpu) > /tmp/libpsl-build.log 2>&1

mkdir -p $OUT/lib $OUT/include
cp src/.libs/libpsl.a $OUT/lib/
cp include/libpsl.h $OUT/include/

echo "libpsl.a $(ls -l $OUT/lib/libpsl.a | awk '{print $5}') bytes"
lipo -info $OUT/lib/libpsl.a 2>/dev/null | tail -1
file $OUT/lib/libpsl.a
nm $OUT/lib/libpsl.a | grep -q 'T _psl_is_public_suffix' \
    && echo "psl_is_public_suffix: present" \
    || { echo "ERROR: psl_is_public_suffix missing from libpsl.a"; exit 1; }
