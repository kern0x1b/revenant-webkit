from conan import ConanFile


class RevenantWebKit(ConanFile):
    name = "revenant-webkit"
    description = "WebKit for armv7 / iOS 6"
    package_type = "application"

    python_requires = "ios6-base/1.0"
    python_requires_extend = "ios6-base.Ios6Port"

    def requirements(self):
        self.requires("openssl-ios6/3.0.15")
        self.requires("brotli/1.1.0")
        self.requires("libwebp/1.4.0")
        self.requires("libxslt/1.1.43")
        self.requires("libpsl/0.23.3")
        self.requires("icu/74.2")
        self.requires("woff2/1.0.2")
        self.requires("libcxx-armv7/21.1.0")
