cmake_minimum_required(VERSION 3.24)
project(revenant-app OBJC)

if (NOT ENGINE_BUILD OR NOT CLASS_PREFIX_HEADER)
    message(FATAL_ERROR "ENGINE_BUILD and CLASS_PREFIX_HEADER name the engine this application hosts; configure through conan build")
endif ()

find_package(openssl REQUIRED CONFIG)

add_executable(RevWebViewHost
    rev-webview-host.m
    ModernTLSURLProtocol.m
    WebKitUIKitDelegate.m)

target_include_directories(RevWebViewHost SYSTEM PRIVATE
    ${ENGINE_BUILD}/WebKitLegacy/Headers
    ${ENGINE_BUILD}/WebCore.framework/PrivateHeaders
    ${ENGINE_BUILD}/WTF/Headers)

target_compile_options(RevWebViewHost PRIVATE
    -g -fno-objc-arc
    "SHELL:-include ${CLASS_PREFIX_HEADER}"
    -F${ENGINE_BUILD})

target_link_options(RevWebViewHost PRIVATE
    -F${ENGINE_BUILD}
    -Wl,-dead_strip
    -Wl,-rpath,@executable_path/Frameworks)

target_link_libraries(RevWebViewHost PRIVATE
    "-framework WebKitLegacy"
    "-framework UIKit" "-framework Foundation" "-framework QuartzCore"
    "-framework CoreGraphics" "-framework ImageIO" "-framework MobileCoreServices"
    openssl::openssl z)

install(TARGETS RevWebViewHost RUNTIME DESTINATION .)
install(FILES cacert.pem start.html DESTINATION .)
