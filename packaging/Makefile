# The Safari substitution, packaged.
#
#   make package        -> packages/space.kern0x1b.rev_<version>_iphoneos-arm.deb
#   make package install DEVICE_IP=... -> builds and installs over SSH
#
# The engine frameworks themselves are built by CMake (see scripts/) and staged
# into the package by `make stage-engine`, because a .deb is the honest way to
# ship a system framework, not a scp of loose files.
include $(dir $(lastword $(MAKEFILE_LIST)))common.mk
include $(THEOS)/makefiles/common.mk

SUBPROJECTS := loader compat tls prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

# The engine is 60MB of frameworks built elsewhere; copy the staged layout in
# before packaging so the .deb carries everything the substitution needs.
ENGINE_STAGE := $(THEOS_PROJECT_DIR)/../dist/rev-sys-fw
before-package::
	@echo "staging the two loader plists"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" \
	          "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp "$(THEOS_PROJECT_DIR)/../platform/safari/rev-safari.plist" \
	    "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/RevSafari.plist"
	@cp "$(THEOS_PROJECT_DIR)/../platform/prefs/entry.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/RevWebKit.plist"
	@if [ -d "$(ENGINE_STAGE)" ]; then \
		echo "staging engine frameworks from $(ENGINE_STAGE)"; \
		mkdir -p "$(THEOS_STAGING_DIR)/usr/lib/rev-fw"; \
		rsync -a --exclude 'librev-c++*.dylib' "$(ENGINE_STAGE)/" "$(THEOS_STAGING_DIR)/usr/lib/rev-fw/"; \
		rsync -a "$(ENGINE_STAGE)/"librev-c++*.dylib "$(THEOS_STAGING_DIR)/usr/lib/"; \
	else \
		echo "note: $(ENGINE_STAGE) is missing - packaging without the engine."; \
		echo "      run scripts/layout-sys-frameworks.sh first to include it."; \
	fi
