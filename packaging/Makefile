# The Safari substitution, packaged. conan build at the repository root runs
# this with the version from conanfile.py and the frameworks it laid out:
#
#   make package PACKAGE_VERSION=<version> ENGINE_STAGE=<laid-out frameworks>
include $(dir $(lastword $(MAKEFILE_LIST)))common.mk
include $(THEOS)/makefiles/common.mk

ifeq ($(PACKAGE_VERSION),)
$(error PACKAGE_VERSION is not set. The version lives in conanfile.py; build the package with conan build at the repository root)
endif
ifeq ($(wildcard $(ENGINE_STAGE)/WebCore.framework/WebCore),)
$(error ENGINE_STAGE does not hold the laid-out frameworks. Build the package with conan build at the repository root)
endif

SUBPROJECTS := loader compat tls prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" \
	          "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" \
	          "$(THEOS_STAGING_DIR)/usr/lib/rev-fw"
	@cp "$(THEOS_PROJECT_DIR)/../platform/safari/rev-safari.plist" \
	    "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/RevSafari.plist"
	@cp "$(THEOS_PROJECT_DIR)/../platform/prefs/entry.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/RevWebKit.plist"
	@rsync -a --exclude 'librev-c++*.dylib' "$(ENGINE_STAGE)/" "$(THEOS_STAGING_DIR)/usr/lib/rev-fw/"
	@rsync -a "$(ENGINE_STAGE)/"librev-c++*.dylib "$(THEOS_STAGING_DIR)/usr/lib/"
