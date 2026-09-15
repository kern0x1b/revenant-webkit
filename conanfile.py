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
