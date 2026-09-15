from io import StringIO
import os

from conan import ConanFile
from conan.errors import ConanException
from conan.tools.layout import basic_layout


class TestPackage(ConanFile):
    settings = "os", "arch", "compiler", "build_type"
    test_type = "explicit"

    _tools = ("revmem", "revpid", "revtouch", "raise-memory-limit")
    _entitlements = {
        "revmem": "task_for_pid-allow",
        "raise-memory-limit": "com.apple.private.memorystatus",
    }

    def requirements(self):
        self.requires(self.tested_reference_str)

    def layout(self):
        basic_layout(self)

    def _output(self, command):
        output = StringIO()
        self.run(command, stdout=output, stderr=output)
        return output.getvalue()

    def test(self):
        tools = self.dependencies["revenant-device-tools"]
        bindir = tools.cpp_info.bindirs[0]
        for tool in self._tools:
            binary = os.path.join(bindir, tool)
            if not os.path.isfile(binary):
                raise ConanException(f"{binary} is missing")
            archs = self._output(f'lipo -archs "{binary}"').split()
            if archs != ["armv7"]:
                raise ConanException(f"{tool} is {archs}, not a thin armv7 Mach-O")
            if "LC_ENCRYPTION_INFO" in self._output(f'otool -l "{binary}"'):
                raise ConanException(f"{tool} carries LC_ENCRYPTION_INFO, which iOS 6 refuses to run: "
                                     "it was linked by the system ld instead of ld64")
            signature = self._output(f'codesign -dv "{binary}"')
            if "CodeDirectory" not in signature:
                raise ConanException(f"{tool} carries no code signature: {signature}")
            entitlement = self._entitlements.get(tool)
            if entitlement and entitlement not in self._output(f'codesign -d --entitlements - "{binary}"'):
                raise ConanException(f"{tool} is signed without {entitlement}")

        plist = os.path.join(tools.cpp_info.resdirs[0], "LaunchDaemons", "space.kern0x1b.memorylimit.plist")
        if not os.path.isfile(plist):
            raise ConanException(f"{plist} is missing")
