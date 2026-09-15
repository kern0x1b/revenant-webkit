IOS6_DEPS := $(dir $(lastword $(MAKEFILE_LIST)))../build/engine/armv7-system/conan/ios6-deps.env

ifeq ($(wildcard $(IOS6_DEPS)),)
$(error $(IOS6_DEPS) is missing. Run conan install at the repository root, or bash scripts/deps.sh)
endif

include $(IOS6_DEPS)

IOS6_SHARED ?= $(if $(CONAN_HOME),$(CONAN_HOME),$(HOME)/.conan2)/packaging/ios6.mk

ifeq ($(wildcard $(IOS6_SHARED)),)
$(error $(IOS6_SHARED) is missing. Run: conan config install <ios6-toolchain>/config)
endif

include $(IOS6_SHARED)
