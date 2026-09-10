#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
OUT=$P/third_party/libxslt-armv7
SRC=$P/third_party/src/libxslt

if [ ! -d "$SRC" ]; then
    mkdir -p $P/third_party/src
    curl -sfL -o /tmp/libxslt.tar.xz https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz
    mkdir -p $SRC && tar xJf /tmp/libxslt.tar.xz -C $SRC --strip-components=1
fi

cd $SRC
[ -f Makefile ] && make distclean > /dev/null 2>&1 || true

export CC="$TC/usr/bin/clang"
export CFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK -O2 -Wno-incompatible-function-pointer-types"
export LDFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK"
export LIBXML_CFLAGS="-I$SDK/usr/include/libxml2"
export LIBXML_LIBS="-lxml2"

./configure \
    --host=arm-apple-darwin --build=$(./config.guess) \
    --prefix=$OUT \
    --disable-shared --enable-static \
    --without-python --without-crypto --without-plugins \
    --without-debugger --without-debug --without-profiler \
    > /tmp/libxslt-configure.log 2>&1

make -j$(sysctl -n hw.ncpu) > /tmp/libxslt-build.log 2>&1

mkdir -p $OUT/lib $OUT/include/libxslt $OUT/include/libexslt
cp libxslt/.libs/libxslt.a $OUT/lib/
cp libexslt/.libs/libexslt.a $OUT/lib/ 2>/dev/null || true
cp libxslt/*.h $OUT/include/libxslt/
cp libexslt/*.h $OUT/include/libexslt/ 2>/dev/null || true

echo "libxslt.a $(ls -l $OUT/lib/libxslt.a | awk '{print $5}') bytes"
lipo -info $OUT/lib/libxslt.a 2>/dev/null | tail -1
file $OUT/lib/libxslt.a
