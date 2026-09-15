from conan import ConanFile


class RevenantHostTests(ConanFile):
    name = "revenant-host-tests"
    settings = "os", "arch", "compiler", "build_type"
    python_requires = "ios6-base/1.0@ios6/stable"

    def requirements(self):
        self.requires("icu/[*]@revenant/stable")

    def generate(self):
        self.python_requires["ios6-base"].module.DependencyEnv(self).generate()
