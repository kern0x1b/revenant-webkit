cmake_minimum_required(VERSION 3.24)
project(ios6compat C CXX OBJC)

if (NOT WEBKIT_IOS6_LIBCXX_DIR OR NOT LIBPSL_INCLUDE_DIR)
    message(FATAL_ERROR "WEBKIT_IOS6_LIBCXX_DIR and LIBPSL_INCLUDE_DIR come from the dependency graph; configure through conan build")
endif ()

add_library(ios6compat STATIC
    ios6_compat.c
    ios6_missing.c
    ios6_missing_constants.c
    ios6_coretext.c
    ios6_coregraphics.c
    ios6_missing_classes.m
    ios6_uttype.m
    ios6_palswift.m
    ios6_uicolor.m
    ios6_avaudio.m
    ios6_media_stubs.cpp)

set_target_properties(ios6compat PROPERTIES CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)

target_include_directories(ios6compat SYSTEM PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/stubs
    $<$<COMPILE_LANGUAGE:CXX>:${WEBKIT_IOS6_LIBCXX_DIR}/include/c++/v1>)
set_source_files_properties(ios6_compat.c PROPERTIES INCLUDE_DIRECTORIES ${LIBPSL_INCLUDE_DIR})

target_compile_options(ios6compat PRIVATE
    -O2
    -fno-objc-arc
    -Wno-builtin-requires-header
    -Wno-protocol
    -Wno-objc-designated-initializers
    "$<$<COMPILE_LANGUAGE:OBJC,CXX>:SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/stubs/ios6_dispatch_compat.h>"
    "$<$<COMPILE_LANGUAGE:CXX>:-nostdinc++>")

target_compile_definitions(ios6compat PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:WEBKIT_IOS6_OBJC_EXTRAS>
    $<$<COMPILE_LANGUAGE:CXX>:_LIBCPP_DISABLE_AVAILABILITY>)
