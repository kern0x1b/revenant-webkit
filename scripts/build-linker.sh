#!/usr/bin/env bash
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
SRC=$P/third_party/src
OUT=$P/third_party/ld64-armv7
LLVM=${LLVM_PREFIX:-$(brew --prefix llvm)}

# Apple's linker from Xcode 27 cannot place the call stubs of a 25MB armv7
# dylib within reach of a Thumb branch, and refuses the link. ld64 inserts
# branch islands and completes it. Building it here also takes the whole
# toolchain off Xcode: clang comes from LLVM, the SDK from theos, and every
# binary utility from cctools.

mkdir -p "$SRC"

if [ ! -d "$SRC/apple-libtapi" ]; then
    git clone --depth 1 https://github.com/tpoechtrager/apple-libtapi.git "$SRC/apple-libtapi"
fi
if [ ! -d "$SRC/cctools-port" ]; then
    git clone --depth 1 https://github.com/tpoechtrager/cctools-port.git "$SRC/cctools-port"
fi

# Its vendored LLVM does not ship the CMake helper its clang asks for.
python3 - "$SRC/apple-libtapi/src/clang/CMakeLists.txt" <<'PATCH'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''if (APPLE AND NOT CMAKE_LINKER MATCHES ".*lld.*")
  get_darwin_linker_version(HOST_LINK_VERSION)'''
new = '''if (APPLE AND NOT CMAKE_LINKER MATCHES ".*lld.*")
  if (COMMAND get_darwin_linker_version)
    get_darwin_linker_version(HOST_LINK_VERSION)
  else()
    set(HOST_LINK_VERSION "1053.12")
  endif()'''
if old in s:
    open(p, "w").write(s.replace(old, new, 1))
PATCH

if [ ! -f "$SRC/tapi-inst/lib/libtapi.dylib" ]; then
    ( cd "$SRC/apple-libtapi" && INSTALLPREFIX="$SRC/tapi-inst" ./build.sh && INSTALLPREFIX="$SRC/tapi-inst" ./install.sh )
fi

# cctools' own llvm-c headers want a newer LLVM's config header beside them.
cp -f "$LLVM/include/llvm-c/Visibility.h" "$SRC/cctools-port/cctools/include/llvm-c/" 2>/dev/null || true

cd "$SRC/cctools-port/cctools"
make distclean > /dev/null 2>&1 || true
CPPFLAGS="-I$LLVM/include" ./configure \
    --prefix="$SRC/cctools-inst" \
    --target=arm-apple-darwin11 \
    --with-libtapi="$SRC/tapi-inst" \
    --with-llvm-config="$LLVM/bin/llvm-config" > /tmp/cctools-configure.log 2>&1
make -j"$(sysctl -n hw.ncpu)" > /tmp/cctools-build.log 2>&1
make install >> /tmp/cctools-build.log 2>&1

rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$SRC/cctools-inst/bin" "$OUT/"
cp "$SRC/tapi-inst/lib/libtapi.dylib" "$OUT/lib/"
ln -sf arm-apple-darwin11-ld "$OUT/bin/ld"
install_name_tool -rpath "$SRC/tapi-inst/lib" @executable_path/../lib "$OUT/bin/arm-apple-darwin11-ld"

"$OUT/bin/ld" -v 2>&1 | head -1
