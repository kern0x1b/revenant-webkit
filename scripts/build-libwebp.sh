#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
SRC=$P/third_party/src/libwebp
OUT=$P/third_party/libwebp-armv7
VERSION=1.4.0

if [ ! -d "$SRC" ]; then
    mkdir -p "$P/third_party/src"
    curl -sfL -o /tmp/libwebp.tar.gz \
        https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$VERSION.tar.gz
    mkdir -p "$SRC" && tar xzf /tmp/libwebp.tar.gz -C "$SRC" --strip-components=1
fi

CC="$TC/usr/bin/clang"
ARCH="-target armv7-apple-ios6.0 -isysroot $SDK -mcpu=cortex-a9 -mfpu=neon -O2 -fvisibility=hidden"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/obj"
cd "$OUT/obj"

compile_group() {
    for f in "$@"; do
        case $(basename "$f") in
            *enc*) continue ;;   # encoder halves of the dsp and utils groups
        esac
        $CC $ARCH -I"$SRC" -I"$SRC/src" -c "$f" -o "$(basename "$f" .c).o"
    done
}

compile_group "$SRC"/src/dec/*.c "$SRC"/src/dsp/*.c "$SRC"/src/utils/*.c
ar rcs "$OUT/lib/libwebp.a" ./*.o
rm -f ./*.o

compile_group "$SRC"/src/demux/*.c
ar rcs "$OUT/lib/libwebpdemux.a" ./*.o

mkdir -p "$OUT/include/webp"
cp "$SRC"/src/webp/*.h "$OUT/include/webp/"
rm -rf "$OUT/obj"

echo "built $OUT/lib/libwebp.a and libwebpdemux.a"
ls -l "$OUT/lib"
