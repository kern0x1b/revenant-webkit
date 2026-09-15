from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, cmake_layout
from conan.tools.files import copy
import os


class RevenantDeviceToolsConan(ConanFile):
    name = "revenant-device-tools"
    version = "1.0.0"
    user = "revenant"
    channel = "stable"
    description = "Command-line probes the port runs on the phone: process list, memory by VM tag, synthetic touch, jetsam limit"
    license = "MIT"
    package_type = "application"
    settings = "os", "arch", "compiler", "build_type"

    _tools = ("revmem", "revpid", "revtouch", "raise-memory-limit")
    _entitled = ("revmem", "raise-memory-limit")
    _launchd_plist = "space.kern0x1b.memorylimit.plist"

    def export_sources(self):
        root = os.path.join(self.recipe_folder, "..", "..", "..")
        copy(self, "CMakeLists.txt", self.recipe_folder, self.export_sources_folder)
        copy(self, "*.xml", os.path.join(self.recipe_folder, "entitlements"),
             os.path.join(self.export_sources_folder, "entitlements"))
        copy(self, "LICENSE", root, self.export_sources_folder)
        for tool in self._tools:
            copy(self, f"{tool}.c", os.path.join(root, "tools"), os.path.join(self.export_sources_folder, "tools"))
        copy(self, self._launchd_plist, os.path.join(root, "platform", "device"),
             os.path.join(self.export_sources_folder, "platform", "device"))

    def configure(self):
        self.settings.rm_safe("compiler.cppstd")
        self.settings.rm_safe("compiler.libcxx")

    def build_requirements(self):
        self.tool_requires("ldid/2.1.5@ios6/stable")

    def layout(self):
        cmake_layout(self, src_folder=".")

    def generate(self):
        CMakeToolchain(self).generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
        for tool in self._tools:
            entitlements = ""
            if tool in self._entitled:
                entitlements = os.path.join(self.source_folder, "entitlements", f"{tool}.xml")
            self.run(f'ldid -S{entitlements} "{os.path.join(self.build_folder, tool)}"')

    def package(self):
        copy(self, "LICENSE", self.source_folder, os.path.join(self.package_folder, "licenses"))
        for tool in self._tools:
            copy(self, tool, self.build_folder, os.path.join(self.package_folder, "bin"))
        copy(self, self._launchd_plist, os.path.join(self.source_folder, "platform", "device"),
             os.path.join(self.package_folder, "res", "LaunchDaemons"))

    def package_info(self):
        self.cpp_info.includedirs = []
        self.cpp_info.libdirs = []
        self.cpp_info.bindirs = ["bin"]
        self.cpp_info.resdirs = ["res"]
        self.conf_info.define_path("user.revenant:device_tools_launchd",
                                   os.path.join(self.package_folder, "res", "LaunchDaemons", self._launchd_plist))
