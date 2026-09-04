#!/usr/bin/env bash
# Build libxslt for armv7 with a 6.0 deployment target.
#
# ENABLE_XSLT needs libxslt/transform.h and friends. The SDK carries only a
# linker stub for the system dylib (libxslt.tbd, matched at runtime against
# the real libxslt on the device) - no headers, and no static archive for
# this architecture. libxml2 is not vendored here: its headers already ship
# in the SDK and its own .tbd is used as-is, same as the WebKit CMake build
# already does for libxml2/sqlite3/zlib.
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-/Users/alexanderhavrysh/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
OUT=$P/third_party/libxslt-armv7
SRC=$P/third_party/src/libxslt

if [ ! -d "$SRC" ]; then
    mkdir -p $P/third_party/src
    # 1.1.43, not the newer 1.1.45: 1.1.45 raised LIBXML_REQUIRED_VERSION to
    # 2.15.1 and its hash-callback signatures (xmlHashDeallocator etc, now
    # const-qualified) no longer match the SDK's libxml2 2.9.4 headers - a
    # real -Wincompatible-function-pointer-types build failure, not a config
    # nag. 1.1.43 still targets the 2.6.27-era API and builds clean against it.
    curl -sfL -o /tmp/libxslt.tar.xz https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz
    mkdir -p $SRC && tar xJf /tmp/libxslt.tar.xz -C $SRC --strip-components=1
fi

cd $SRC
[ -f Makefile ] && make distclean > /dev/null 2>&1 || true

export CC="$TC/usr/bin/clang"
# The SDK's libxml2 is 2.9.4 (pre-const-correct xmlHashDeallocator/
# xmlHashScanner typedefs in hash.h); libxslt's own callbacks have used the
# const-qualified signature since long before that stopped mattering to any
# compiler. Recent clang promotes the mismatch from a warning to a hard
# error by default - harmless (same pointer width, read-only access either
# way), so it is downgraded back to a warning here rather than patched away.
export CFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK -O2 -Wno-incompatible-function-pointer-types"
export LDFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK"
# No xml2-config/pkg-config for this SDK; point straight at the headers and
# .tbd that already ship there, same as the CMake build does for WebCore.
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
