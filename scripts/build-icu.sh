#!/usr/bin/env bash
# Build ICU 74.2 twice: once for this Mac (ICU needs its own tools to generate
# data) and once for armv7/iOS 6, which is what WebKit links against.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
XC=/Applications/Xcode.app/Contents/Developer
CXX21=$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/usr/include/c++/v1
SRC=$ROOT/third_party/icu
mkdir -p $ROOT/third_party

if [ ! -d "$SRC" ]; then
    curl -sfL -o /tmp/icu.tgz https://github.com/unicode-org/icu/releases/download/release-74-2/icu4c-74_2-src.tgz
    mkdir -p $SRC && tar xzf /tmp/icu.tgz -C $SRC --strip-components=1
fi

rm -rf $ROOT/build-icu-armv7
mkdir -p $ROOT/build-icu-host $ROOT/build-icu-armv7

cd $ROOT/build-icu-host
[ -f Makefile ] || $SRC/source/configure --enable-static --disable-shared --disable-tests \
    --disable-samples --disable-extras > host-cfg.log 2>&1
make -j8 > host-build.log 2>&1

cd $ROOT/build-icu-armv7
export CC="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
export CXX="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
export CFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK -O2"
export CXXFLAGS="$CFLAGS -std=c++17 -nostdinc++ -isystem $CXX21 -D_LIBCPP_DISABLE_AVAILABILITY"
export LDFLAGS="-target armv7-apple-ios6.0 -isysroot $SDK"
$SRC/source/configure --host=arm-apple-darwin --with-cross-build=$ROOT/build-icu-host \
    --enable-static --disable-shared --disable-tests --disable-samples \
    --disable-extras --disable-tools --disable-renaming --prefix=$ROOT/third_party/icu-armv7 > cross-cfg.log 2>&1
make -j8 > cross-build.log 2>&1
make install > cross-install.log 2>&1
echo "ICU armv7 installed:"
ls $ROOT/third_party/icu-armv7/lib
