#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-${THEOS:-$HOME/theos}/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
SRC=$P/third_party/src
OUT=$P/third_party/woff2-armv7
BROTLI_VERSION=1.1.0
WOFF2_VERSION=1.0.2

if [ ! -d "$SRC/brotli" ]; then
    mkdir -p "$SRC"
    curl -sfL -o /tmp/brotli.tar.gz \
        https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz
    mkdir -p "$SRC/brotli" && tar xzf /tmp/brotli.tar.gz -C "$SRC/brotli" --strip-components=1
fi
if [ ! -d "$SRC/woff2" ]; then
    curl -sfL -o /tmp/woff2.tar.gz \
        https://github.com/google/woff2/archive/refs/tags/v$WOFF2_VERSION.tar.gz
    mkdir -p "$SRC/woff2" && tar xzf /tmp/woff2.tar.gz -C "$SRC/woff2" --strip-components=1
fi

CC="$TC/usr/bin/clang"
CXX="$TC/usr/bin/clang++"
ARCH="-target armv7-apple-ios6.0 -isysroot $SDK -mcpu=cortex-a9 -mfpu=neon -Os -fvisibility=hidden"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/obj"
cd "$OUT/obj"

for f in "$SRC"/brotli/c/common/*.c "$SRC"/brotli/c/dec/*.c; do
    $CC $ARCH -I"$SRC/brotli/c/include" -c "$f" -o "$(basename "$f" .c).o"
done
ar rcs "$OUT/lib/libbrotlidec.a" ./*.o
mkdir -p "$OUT/obj/brotli" && mv ./*.o "$OUT/obj/brotli/"

woff2_compile() {
    $CXX $ARCH -std=c++11 -nostdinc++ \
        -isystem "$P/third_party/libcxx-armv7/include/c++/v1" \
        -D_LIBCPP_DISABLE_AVAILABILITY \
        -I"$SRC/woff2/include" -I"$SRC/woff2/src" -I"$SRC/brotli/c/include" \
        -c "$SRC/woff2/src/$1.cc" -o "$1.o"
}

for f in woff2_common table_tags variable_length; do woff2_compile $f; done
ar rcs "$OUT/lib/libwoff2common.a" ./*.o
mkdir -p "$OUT/obj/common" && mv ./*.o "$OUT/obj/common/"

for f in woff2_dec woff2_out; do woff2_compile $f; done
ar rcs "$OUT/lib/libwoff2dec.a" ./*.o "$OUT/obj/common"/*.o "$OUT/obj/brotli"/*.o

cp -R "$SRC/woff2/include/woff2" "$OUT/include/"
cp -R "$SRC/brotli/c/include/brotli" "$OUT/include/"
rm -rf "$OUT/obj"

echo "built $OUT/lib/libwoff2dec.a and libbrotlidec.a"
ls -l "$OUT/lib"
