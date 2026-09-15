from conan import ConanFile
from conan.tools.files import copy, chdir
from conan.tools.layout import basic_layout
from conan.tools.apple import XCRun
from conan.tools.scm import Git
import os
import json


class IcuConan(ConanFile):
    name = "icu"
    user = "ios6"
    channel = "stable"
    description = "ICU for armv7 / iOS 6, and for the Mac that tests its data"
    license = "Unicode-3.0"
    homepage = "https://icu.unicode.org"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"
    exports = "icu-keep-languages.txt"

    _dropped_features = ("rbnf_tree", "translit")

    @property
    def _cross(self):
        return self.settings.os == "iOS"

    def requirements(self):
        if self._cross:
            self.requires("libcxx/21.1.0@ios6/stable")

    def layout(self):
        basic_layout(self, src_folder="src")

    def source(self):
        source = self.conan_data["sources"][self.version]
        Git(self).fetch_commit(source["url"], source["commit"])

    def build(self):
        icu_source = os.path.join(self.source_folder, "icu4c", "source")
        host_build = os.path.join(self.build_folder, "host")
        cross_build = os.path.join(self.build_folder, "cross")
        for folder in (host_build, cross_build):
            os.makedirs(folder, exist_ok=True)
        data_filter = self._data_filter()

        # ICU builds tools it then runs to generate its own data, so a cross
        # build needs a native one first. Conan's build context is exactly that
        # distinction, and this is the shape it takes for autotools.
        prefix = "" if self._cross else f" --prefix={self.package_folder}"
        with chdir(self, host_build):
            self.run(f'{data_filter} {icu_source}/configure --enable-static --disable-shared'
                     f" --disable-tests --disable-samples --disable-extras{prefix}")
            self.run(f"{data_filter} make -j{os.cpu_count()}")
            if not self._cross:
                self.run("make install")
                return

        sdk = self.conf.get("tools.apple:sdk_path")
        target = f"armv7-apple-ios{self.settings.os.version}"
        libcxx = self.dependencies["libcxx"].cpp_info
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
            "ICU_DATA_FILTER_FILE": self._filter_file,
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

    def _data_filter(self):
        languages = open(os.path.join(self.recipe_folder,
                                      "icu-keep-languages.txt")).read().split()
        rules = {
            "localeFilter": {"filterType": "language", "includelist": languages},
            "featureFilters": {name: "exclude" for name in self._dropped_features},
        }
        with open(self._filter_file, "w") as out:
            json.dump(rules, out)
        self.output.info(f"icu data: {len(languages)} languages, "
                         f"without {', '.join(self._dropped_features)}")
        return f'ICU_DATA_FILTER_FILE="{self._filter_file}"'

    @property
    def _filter_file(self):
        return os.path.join(self.build_folder, "icu-data-filter.json")

    def package(self):
        copy(self, "LICENSE", os.path.join(self.source_folder, "icu4c"),
             os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.libs = ["icui18n", "icuuc", "icudata"]
        self.cpp_info.defines = ["U_STATIC_IMPLEMENTATION"]
