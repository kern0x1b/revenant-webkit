from conan import ConanFile


class RevenantWebKit(ConanFile):
    name = "revenant-webkit"
    description = "WebKit for armv7 / iOS 6"
    package_type = "application"

    python_requires = "ios6-base/1.0@ios6/stable"
    python_requires_extend = "ios6-base.Ios6Port"

    def requirements(self):
        self.requires("openssl/3.0.15@ios6/stable")
        self.requires("brotli/1.1.0@ios6/stable")
        self.requires("libwebp/1.4.0@ios6/stable")
        self.requires("libxslt/1.1.43@ios6/stable")
        self.requires("libpsl/0.23.3@ios6/stable")
        self.requires("icu/74.2@ios6/stable")
        self.requires("woff2/1.0.2@ios6/stable")
        self.requires("libcxx/21.1.0@ios6/stable")
