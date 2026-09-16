CHARON_CONFIG ?= $(if $(IOS6_TOOLCHAIN),$(IOS6_TOOLCHAIN)/config,$(shell conan config home))
include $(CHARON_CONFIG)/extensions/charon/charon.mk
