#!/usr/bin/env bash
# iOS 6 ships libc++ from 2012: no std::filesystem, no charconv, none of the
# C++17 runtime. Build our own for armv7 and link it statically, which is what
# LightKit does with its libLegacyIOSRuntime.dylib.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
XC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
SRC=$ROOT/third_party/llvm-project

if [ ! -d "$SRC" ]; then
    git clone --depth 1 --branch llvmorg-21.1.0 --filter=blob:none --sparse \
        https://github.com/llvm/llvm-project.git $SRC
    git -C $SRC sparse-checkout set libcxx libcxxabi libunwind runtimes cmake third-party llvm/cmake llvm/utils/llvm-lit libc
fi

rm -rf $ROOT/build-libcxx
cmake -S $SRC/runtimes -B $ROOT/build-libcxx -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$ROOT/third_party/libcxx-armv7 \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DCMAKE_OSX_SYSROOT=$SDK \
    -DCMAKE_OSX_ARCHITECTURES=armv7 \
    -DCMAKE_C_COMPILER=$XC/usr/bin/clang \
    -DCMAKE_CXX_COMPILER=$XC/usr/bin/clang++ \
    -DCMAKE_C_FLAGS="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -isysroot $SDK" \
    -DCMAKE_CXX_FLAGS="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -isysroot $SDK -DLIBCXX_NO_UTIMENSAT" \
    -DCMAKE_EXE_LINKER_FLAGS="-target armv7-apple-ios6.0 -isysroot $SDK" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLIBCXX_ENABLE_SHARED=ON -DLIBCXXABI_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=OFF -DLIBCXXABI_ENABLE_STATIC=OFF \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_ENABLE_FILESYSTEM=ON \
    -DLIBCXX_USE_COMPILER_RT=OFF \
    -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLLVM_CMAKE_DIR=$SRC/llvm/cmake/modules \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > $ROOT/build-libcxx-cfg.log 2>&1
cmake --build $ROOT/build-libcxx -j8 > $ROOT/build-libcxx-build.log 2>&1
cmake --install $ROOT/build-libcxx > /dev/null 2>&1
# Each library gets its own bundle-relative install name, and libc++'s
# reference to libc++abi is rewritten to match.
LIB=$ROOT/third_party/libcxx-armv7/lib
for name in libc++.1.dylib libc++abi.1.dylib; do
    [ -f "$LIB/$name" ] || cp "$ROOT/build-libcxx/lib/$name" "$LIB/$name" 2>/dev/null || true
done
cp -f $ROOT/build-libcxx/lib/libc++abi.1.0.dylib $LIB/ 2>/dev/null || true
for name in libc++.1.0.dylib libc++abi.1.0.dylib; do
    [ -f "$LIB/$name" ] || continue
    base=$(echo "$name" | sed "s/\.1\.0\./.1./")
    install_name_tool -id "@executable_path/Frameworks/$base" "$LIB/$name"
    install_name_tool -change "$LIB/libc++abi.1.dylib" "@executable_path/Frameworks/libc++abi.1.dylib" "$LIB/$name" 2>/dev/null || true
    install_name_tool -change "@rpath/libc++abi.1.dylib" "@executable_path/Frameworks/libc++abi.1.dylib" "$LIB/$name" 2>/dev/null || true
done

echo "libc++ armv7:"
ls $ROOT/third_party/libcxx-armv7/lib
