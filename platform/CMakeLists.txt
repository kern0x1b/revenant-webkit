cmake_minimum_required(VERSION 3.24)
project(revenant-platform C OBJC OBJCXX)

find_package(openssl REQUIRED CONFIG)
find_package(wasm3 REQUIRED CONFIG)

function(device_library target install_dir)
    set_target_properties(${target} PROPERTIES
        PREFIX ""
        INSTALL_NAME_DIR ${install_dir}
        BUILD_WITH_INSTALL_NAME_DIR ON)
    target_compile_options(${target} PRIVATE -Wall)
endfunction()

add_library(RevSafari SHARED safari/rev-safari-tweak.c)
device_library(RevSafari /Library/MobileSubstrate/DynamicLibraries)
target_compile_options(RevSafari PRIVATE -O2)
target_link_libraries(RevSafari PRIVATE "-framework CoreFoundation")

add_library(rev-safari-compat SHARED safari/safari-compat.mm safari/RevWasm.m)
device_library(rev-safari-compat /usr/lib)
target_compile_options(rev-safari-compat PRIVATE
    -O2 -fno-objc-arc -Wno-deprecated-declarations -Wno-unused
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0)
target_link_options(rev-safari-compat PRIVATE -nostdlib++)
target_link_libraries(rev-safari-compat PRIVATE
    objc "-framework Foundation" "-framework CoreFoundation" sqlite3 wasm3::wasm3)

add_library(rev-TLS SHARED safari/tls-openssl.c)
device_library(rev-TLS /usr/lib)
target_compile_options(rev-TLS PRIVATE -O2)
target_link_libraries(rev-TLS PRIVATE
    openssl::openssl "-framework CoreFoundation" "-framework Security")

add_library(RevPrefs SHARED prefs/RevRootListController.m prefs/RevAppsListController.m)
device_library(RevPrefs /Library/PreferenceBundles/RevPrefs.bundle)
set_target_properties(RevPrefs PROPERTIES SUFFIX "")
target_include_directories(RevPrefs PRIVATE prefs)
target_compile_options(RevPrefs PRIVATE -Os -fno-objc-arc -Wno-deprecated-declarations -Wno-unused)
target_link_options(RevPrefs PRIVATE -undefined dynamic_lookup -flat_namespace)
target_link_libraries(RevPrefs PRIVATE
    objc "-framework Foundation" "-framework CoreFoundation" "-framework UIKit")

install(TARGETS RevSafari LIBRARY DESTINATION Library/MobileSubstrate/DynamicLibraries)
install(FILES safari/rev-safari.plist
    DESTINATION Library/MobileSubstrate/DynamicLibraries RENAME RevSafari.plist)
install(TARGETS rev-safari-compat rev-TLS LIBRARY DESTINATION usr/lib)
install(TARGETS RevPrefs LIBRARY DESTINATION Library/PreferenceBundles/RevPrefs.bundle)
install(DIRECTORY prefs/Resources/ DESTINATION Library/PreferenceBundles/RevPrefs.bundle)
install(FILES prefs/entry.plist
    DESTINATION Library/PreferenceLoader/Preferences RENAME RevWebKit.plist)
