from conan import ConanFile
from conan.tools.gnu import Autotools, AutotoolsToolchain
from conan.tools.files import copy, chdir
from conan.tools.layout import basic_layout
from conan.tools.scm import Git
import os


class LibXsltConan(ConanFile):
    name = "libxslt"
    user = "ios6"
    channel = "stable"
    description = "XSLT and EXSLT, built against the libxml2 the SDK already ships"
    license = "MIT"
    homepage = "https://gitlab.gnome.org/GNOME/libxslt"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"

    def layout(self):
        basic_layout(self, src_folder="src")

    def source(self):
        source = self.conan_data["sources"][self.version]
        Git(self).fetch_commit(source["url"], source["commit"])

    def generate(self):
        sdk = self.conf.get("tools.apple:sdk_path")
        tc = AutotoolsToolchain(self)
        tc.configure_args += [
            "--disable-shared", "--enable-static",
            "--without-python", "--without-crypto", "--without-plugins",
            "--without-debugger", "--without-debug", "--without-profiler",
        ]
        # libxml2 comes from the SDK rather than from a package: the system one
        # is what WebCore links against at runtime on the device.
        tc.extra_cflags.append("-Wno-incompatible-function-pointer-types")
        env = tc.environment()
        env.define("LIBXML_CFLAGS", f"-I{sdk}/usr/include/libxml2")
        env.define("LIBXML_LIBS", "-lxml2")
        tc.generate(env)

    def build(self):
        with chdir(self, self.source_folder):
            if os.path.exists(os.path.join(self.source_folder, "autogen.sh")):
                self.run("NOCONFIGURE=1 ./autogen.sh")
        autotools = Autotools(self)
        autotools.configure()
        autotools.make()

    def package(self):
        copy(self, "Copyright", self.source_folder, os.path.join(self.package_folder, "licenses"))
        for header_dir in ("libxslt", "libexslt"):
            for root in (self.source_folder, self.build_folder):
                copy(self, "*.h", os.path.join(root, header_dir),
                     os.path.join(self.package_folder, "include", header_dir))
            copy(self, f"{header_dir}/*.h", self.build_folder,
                 os.path.join(self.package_folder, "include"))
        copy(self, "*.a", self.build_folder, os.path.join(self.package_folder, "lib"), keep_path=False)

    def package_info(self):
        self.cpp_info.libs = ["exslt", "xslt"]
        self.cpp_info.system_libs = ["xml2"]
