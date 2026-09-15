#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
. "$P/scripts/deps.sh"
L=$IOS6_HOST_LIBCXX; PSL=$IOS6_HOST_LIBPSL
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
[ -x "$TC/usr/bin/clang" ] || TC=$(xcode-select -p)

COMMON="-target armv7-apple-ios6.0 -isysroot $SDK -isystem $P/compat/stubs -O2 -fno-objc-arc -Wno-builtin-requires-header -Wno-protocol -Wno-objc-designated-initializers"
STUBS="-include $P/compat/stubs/ios6_dispatch_compat.h"
CXX_ONLY="-nostdinc++ -isystem $L/include/c++/v1 -D_LIBCPP_DISABLE_AVAILABILITY -std=c++2b"

cd $P/compat

"$TC/usr/bin/clang" $COMMON -I $PSL/include \
    -c ios6_compat.c -o ios6_compat.o

for f in ios6_missing.c ios6_missing_constants.c ios6_coretext.c ios6_coregraphics.c; do
    "$TC/usr/bin/clang" $COMMON -c "$f" -o "${f%.c}.o"
done
for f in ios6_missing_classes.m ios6_uttype.m ios6_palswift.m ios6_uicolor.m ios6_avaudio.m; do
    "$TC/usr/bin/clang" $COMMON $STUBS -DWEBKIT_IOS6_OBJC_EXTRAS -c "$f" -o "${f%.m}.o"
done
for f in ios6_media_stubs.cpp; do
    "$TC/usr/bin/clang++" $COMMON $STUBS $CXX_ONLY -c "$f" -o "${f%.cpp}.o"
done

OBJECTS="ios6_compat.o ios6_missing.o ios6_missing_constants.o ios6_coretext.o ios6_coregraphics.o \
         ios6_missing_classes.o ios6_uttype.o ios6_palswift.o ios6_uicolor.o ios6_avaudio.o \
         ios6_media_stubs.o"

rm -f libios6compat.a
ar rcs libios6compat.a $OBJECTS

echo "libios6compat.a: $(nm libios6compat.a | awk '$2 ~ /^[TDBSC]$/' | wc -l | tr -d ' ') symbols"

if [ "$1" = "audit" ]; then
    nm libios6compat.a | awk '$2 ~ /^[TDBSC]$/ {print $3}' | sort -u > /tmp/compat_def.txt
    { find ${ENGINE_BUILD:-$P/build-254-lto} -name '*.o' -not -path '*compat*' | xargs nm 2>/dev/null
      nm $IOS6_HOST_ICU/lib/*.a 2>/dev/null; } \
        | awk '$2 ~ /^[TDBSC]$/ {print $3}' | sort -u > /tmp/wk_def.txt
    clash=$(comm -12 /tmp/compat_def.txt /tmp/wk_def.txt | grep -v '^__OBJC_' || true)
    if [ -n "$clash" ]; then
        echo "ERROR: these stubs shadow WebKit's own definitions:"
        echo "$clash"
        exit 1
    fi
    echo "audit: no stub shadows a WebKit definition"
fi
