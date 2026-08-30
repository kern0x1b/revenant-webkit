# Cross-compile modern WebKit trunk for armv7 / iOS 6.
# libc\+\+ headers come from the current Xcode SDK because trunk needs C++23;
# the C library and frameworks come from the iOS 10.3 SDK, which still ships
# armv7 slices and accepts a 6.0 deployment target.
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_OSX_SYSROOT $ENV{IOS_SDK})
set(CMAKE_OSX_ARCHITECTURES armv7)
set(CMAKE_OSX_DEPLOYMENT_TARGET 6.0)
set(CMAKE_C_COMPILER /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)
set(CMAKE_CXX_COMPILER /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++)

set(SDK6 $ENV{IOS_SDK})
set(CXX21 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/usr/include/c++/v1)
set(COMMON "-target armv7-apple-ios6.0 -isysroot ${SDK6}")
set(CMAKE_C_FLAGS_INIT "${COMMON} -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_CXX_FLAGS_INIT "${COMMON} -nostdinc++ -isystem ${CXX21} -D_LIBCPP_DISABLE_AVAILABILITY -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${COMMON}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${COMMON}")

set(CMAKE_FIND_ROOT_PATH ${SDK6})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# mig needs mach/*.defs, which only the macOS SDK ships.
set(MIG_SYSROOT /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk)
