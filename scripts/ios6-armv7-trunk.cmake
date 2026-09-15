# Cross-compile modern WebKit trunk for armv7 / iOS 6.
# libc++ headers come from the libcxx package because trunk needs C++23; the C
# library and frameworks come from the iOS 13.7 SDK, which still ships armv7
# slices and accepts a 6.0 deployment target.
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm)
# The SDK is remembered in the cache, not read from the environment each time.
#
# ninja re-runs cmake by itself whenever a source list changes, and that run does
# not inherit the shell that configured the build. Reading the environment there
# yields nothing and cmake quietly falls back to the newest installed SDK, which
# compiles the whole tree against headers from a system fifteen years newer than
# the target. It looks like hundreds of syntax errors in Apple's own headers.
if(NOT IOS6_SDK OR NOT IOS6_DEPLOYMENT_TARGET)
    message(FATAL_ERROR "IOS6_SDK and IOS6_DEPLOYMENT_TARGET come from the Conan profile; configure through conan build")
endif()
set(IOS6_SDK "${IOS6_SDK}" CACHE PATH "SDK used to build for armv7" FORCE)
set(IOS6_DEPLOYMENT_TARGET "${IOS6_DEPLOYMENT_TARGET}" CACHE STRING "Oldest iOS the build runs on" FORCE)
set(CMAKE_OSX_SYSROOT ${IOS6_SDK} CACHE PATH "SDK the compiler is pointed at" FORCE)
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES IOS6_SDK IOS6_DEPLOYMENT_TARGET)
set(WEBKIT_IOS6 ON CACHE BOOL "Building the iOS 6 armv7 port" FORCE)
set(CMAKE_OSX_ARCHITECTURES armv7)
set(CMAKE_OSX_DEPLOYMENT_TARGET ${IOS6_DEPLOYMENT_TARGET})
# Xcode is not required to build this port: the Command Line Tools carry the
# same clang and the same compiler-rt, the SDK comes from theos/sdks, and the
# linker comes from the ld64 package. DEVELOPER_DIR
# selects which of the two is used; whichever it is, the compilers live in one
# of these two places.
if (DEFINED ENV{DEVELOPER_DIR})
    set(DEVELOPER_ROOT $ENV{DEVELOPER_DIR})
else ()
    execute_process(COMMAND xcode-select -p
        OUTPUT_VARIABLE DEVELOPER_ROOT OUTPUT_STRIP_TRAILING_WHITESPACE)
endif ()
if (EXISTS ${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)
    set(TOOLCHAIN_BIN ${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin)
else ()
    set(TOOLCHAIN_BIN ${DEVELOPER_ROOT}/usr/bin)
endif ()
set(CMAKE_C_COMPILER ${TOOLCHAIN_BIN}/clang)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_BIN}/clang++)

set(SDK6 ${IOS6_SDK})
set(COMMON "-target armv7-apple-ios${IOS6_DEPLOYMENT_TARGET} -isysroot ${SDK6}")
set(CMAKE_C_FLAGS_INIT "${COMMON} -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_OBJC_FLAGS_INIT "${COMMON} -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_CXX_FLAGS_INIT "${COMMON} -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_OBJCXX_FLAGS_INIT "${COMMON} -DWEBKIT_IOS6_NO_READLINE")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${COMMON}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${COMMON}")

set(CMAKE_FIND_ROOT_PATH ${SDK6})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# mig needs mach/*.defs, which only the macOS SDK ships.
if (EXISTS ${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
    set(MIG_SYSROOT ${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
else ()
    set(MIG_SYSROOT ${DEVELOPER_ROOT}/SDKs/MacOSX.sdk)
endif ()
