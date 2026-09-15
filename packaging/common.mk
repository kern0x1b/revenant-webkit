IOS6_SHARED ?= $(if $(CONAN_HOME),$(CONAN_HOME),$(HOME)/.conan2)/packaging/ios6.mk

ifeq ($(wildcard $(IOS6_SHARED)),)
$(error $(IOS6_SHARED) is missing. Run: conan config install <ios6-toolchain>/config)
endif

include $(IOS6_SHARED)
