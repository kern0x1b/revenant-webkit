from conan import ConanFile


class TestPackage(ConanFile):
    python_requires = "ios6-base/1.0@ios6/stable"
    python_requires_extend = "ios6-base.Ios6TestPackage"
