# Shared settings for every piece the tweak package builds.
#
# Theos lives where its own documentation puts it; the SDK is linked into
# $(THEOS)/sdks, which is where Theos looks for it. Both can be overridden from
# the environment, and neither is written down as an absolute path.
export THEOS ?= $(HOME)/theos

# The device is an iPhone 4S on iOS 6.1.3: one architecture, and a deployment
# target far below the SDK's own. The 13.7 SDK is the newest whose headers this
# engine still compiles against.
export TARGET := iphone:clang:13.7:6.0
export ARCHS := armv7

# Packages are plain .deb, not the rootless layout of modern jailbreaks.
export THEOS_PACKAGE_SCHEME :=

# Theos compiles with modules on. This SDK still ships mach-o/module.map under
# its deprecated name, which today's clang refuses as an error, so the pieces
# here are built the way the engine itself is built: without modules.
export ADDITIONAL_CFLAGS := -fno-modules -Wno-error=deprecated-module-dot-map
