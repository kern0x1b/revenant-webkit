# rev-TLS.dylib - the TLS this substitution speaks. The loader inserts it, so it
# secures every https connection the browser makes; app/tls-openssl.c records why
# the system's own TLS is not enough on this release. OpenSSL is linked in
# statically from third_party/openssl-armv7.
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk
include $(THEOS)/makefiles/common.mk

OPENSSL = ../../third_party/openssl-armv7

LIBRARY_NAME = rev-TLS
rev-TLS_FILES = ../../app/tls-openssl.c
rev-TLS_CFLAGS = -O2 -I$(OPENSSL)/include
rev-TLS_LDFLAGS = $(OPENSSL)/lib/libssl.a $(OPENSSL)/lib/libcrypto.a
rev-TLS_FRAMEWORKS = CoreFoundation Security
rev-TLS_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
