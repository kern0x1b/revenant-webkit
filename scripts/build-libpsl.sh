#!/usr/bin/env bash
# Build libpsl for armv7 with a 6.0 deployment target.
#
# _CFHostIsDomainTopLevel (compat/ios6_compat.c) is PublicSuffixStoreCocoa.mm's
# only source of public-suffix data on this port. It used to be a hand-curated
# table of ~90 common suffixes - honest about being a heuristic, but a real,
# bounded gap against the actual Mozilla Public Suffix List. libpsl is the
# small C library purpose-built to answer that question from the real list
# (publicsuffix.org), and it can compile the list straight into the binary
# (--enable-builtin, the default) so nothing has to ship or update alongside
# the app.
#
# Built with --disable-runtime: full IDNA/punycode normalization needs
# libidn2 (which itself needs libunistring) cross-compiled for armv7 too.
# The public suffix data itself does not need it - --disable-runtime only
# drops psl_str_to_utf8lower()'s ability to normalize non-ASCII input before
# lookup, which _CFHostIsDomainTopLevel never calls (WebKit's CFNetworkSPI
# caller already hands it ASCII labels). psl_is_public_suffix() itself is
# unaffected either way.
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-/Users/alexanderhavrysh/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
OUT=$P/third_party/libpsl-armv7
SRC=$P/third_party/src/libpsl
VERSION=0.23.3

if [ ! -d "$SRC" ]; then
    mkdir -p $P/third_party/src
    # Release tarball, not a git clone: it ships configure (pre-run autoconf)
    # and src/suffixes_dafsa.h (pre-run psl-make-dafsa over list/public_suffix_list.dat,
    # which the tarball also carries) already generated, so no python/gperf
    # step is needed to get the real PSL data built in.
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
