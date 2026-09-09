# RevPrefs.bundle - the RevWebKit pane in Settings. It writes the
# space.kern0x1b.rev domain the compat dylib reads. The PS* superclasses live in
# Preferences.framework inside the Preferences process, not in the SDK, so they
# are resolved at load time - hence the flat namespace and dynamic lookup.
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RevPrefs
RevPrefs_FILES = ../../platform/prefs/RevRootListController.m ../../platform/prefs/RevAppsListController.m
RevPrefs_CFLAGS = -Os -fno-objc-arc -Wno-deprecated-declarations -Wno-unused \
	-I../../platform/prefs
RevPrefs_LDFLAGS = -undefined dynamic_lookup -flat_namespace
RevPrefs_FRAMEWORKS = Foundation UIKit CoreFoundation
RevPrefs_LIBRARIES = objc
RevPrefs_INSTALL_PATH = /Library/PreferenceBundles
RevPrefs_RESOURCE_DIRS = ../../platform/prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
