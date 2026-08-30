# Toolchain: armv7, iOS 6 deployment target, built against the SDK of this
# WebKit's own era. iOS 11 dropped 32-bit, so 10.3 is the newest SDK that still
# has armv7 slices of the system libraries.
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_OSX_SYSROOT $ENV{IOS_SDK})
set(CMAKE_OSX_ARCHITECTURES armv7)
set(CMAKE_OSX_DEPLOYMENT_TARGET "")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)

set(EXTRA "-arch armv7 -isysroot $ENV{IOS_SDK} -miphoneos-version-min=6.0 -fno-objc-arc")
set(CMAKE_C_FLAGS_INIT "${EXTRA}")
# Modern clang looks for the C++ headers inside its own toolchain; this SDK
# carries its own libc++, and mixing the two does not work.
# This SDK carries no C++ headers, and modern ones reference symbols that do not
# exist in iOS 6's libc++. These are libc++ 3.9 — the compiler era of the SDK.
set(CXXLIB "-nostdinc++ -isystem ${WEBKIT_IOS6_ROOT}/third_party/libcxx-3.9.1/include")
set(CMAKE_CXX_FLAGS_INIT "${EXTRA} -std=c++14 ${CXXLIB}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${EXTRA}")

set(CMAKE_FIND_ROOT_PATH $ENV{IOS_SDK})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
