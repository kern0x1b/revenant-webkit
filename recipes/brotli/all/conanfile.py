from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy, replace_in_file
from conan.tools.scm import Git
import os


class BrotliConan(ConanFile):
    name = "brotli"
    user = "revenant"
    channel = "stable"
    description = "Brotli compression format"
    license = "MIT"
    homepage = "https://github.com/google/brotli"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"
    options = {"fPIC": [True, False]}
    default_options = {"fPIC": True}

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def layout(self):
        cmake_layout(self)

    def source(self):
        source = self.conan_data["sources"][self.version]
        git = Git(self)
        git.fetch_commit(source["url"], source["commit"])
        # The command line tool is installed as an app bundle on Apple platforms
        # and iOS has nowhere to put one. Only the libraries are wanted here, and
        # they are copied out of the build folder directly.
        replace_in_file(self, os.path.join(self.source_folder, "CMakeLists.txt"),
                        "if(NOT BROTLI_BUNDLED_MODE)", "if(FALSE)")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.cache_variables["BROTLI_DISABLE_TESTS"] = True
        tc.cache_variables["BROTLI_BUNDLED_MODE"] = True
        tc.cache_variables["BUILD_SHARED_LIBS"] = False
        # brotli installs its command line tool as an app bundle on Apple
        # platforms, which iOS has no destination for.
        tc.cache_variables["CMAKE_MACOSX_BUNDLE"] = False
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "LICENSE", self.source_folder, os.path.join(self.package_folder, "licenses"))
        copy(self, "*.h", os.path.join(self.source_folder, "c", "include"),
             os.path.join(self.package_folder, "include"))
        for pattern in ("*.a", "*.lib"):
            copy(self, pattern, self.build_folder, os.path.join(self.package_folder, "lib"), keep_path=False)

    def package_info(self):
        self.cpp_info.components["brotlicommon"].libs = ["brotlicommon"]
        self.cpp_info.components["brotlidec"].libs = ["brotlidec"]
        self.cpp_info.components["brotlidec"].requires = ["brotlicommon"]
        self.cpp_info.components["brotlienc"].libs = ["brotlienc"]
        self.cpp_info.components["brotlienc"].requires = ["brotlicommon"]
