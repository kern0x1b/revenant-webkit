# RevSafari.dylib - the loader MobileSubstrate injects into a launching app.
# It reads InjectedApps, sets DYLD_FRAMEWORK_PATH / DYLD_INSERT_LIBRARIES to
# this engine and re-execs, so the second launch runs on WebKit 2.54. It uses no
# Substrate API itself, and links only libSystem and CoreFoundation - the same
# linkage as the copy proven on the device.
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = RevSafari
RevSafari_FILES = ../../platform/safari/rev-safari-tweak.c
RevSafari_CFLAGS = -O2
RevSafari_FRAMEWORKS = CoreFoundation
RevSafari_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
