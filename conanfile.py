import os
import plistlib
import re
import shutil
import sys
from io import StringIO

from conan import ConanFile
from conan.errors import ConanException
from conan.tools.apple import XCRun
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain
from conan.tools.env import Environment
from conan.tools.files import copy, mkdir, rmdir


class RevenantWebKit(ConanFile):
    name = "revenant-webkit"
    version = "0.1.0"
    description = "WebKit for armv7 / iOS 6"
    package_type = "application"
    options = {"prefixed": [True, False]}
    default_options = {"prefixed": False}
    generators = "VirtualBuildEnv"

    python_requires = "ios6-base/1.0@ios6/stable"
    python_requires_extend = "ios6-base.Ios6Port"

    _cmake_packages = ("icu", "libcxx", "libxml2", "libxslt", "openssl", "wasm3")
    _system_frameworks = {
        "JavaScriptCore": ("JavaScriptCore", "/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore"),
        "WebCore": ("WebCore", "/System/Library/PrivateFrameworks/WebCore.framework/WebCore"),
        "WebKitLegacy": ("WebKit", "/System/Library/PrivateFrameworks/WebKit.framework/WebKit"),
    }
    _runtime = {
        "libc++.1.0.dylib": "librev-c++.1.dylib",
        "libc++abi.1.0.dylib": "librev-c++abi.1.dylib",
    }
    _webcore_left_out = ("WebCore", "Headers", "PrivateHeaders", "Modules", "_CodeSignature")
    _engine_location = "usr/lib/rev-fw"

    def requirements(self):
        self.requires("openssl/3.0.15@revenant/stable")
        self.requires("brotli/1.1.0@revenant/stable")
        self.requires("libwebp/1.4.0@revenant/stable")
        self.requires("libxml2/2.15.4@revenant/stable")
        self.requires("libxslt/1.1.45@revenant/stable")
        self.requires("libpsl/0.23.3@revenant/stable")
        self.requires("icu/74.2@revenant/stable")
        self.requires("woff2/1.0.2@revenant/stable")
        self.requires("libcxx/21.1.0@ios6/stable")
        self.requires("wasm3/cci.20260905@revenant/stable")

    def build_requirements(self):
        self.tool_requires("cmake/4.4.3")
        self.tool_requires("ninja/1.13.2")
        self.tool_requires("ldid/2.1.5@ios6/stable")

    def layout(self):
        variant = "prefixed" if self.options.prefixed else "system"
        self.folders.source = "webkit-254"
        self.folders.build = os.path.join("build", "engine", f"{self.settings.arch}-{variant}")
        self.folders.generators = os.path.join(self.folders.build, "conan")

    def _dependency(self, name):
        return self.dependencies[name].package_folder

    def _cpp_info(self, name):
        return self.dependencies[name].cpp_info.aggregated_components()

    def _include_dir(self, name):
        return self._cpp_info(name).includedirs[0]

    def _library(self, dependency, library):
        info = self._cpp_info(dependency)
        if library not in info.libs:
            raise ConanException(f"{dependency} does not provide {library}; it provides {', '.join(info.libs)}")
        for folder in info.libdirs:
            path = os.path.join(folder, f"lib{library}.a")
            if os.path.isfile(path):
                return path
        raise ConanException(f"{dependency} declares {library} but no lib{library}.a is in {', '.join(info.libdirs)}")

    @property
    def _sdk(self):
        sdk = self.conf.get("tools.apple:sdk_path", check_type=str)
        if not sdk:
            raise ConanException("tools.apple:sdk_path is not set; install with the port's profile")
        return sdk

    @property
    def _compat_library(self):
        return os.path.join(self.build_folder, "compat", "libios6compat.a")

    @property
    def _exports(self):
        if self.options.prefixed:
            return os.path.join(self.build_folder, "WebKitLegacy-iOS-rev.exp")
        return os.path.join(self.source_folder, "Source", "WebKitLegacy", "WebKitLegacy-iOS.exp")

    @property
    def _stage(self):
        return os.path.join(self.build_folder, "stage")

    @property
    def _application(self):
        return os.path.join(self.build_folder, "RevWebViewHost.app")

    def generate(self):
        super().generate()
        root = self.recipe_folder
        sdk = self._sdk
        libcxx = self._include_dir("libcxx")
        stubs = os.path.join(root, "compat", "stubs")
        prefix_header = "ios6_class_prefix.h" if self.options.prefixed else "ios6_class_names.h"
        target = f"armv7-apple-ios{self.settings.os.version}"
        tuning = " ".join(self.conf.get("tools.build:cxxflags", default=[], check_type=list))
        defines = "-DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
        common = f"-flto=thin -mllvm -hot-cold-split=false -target {target} {tuning} -isysroot {sdk}"
        cxx_flags = (f"{common} -nostdinc++ -isystem {libcxx} "
                     f"-isystem {stubs} -include {stubs}/ios6_dispatch_compat.h -include {stubs}/{prefix_header} "
                     f"-D_LIBCPP_DISABLE_AVAILABILITY {defines}")
        c_flags = f"{common} -isystem {stubs} -include {stubs}/{prefix_header} {defines}"
        linker = os.path.join(self.dependencies.build["ld64"].package_folder, "bin")
        link_libraries = " ".join((self._library("brotli", "brotlidec"), self._library("brotli", "brotlicommon"),
                                   self._library("libpsl", "psl")))
        link_folders = " ".join(f"-L{folder}" for name in ("libxslt", "woff2") for folder in self._cpp_info(name).libdirs)

        if self.options.prefixed:
            os.makedirs(self.build_folder, exist_ok=True)
            self.run(f'"{sys.executable}" "{root}/tools/prefix-exports.py" "{stubs}/ios6_class_prefix.h" '
                     f'"{self.source_folder}/Source/WebKitLegacy/WebKitLegacy-iOS.exp" "{self._exports}"')

        self.conf.define("tools.cmake.cmaketoolchain:user_toolchain",
                         [os.path.join(root, "scripts", "ios6-armv7-trunk.cmake")])
        tc = CMakeToolchain(self)
        tc.blocks.remove("apple_system")
        variables = tc.cache_variables
        variables.update({
            "IOS6_SDK": sdk,
            "IOS6_DEPLOYMENT_TARGET": str(self.settings.os.version),
            "CMAKE_OSX_SYSROOT": sdk,
            "CMAKE_OSX_DEPLOYMENT_TARGET": str(self.settings.os.version),
            "CMAKE_BUILD_TYPE": "Release",
            "CMAKE_PROJECT_WebKit_INCLUDE": os.path.join(root, "scripts", "ios6-conan-targets.cmake"),
            "PORT": "Cocoa",
            "DEVELOPER_MODE": "OFF",
            "PYTHON_EXECUTABLE": sys.executable,
            "SWIFT_REQUIRED": "OFF",
            "WEBKIT_IOS6_CRYPTO_LIB": self._library("openssl", "crypto"),
            "WEBKIT_IOS6_COMPAT_LIB": self._compat_library,
            "WEBKIT_IOS6_EXPORTS": self._exports,
            "WEBKIT_IOS6_LIBCXX_DIR": self._dependency("libcxx"),
            "WEBKIT_IOS6_SIZE_OPTIMIZED": "ON",
            "WEBKIT_NO_AVAILABILITY_OVERLAY": "ON",
            "CMAKE_DISABLE_PRECOMPILE_HEADERS": "OFF",
            "USE_WEBP": "ON",
            "WebP_INCLUDE_DIR": self._include_dir("libwebp"),
            "WebP_LIBRARY": self._library("libwebp", "webp"),
            "WebP_DEMUX_LIBRARY": self._library("libwebp", "webpdemux"),
            "USE_WOFF2": "ON",
            "WOFF2_INCLUDE_DIR": self._include_dir("woff2"),
            "WOFF2_DEC_INCLUDE_DIR": self._include_dir("woff2"),
            "WOFF2_LIBRARY": self._library("woff2", "woff2common"),
            "WOFF2_DEC_LIBRARY": self._library("woff2", "woff2dec"),
            "ENABLE_WEBKIT_LEGACY": "ON",
            "ENABLE_WEBKIT": "OFF",
            "ENABLE_TOUCH_EVENTS": "ON",
            "ENABLE_IOS_TOUCH_EVENTS": "OFF",
            "ENABLE_WEBKIT_OVERFLOW_SCROLLING_CSS_PROPERTY": "ON",
            "ENABLE_NOTIFICATIONS": "ON",
            "ENABLE_FULLSCREEN_API": "ON",
            "ENABLE_WEBGPU": "OFF",
            "ENABLE_WEBDRIVER": "OFF",
            "ENABLE_WEBINSPECTORUI": "OFF",
            "ENABLE_API_TESTS": "OFF",
            "ENABLE_MINIBROWSER": "OFF",
            "ENABLE_WEB_RTC": "OFF",
            "USE_LIBWEBRTC": "OFF",
            "ENABLE_MEDIA_STREAM": "ON",
            "ENABLE_MEDIA_RECORDER": "OFF",
            "ENABLE_WEB_CODECS": "OFF",
            "ENABLE_COCOA_WEBM_PLAYER": "OFF",
            "ENABLE_AV1": "OFF",
            "ENABLE_XSLT": "ON",
            "ENABLE_SPEECH_SYNTHESIS": "OFF",
            "ENABLE_WEB_SPEECH": "OFF",
            "ENABLE_WEBGL": "ON",
            "ENABLE_GAMEPAD": "OFF",
            "ENABLE_PIXEL_FORMAT_RGBA16F": "OFF",
            "ENABLE_WIRELESS_PLAYBACK_TARGET": "ON",
            "ENABLE_WIRELESS_PLAYBACK_TARGET_AVAILABILITY_API": "ON",
            "ENABLE_COMPRESSION_STREAM": "OFF",
            "ENABLE_APPLE_PAY": "OFF",
            "ENABLE_APPLE_PAY_COUPON_CODE": "OFF",
            "ENABLE_APPLE_PAY_SESSION_V3": "OFF",
            "USE_ANGLE_EGL": "OFF",
            "ENABLE_JIT": "ON",
            "ENABLE_C_LOOP": "OFF",
            "ENABLE_DFG_JIT": "ON",
            "ENABLE_FTL_JIT": "OFF",
            "USE_SYSTEM_MALLOC": "ON",
            "ENABLE_MEDIA_SOURCE": "OFF",
            "ENABLE_MEDIA_SOURCE_IN_WORKERS": "OFF",
            "ENABLE_ENCRYPTED_MEDIA": "OFF",
            "ENABLE_LEGACY_ENCRYPTED_MEDIA": "OFF",
            "ENABLE_WEB_AUTHN": "OFF",
            "ENABLE_WRITING_TOOLS": "OFF",
            "ENABLE_PAYMENT_REQUEST": "OFF",
            "ENABLE_IMAGE_DIFF": "OFF",
            "BROWSERENGINECORE_LIBRARY": "BROWSERENGINECORE_LIBRARY-NOTFOUND",
            "BROWSERENGINEKIT_LIBRARY": "BROWSERENGINEKIT_LIBRARY-NOTFOUND",
            "UNIFORMTYPEIDENTIFIERS_LIBRARY": "UNIFORMTYPEIDENTIFIERS_LIBRARY-NOTFOUND",
            "CMAKE_CXX_FLAGS": cxx_flags,
            "CMAKE_C_FLAGS": c_flags,
            "CMAKE_OBJCXX_FLAGS": f"{cxx_flags} -DWEBKIT_IOS6_OBJC_EXTRAS",
            "CMAKE_OBJC_FLAGS": f"{c_flags} -DWEBKIT_IOS6_OBJC_EXTRAS",
            "CMAKE_SHARED_LINKER_FLAGS": (f"-B{linker} -flto=thin -Wl,-compatibility_version,1.0.0 "
                                          f"-Wl,-current_version,1.0.0 {link_folders} {link_libraries}"),
            "CMAKE_EXE_LINKER_FLAGS": (f"-B{linker} {self._library('libpsl', 'psl')} "
                                       "-Wl,-rpath,@executable_path/Frameworks"),
            "CMAKE_MODULE_LINKER_FLAGS": f"-B{linker} {self._library('libpsl', 'psl')}",
        })
        if self.options.prefixed:
            variables.update({"ENABLE_MEDIA_STREAM": "OFF", "ENABLE_NOTIFICATIONS": "OFF", "ENABLE_WEBGL": "OFF"})
        tc.generate()

        deps = CMakeDeps(self)
        for dependency in self.dependencies.host.values():
            if dependency.ref.name not in self._cmake_packages:
                deps.set_property(dependency.ref.name, "cmake_find_mode", "none")
        deps.generate()

        environment = Environment()
        environment.define("CCACHE_BASEDIR", root)
        environment.vars(self, scope="build").save_script("ccache_basedir")

    def _tool(self, name):
        return XCRun(self).find(name)

    def _python(self, script, *arguments):
        quoted = " ".join(f'"{argument}"' for argument in arguments)
        self.run(f'"{sys.executable}" "{os.path.join(self.recipe_folder, script)}" {quoted}')

    def _cmake_project(self, source, folder, **definitions):
        toolchain = os.path.join(self.generators_folder, "conan_toolchain.cmake")
        values = " ".join(f'-D{name}="{value}"' for name, value in definitions.items())
        self.run(f'cmake -S "{source}" -B "{folder}" -G Ninja -DCMAKE_BUILD_TYPE=Release '
                 f'-DCMAKE_TOOLCHAIN_FILE="{toolchain}" -DIOS6_SDK="{self._sdk}" '
                 f'-DIOS6_DEPLOYMENT_TARGET="{self.settings.os.version}" {values}')
        self.run(f'cmake --build "{folder}"')

    def _output(self, command):
        output = StringIO()
        self.run(command, stdout=output)
        return output.getvalue()

    def _dylib_references(self, binary):
        listing = self._output(f'"{self._tool("otool")}" -L "{binary}"')
        return [match.group(1) for match in re.finditer(r"^\t(\S+) \(compatibility version", listing, re.M)][1:]

    def _compatibility_version(self, binary):
        commands = self._output(f'"{self._tool("otool")}" -l "{binary}"').split("Load command")
        identity = next((block for block in commands if "cmd LC_ID_DYLIB" in block), "")
        match = re.search(r"compatibility version (\S+)", identity)
        return match.group(1) if match else None

    def _check_exports(self):
        binary = os.path.join(self.build_folder, "WebKitLegacy.framework", "WebKitLegacy")
        with open(self._exports) as listing:
            listed = {line.strip() for line in listing if line.strip() and not line.lstrip().startswith("#")}
        exported = set(self._output(f'"{self._tool("nm")}" -gUj "{binary}"').split())
        missing, unlisted = sorted(listed - exported), sorted(exported - listed)
        if missing or unlisted:
            raise ConanException(f"WebKitLegacy was not linked with {self._exports}: "
                                 f"{len(missing)} listed symbols not exported (first: {missing[:3]}), "
                                 f"{len(unlisted)} exported symbols not listed (first: {unlisted[:3]})")

    def _store_binary_plists(self, root):
        for folder, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".plist"):
                    continue
                path = os.path.join(folder, name)
                with open(path, "rb") as source:
                    content = plistlib.load(source)
                with open(path, "wb") as target:
                    plistlib.dump(content, target, fmt=plistlib.FMT_BINARY)

    def _check_no_encryption_info(self, root):
        otool = self._tool("otool")
        stamped = []
        for folder, _, names in os.walk(root):
            for name in names:
                path = os.path.join(folder, name)
                if os.path.islink(path):
                    continue
                with open(path, "rb") as candidate:
                    if candidate.read(4) not in (b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                        continue
                if "LC_ENCRYPTION_INFO" in self._output(f'"{otool}" -l "{path}"'):
                    stamped.append(os.path.relpath(path, root))
        if stamped:
            raise ConanException("linked by a linker that stamps LC_ENCRYPTION_INFO, which iOS 6 refuses "
                                 f"in a library it loads: {', '.join(stamped)}")

    def _lay_out_frameworks(self, stage):
        engine = os.path.join(stage, self._engine_location)
        installed = {}
        for built, (name, system_path) in self._system_frameworks.items():
            destination = os.path.join(engine, f"{name}.framework", name)
            mkdir(self, os.path.dirname(destination))
            shutil.copy2(os.path.join(self.build_folder, f"{built}.framework", built), destination)
            installed[destination] = system_path

        webcore = os.path.join(self.build_folder, "WebCore.framework")
        staged_webcore = os.path.join(engine, "WebCore.framework")
        for entry in sorted(os.listdir(webcore)):
            if entry in self._webcore_left_out:
                continue
            source = os.path.join(webcore, entry)
            if entry == "en.lproj":
                copy(self, "*.js", source, os.path.join(staged_webcore, entry))
            elif os.path.isdir(source):
                shutil.copytree(source, os.path.join(staged_webcore, entry), symlinks=True)
            else:
                shutil.copy2(source, staged_webcore)
        controls = os.path.join(staged_webcore, "modern-media-controls", "images")
        if os.path.isdir(os.path.join(controls, "iOS")):
            for pattern in ("*.svg", "*.png"):
                copy(self, pattern, os.path.join(controls, "iOS"), controls)

        runtime = self._cpp_info("libcxx").libdirs[0]
        for built, name in self._runtime.items():
            destination = os.path.join(stage, "usr", "lib", name)
            shutil.copy2(os.path.join(runtime, built), destination)
            installed[destination] = f"/usr/lib/{name}"

        by_basename = {os.path.basename(path).replace("librev-", "lib"): path for path in installed.values()}
        install_name_tool = self._tool("install_name_tool")
        for binary, identity in installed.items():
            self.run(f'"{install_name_tool}" -id "{identity}" "{binary}"')
            for reference in self._dylib_references(binary):
                target = by_basename.get(os.path.basename(reference))
                if target and target != reference:
                    self.run(f'"{install_name_tool}" -change "{reference}" "{target}" "{binary}"')
            unresolved = [ref for ref in self._dylib_references(binary) if ref.startswith("@rpath/")]
            if unresolved:
                raise ConanException(f"{binary} still depends on {', '.join(unresolved)}")

        strip = self._tool("strip")
        for binary in installed:
            if not binary.endswith(".dylib"):
                if self._compatibility_version(binary) != "1.0.0":
                    raise ConanException(f"{binary} does not declare compatibility version 1.0.0, "
                                         "which the system's clients of this framework recorded")
                self.run(f'"{strip}" -S -x "{binary}"')
            self.run(f'ldid -S "{binary}"')

    def _build_platform(self, stage):
        folder = os.path.join(self.build_folder, "platform")
        self._cmake_project(os.path.join(self.recipe_folder, "platform"), folder)
        self.run(f'cmake --install "{folder}" --prefix "{stage}"')
        strip = self._tool("strip")
        for binary in ("Library/MobileSubstrate/DynamicLibraries/RevSafari.dylib",
                       "usr/lib/rev-safari-compat.dylib", "usr/lib/rev-TLS.dylib",
                       "Library/PreferenceBundles/RevPrefs.bundle/RevPrefs"):
            path = os.path.join(stage, binary)
            self.run(f'"{strip}" -x "{path}"')
            self.run(f'ldid -S "{path}"')

    def _build_standalone_app(self):
        name = "RevWebViewHost"
        root = self.recipe_folder
        app = self._application
        frameworks = os.path.join(app, "Frameworks")
        rmdir(self, app)
        mkdir(self, frameworks)

        linker = os.path.join(self.dependencies.build["ld64"].package_folder, "bin")
        sources = " ".join(f'"{os.path.join(root, "app", source)}"'
                           for source in ("rev-webview-host.m", "ModernTLSURLProtocol.m", "WebKitUIKitDelegate.m"))
        system_frameworks = " ".join(f"-framework {framework}" for framework in
                                     ("UIKit", "Foundation", "QuartzCore", "CoreGraphics", "ImageIO", "MobileCoreServices"))
        self.run(f'"{XCRun(self).cc}" -target armv7-apple-ios{self.settings.os.version} -isysroot "{self._sdk}" '
                 f'-fno-objc-arc -O0 -g -B"{linker}" '
                 f'-include "{os.path.join(root, "compat", "stubs", "ios6_class_prefix.h")}" '
                 f'-I"{os.path.join(self.build_folder, "WebKitLegacy", "Headers")}" '
                 f'-I"{os.path.join(self.build_folder, "WebCore.framework", "PrivateHeaders")}" '
                 f'-I"{os.path.join(self.build_folder, "WTF", "Headers")}" -F"{self.build_folder}" '
                 f'{system_frameworks} -framework WebKitLegacy '
                 f'-Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip {sources} '
                 f'-I"{self._include_dir("openssl")}" "{self._library("openssl", "ssl")}" '
                 f'"{self._library("openssl", "crypto")}" -lz '
                 f'-o "{os.path.join(app, name)}"')

        bundled = {}
        for framework in self._system_frameworks:
            destination = os.path.join(frameworks, f"{framework}.framework", framework)
            shutil.copytree(os.path.join(self.build_folder, f"{framework}.framework"),
                            os.path.dirname(destination), symlinks=True)
            bundled[destination] = f"@executable_path/Frameworks/{framework}.framework/{framework}"
        runtime = self._cpp_info("libcxx").libdirs[0]
        for built in self._runtime:
            library = built.replace(".1.0.", ".1.")
            destination = os.path.join(frameworks, library)
            shutil.copy2(os.path.join(runtime, built), destination)
            bundled[destination] = f"@executable_path/Frameworks/{library}"

        by_basename = {os.path.basename(identity): identity for identity in bundled.values()}
        install_name_tool = self._tool("install_name_tool")
        for binary in list(bundled) + [os.path.join(app, name)]:
            if binary in bundled:
                self.run(f'"{install_name_tool}" -id "{bundled[binary]}" "{binary}"')
                if not binary.endswith(".dylib") and self._compatibility_version(binary) != "1.0.0":
                    raise ConanException(f"{binary} does not declare compatibility version 1.0.0")
            for reference in self._dylib_references(binary):
                target = by_basename.get(os.path.basename(reference))
                if target and reference != target:
                    self.run(f'"{install_name_tool}" -change "{reference}" "{target}" "{binary}"')
            unresolved = [reference for reference in self._dylib_references(binary) if reference.startswith("@rpath/")]
            if unresolved:
                raise ConanException(f"{binary} still depends on {', '.join(unresolved)}")

        shutil.copy2(os.path.join(root, "app", "cacert.pem"), app)
        with open(os.path.join(app, "Info.plist"), "wb") as info:
            plistlib.dump({
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundleIdentifier": "space.kern0x1b.revwebviewhost",
                "CFBundleExecutable": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": self.version,
                "CFBundleShortVersionString": self.version,
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
                "UIDeviceFamily": [1],
                "MinimumOSVersion": str(self.settings.os.version),
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "CFBundleURLTypes": [{"CFBundleURLName": "space.kern0x1b.revwebviewhost",
                                      "CFBundleURLSchemes": ["revwebviewhost"]}],
            }, info)

        for binary in bundled:
            self.run(f'ldid -S "{binary}"')
        self.run(f'ldid -S"{os.path.join(root, "app", "entitlements.xml")}" "{os.path.join(app, name)}"')

    def build(self):
        self._python("scripts/carry-check.py")
        self._cmake_project(os.path.join(self.recipe_folder, "compat"), os.path.dirname(self._compat_library),
                            WEBKIT_IOS6_LIBCXX_DIR=self._dependency("libcxx"),
                            LIBPSL_INCLUDE_DIR=self._include_dir("libpsl"))
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
        self._check_exports()
        self._python("tools/compat-audit.py", "--compat", self._compat_library,
                     "--engine-build", self.build_folder, "--icu", self._dependency("icu"))
        if self.options.prefixed:
            self._build_standalone_app()
            return
        self._python("tools/symbol-check.py", "--build", self.build_folder)
        stage = self._stage
        rmdir(self, stage)
        self._build_platform(stage)
        self._lay_out_frameworks(stage)
        self._store_binary_plists(stage)
        self._check_no_encryption_info(stage)
        dyld_cache = self.conf.get("user.ios6:dyld_shared_cache", check_type=str)
        if dyld_cache:
            self._python("tools/ios6-imports-check.py", "--cache", dyld_cache,
                         "--dist", os.path.join(stage, self._engine_location))

    def package(self):
        copy(self, "LICENSE", self.recipe_folder, os.path.join(self.package_folder, "licenses"))
        copy(self, "THIRD-PARTY.md", self.recipe_folder, os.path.join(self.package_folder, "licenses"))
        if self.options.prefixed:
            shutil.copytree(self._application, os.path.join(self.package_folder, os.path.basename(self._application)),
                            symlinks=True)
            return
        shutil.copytree(self._stage, os.path.join(self.package_folder, "root"), symlinks=True)
        packaging = os.path.join(self.recipe_folder, "packaging")
        self.python_requires["ios6-base"].module.DebianPackage(
            self, os.path.join(packaging, "control"), self._stage, os.path.join(packaging, "DEBIAN")
        ).write(os.path.join(self.package_folder, "deb"))
