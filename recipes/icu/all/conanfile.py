from conan import ConanFile
from conan.tools.files import copy, chdir
from conan.tools.layout import basic_layout
from conan.tools.apple import XCRun
from conan.tools.scm import Git
import os


class IcuConan(ConanFile):
    name = "icu"
    description = "ICU for armv7 / iOS 6"
    license = "Unicode-3.0"
    homepage = "https://icu.unicode.org"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"

    def requirements(self):
        self.requires("libcxx-armv7/21.1.0")

    def layout(self):
        basic_layout(self, src_folder="src")

    def source(self):
        source = self.conan_data["sources"][self.version]
        Git(self).fetch_commit(source["url"], source["commit"])

    def build(self):
        sdk = self.conf.get("tools.apple:sdk_path")
        target = f"armv7-apple-ios{self.settings.os.version}"
        icu_source = os.path.join(self.source_folder, "icu4c", "source")
        host_build = os.path.join(self.build_folder, "host")
        cross_build = os.path.join(self.build_folder, "cross")
        for folder in (host_build, cross_build):
            os.makedirs(folder, exist_ok=True)

        # ICU builds tools it then runs to generate its own data, so a cross
        # build needs a native one first. Conan's build context is exactly that
        # distinction, and this is the shape it takes for autotools.
        with chdir(self, host_build):
            self.run(f"{icu_source}/configure --enable-static --disable-shared"
                     " --disable-tests --disable-samples --disable-extras")
            self.run(f"make -j{os.cpu_count()}")

        libcxx = self.dependencies["libcxx-armv7"].cpp_info
        cxx_include = libcxx.includedirs[0]
        xcrun = XCRun(self)
        flags = f"-target {target} -isysroot {sdk} -O2"
        env = {
            "CC": xcrun.cc,
            "CXX": xcrun.cxx,
            "CFLAGS": flags,
            "CXXFLAGS": f"{flags} -nostdinc++ -isystem {cxx_include}"
                        " -D_LIBCPP_DISABLE_AVAILABILITY",
            "LDFLAGS": f"-target {target} -isysroot {sdk}",
        }
        exports = " ".join(f'{k}="{v}"' for k, v in env.items())
        with chdir(self, cross_build):
            self.run(f"{exports} {icu_source}/configure --host=arm-apple-darwin"
                     f" --with-cross-build={host_build}"
                     " --enable-static --disable-shared --disable-tests"
                     " --disable-samples --disable-extras --disable-tools"
                     f" --disable-renaming --prefix={self.package_folder}")
            self.run(f"make -j{os.cpu_count()}")
            self.run("make install")

    def package(self):
        copy(self, "LICENSE", os.path.join(self.source_folder, "icu4c"),
             os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.libs = ["icui18n", "icuuc", "icudata"]
        self.cpp_info.defines = ["U_STATIC_IMPLEMENTATION"]
