#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
L=$P/third_party/libcxx-armv7
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain

COMMON="-target armv7-apple-ios6.0 -isysroot $SDK -isystem $P/compat/stubs -O2 -fno-objc-arc -Wno-builtin-requires-header -Wno-protocol -Wno-objc-designated-initializers"
STUBS="-include $P/compat/stubs/ios6_dispatch_compat.h"
CXX_ONLY="-nostdinc++ -isystem $L/include/c++/v1 -D_LIBCPP_DISABLE_AVAILABILITY -std=c++2b"

cd $P/compat

"$TC/usr/bin/clang" $COMMON -I $P/third_party/libpsl-armv7/include \
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

mkdir -p /tmp/ios6-openssl-members
(cd /tmp/ios6-openssl-members && rm -f *.o && ar x $P/third_party/openssl-armv7/lib/libcrypto.a)
ar rs libios6compat.a /tmp/ios6-openssl-members/*.o > /dev/null 2>&1

mkdir -p /tmp/ios6-libpsl-members
(cd /tmp/ios6-libpsl-members && rm -f *.o && ar x $P/third_party/libpsl-armv7/lib/libpsl.a)
ar rs libios6compat.a /tmp/ios6-libpsl-members/*.o > /dev/null 2>&1
echo "libios6compat.a: $(nm libios6compat.a | awk '$2 ~ /^[TDBSC]$/' | wc -l | tr -d ' ') symbols"

if [ "$1" = "audit" ]; then
    nm libios6compat.a | awk '$2 ~ /^[TDBSC]$/ {print $3}' | sort -u > /tmp/compat_def.txt
    { find $P/build-cocoa -name '*.o' -not -path '*compat*' | xargs nm 2>/dev/null
      nm $P/third_party/icu-armv7/lib/*.a 2>/dev/null; } \
        | awk '$2 ~ /^[TDBSC]$/ {print $3}' | sort -u > /tmp/wk_def.txt
    clash=$(comm -12 /tmp/compat_def.txt /tmp/wk_def.txt | grep -v '^__OBJC_' || true)
    if [ -n "$clash" ]; then
        echo "ERROR: these stubs shadow WebKit's own definitions:"
        echo "$clash"
        exit 1
    fi
    echo "audit: no stub shadows a WebKit definition"
fi
