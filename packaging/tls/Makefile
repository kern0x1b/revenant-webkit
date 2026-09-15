# rev-TLS.dylib - the TLS this substitution speaks. The loader inserts it, so it
# secures every https connection the browser makes; app/tls-openssl.c records why
# the system's own TLS is not enough on this release. OpenSSL is linked in
# statically from the openssl package.
TLS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(TLS_DIR)../common.mk
include $(THEOS)/makefiles/common.mk

IOS6_DEPS := $(TLS_DIR)../../build/conan/armv7/ios6-deps.env
ifeq ($(wildcard $(IOS6_DEPS)),)
$(error $(IOS6_DEPS) is missing. Run scripts/configure-engine.sh, or bash scripts/deps.sh)
endif
include $(IOS6_DEPS)

OPENSSL = $(IOS6_HOST_OPENSSL)

LIBRARY_NAME = rev-TLS
rev-TLS_FILES = ../../app/tls-openssl.c
rev-TLS_CFLAGS = -O2 -I$(OPENSSL)/include
rev-TLS_LDFLAGS = $(OPENSSL)/lib/libssl.a $(OPENSSL)/lib/libcrypto.a
rev-TLS_FRAMEWORKS = CoreFoundation Security
rev-TLS_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
