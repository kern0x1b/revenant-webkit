# rev-safari-compat.dylib - inserted into the re-exec'd Safari beside the engine.
# It carries the iOS 6 ABI stubs modern WebKit expects, the bookmarks start page,
# the preference reads, and window.WebAssembly through the wasm3 interpreter
# (JavaScriptCore's own WebAssembly is 64-bit only).
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk
include $(THEOS)/makefiles/common.mk

WASM3 = $(IOS6_HOST_WASM3)

LIBRARY_NAME = rev-safari-compat
rev-safari-compat_FILES = ../../platform/safari/safari-compat.mm ../../app/RevWasm.m
# Two things have to match the copy proven on the device, or this dylib either
# fails to load or fights the engine:
#   - no libc++. Safari already carries the engine's own C++ runtime; pulling in
#     the shared cache's would put two of them in one process.
#   - no _FORTIFY_SOURCE. It rewrites memcpy and friends into __*_chk symbols,
#     which is linkage this release was never built against.
rev-safari-compat_CFLAGS = -O2 -fno-objc-arc -Wno-deprecated-declarations -Wno-unused \
	-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
	-I$(WASM3)/include -I../../app
rev-safari-compat_LDFLAGS = -nostdlib++ $(WASM3)/lib/libm3.a
rev-safari-compat_FRAMEWORKS = Foundation CoreFoundation
rev-safari-compat_LIBRARIES = objc sqlite3
rev-safari-compat_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
