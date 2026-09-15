import os
import plistlib
import re
import shutil
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

    _cmake_packages = ("icu", "libcxx", "libxml2", "libxslt")
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

    def layout(self):
        variant = "prefixed" if self.options.prefixed else "system"
        self.folders.source = "webkit-254"
        self.folders.build = os.path.join("build", "engine", f"{self.settings.arch}-{variant}")
        self.folders.generators = os.path.join(self.folders.build, "conan")

    def _dependency(self, name):
        return self.dependencies[name].package_folder

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
        return os.path.join(self.build_folder, "rev-sys-fw")

    def generate(self):
        super().generate()
        root = self.recipe_folder
        sdk = self.conf.get("tools.apple:sdk_path", check_type=str)
        if not sdk:
            raise ConanException("tools.apple:sdk_path is not set; install with the port's profile")
        libcxx, xslt, ssl, webp, brotli, woff2, psl = (
            self._dependency(n) for n in ("libcxx", "libxslt", "openssl", "libwebp", "brotli", "woff2", "libpsl"))
        linker = os.path.join(self.dependencies.build["ld64"].package_folder, "bin")
        stubs = os.path.join(root, "compat", "stubs")
        prefix_header = "ios6_class_prefix.h" if self.options.prefixed else "ios6_class_names.h"
        target = f"armv7-apple-ios{self.settings.os.version}"
        tuning = " ".join(self.conf.get("tools.build:cxxflags", default=[], check_type=list))
        defines = "-DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
        common = f"-flto=thin -mllvm -hot-cold-split=false -target {target} {tuning} -isysroot {sdk}"
        cxx_flags = (f"{common} -nostdinc++ -isystem {libcxx}/include/c++/v1 "
                     f"-isystem {stubs} -include {stubs}/ios6_dispatch_compat.h -include {stubs}/{prefix_header} "
                     f"-D_LIBCPP_DISABLE_AVAILABILITY {defines}")
        c_flags = f"{common} -isystem {stubs} -include {stubs}/{prefix_header} {defines}"

        if self.options.prefixed:
            os.makedirs(self.build_folder, exist_ok=True)
            self.run(f'python3 "{root}/tools/prefix-exports.py" "{stubs}/ios6_class_prefix.h" '
                     f'"{self.source_folder}/Source/WebKitLegacy/WebKitLegacy-iOS.exp" "{self._exports}"')

        self.conf.define("tools.cmake.cmaketoolchain:user_toolchain",
                         [os.path.join(root, "scripts", "ios6-armv7-trunk.cmake")])
        tc = CMakeToolchain(self)
        tc.blocks.remove("apple_system")
        variables = tc.cache_variables
        launcher = shutil.which("ccache")
        if launcher:
            for language in ("C", "CXX", "OBJC", "OBJCXX"):
                variables[f"CMAKE_{language}_COMPILER_LAUNCHER"] = launcher
        variables.update({
            "IOS6_SDK": sdk,
            "CMAKE_OSX_SYSROOT": sdk,
            "CMAKE_OSX_DEPLOYMENT_TARGET": str(self.settings.os.version),
            "CMAKE_BUILD_TYPE": "Release",
            "CMAKE_PROJECT_WebKit_INCLUDE": os.path.join(root, "scripts", "ios6-conan-targets.cmake"),
            "PORT": "Cocoa",
            "DEVELOPER_MODE": "OFF",
            "PYTHON_EXECUTABLE": shutil.which("python3"),
            "SWIFT_REQUIRED": "OFF",
            "WEBKIT_IOS6_CRYPTO_LIB": f"{ssl}/lib/libcrypto.a",
            "WEBKIT_IOS6_COMPAT_LIB": self._compat_library,
            "WEBKIT_IOS6_EXPORTS": self._exports,
            "WEBKIT_IOS6_LIBCXX_DIR": libcxx,
            "WEBKIT_IOS6_SIZE_OPTIMIZED": "ON",
            "WEBKIT_NO_AVAILABILITY_OVERLAY": "ON",
            "CMAKE_DISABLE_PRECOMPILE_HEADERS": "OFF",
            "USE_WEBP": "ON",
            "WebP_INCLUDE_DIR": f"{webp}/include",
            "WebP_LIBRARY": f"{webp}/lib/libwebp.a",
            "WebP_DEMUX_LIBRARY": f"{webp}/lib/libwebpdemux.a",
            "USE_WOFF2": "ON",
            "WOFF2_INCLUDE_DIR": f"{woff2}/include",
            "WOFF2_DEC_INCLUDE_DIR": f"{woff2}/include",
            "WOFF2_LIBRARY": f"{woff2}/lib/libwoff2common.a",
            "WOFF2_DEC_LIBRARY": f"{woff2}/lib/libwoff2dec.a",
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
                                          f"-Wl,-current_version,1.0.0 -L{xslt}/lib -L{woff2}/lib -L{brotli}/lib "
                                          f"-lbrotlidec -lbrotlicommon -L{psl}/lib -lpsl"),
            "CMAKE_EXE_LINKER_FLAGS": f"-B{linker} -L{psl}/lib -lpsl -Wl,-rpath,@executable_path/Frameworks",
            "CMAKE_MODULE_LINKER_FLAGS": f"-B{linker} -L{psl}/lib -lpsl",
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
        path = shutil.which(name)
        if not path:
            raise ConanException(f"{name} is not on PATH; the package cannot be finished without it")
        return path

    def _python(self, script, *arguments):
        quoted = " ".join(f'"{argument}"' for argument in arguments)
        self.run(f'python3 "{os.path.join(self.recipe_folder, script)}" {quoted}')

    def _build_compat(self):
        folder = os.path.dirname(self._compat_library)
        psl = self._dependency("libpsl")
        launcher = shutil.which("ccache")
        launchers = " ".join(f"-DCMAKE_{language}_COMPILER_LAUNCHER={launcher}"
                             for language in ("C", "CXX", "OBJC")) if launcher else ""
        self.run(f'cmake -S "{self.recipe_folder}/compat" -B "{folder}" -G Ninja {launchers} '
                 f'-DCMAKE_TOOLCHAIN_FILE="{self.recipe_folder}/scripts/ios6-armv7-trunk.cmake" '
                 f'-DIOS6_SDK="{self.conf.get("tools.apple:sdk_path", check_type=str)}" '
                 f'-DWEBKIT_IOS6_LIBCXX_DIR="{self._dependency("libcxx")}" '
                 f'-DLIBPSL_INCLUDE_DIR="{psl}/include"')
        self.run(f'cmake --build "{folder}"')

    def _output(self, command):
        output = StringIO()
        self.run(command, stdout=output)
        return output.getvalue()

    def _dylib_references(self, binary):
        listing = self._output(f'otool -L "{binary}"')
        return [match.group(1) for match in re.finditer(r"^\t(\S+) \(compatibility version", listing, re.M)][1:]

    def _compatibility_version(self, binary):
        commands = self._output(f'otool -l "{binary}"').split("Load command")
        identity = next((block for block in commands if "cmd LC_ID_DYLIB" in block), "")
        match = re.search(r"compatibility version (\S+)", identity)
        return match.group(1) if match else None

    def _check_exports(self):
        binary = os.path.join(self.build_folder, "WebKitLegacy.framework", "WebKitLegacy")
        with open(self._exports) as listing:
            listed = {line.strip() for line in listing if line.strip() and not line.lstrip().startswith("#")}
        exported = set(self._output(f'nm -gUj "{binary}"').split())
        missing, unlisted = sorted(listed - exported), sorted(exported - listed)
        if missing or unlisted:
            raise ConanException(f"WebKitLegacy was not linked with {self._exports}: "
                                 f"{len(missing)} listed symbols not exported (first: {missing[:3]}), "
                                 f"{len(unlisted)} exported symbols not listed (first: {unlisted[:3]})")

    def _lay_out_frameworks(self):
        stage = self._stage
        rmdir(self, stage)
        installed = {}
        for built, (name, system_path) in self._system_frameworks.items():
            destination = os.path.join(stage, f"{name}.framework", name)
            mkdir(self, os.path.dirname(destination))
            shutil.copy2(os.path.join(self.build_folder, f"{built}.framework", built), destination)
            installed[destination] = system_path

        webcore = os.path.join(self.build_folder, "WebCore.framework")
        staged_webcore = os.path.join(stage, "WebCore.framework")
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

        runtime = os.path.join(self._dependency("libcxx"), "lib")
        for built, name in self._runtime.items():
            destination = os.path.join(stage, name)
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

        strip, ldid = self._tool("strip"), self._tool("ldid")
        for binary in installed:
            if not binary.endswith(".dylib"):
                if self._compatibility_version(binary) != "1.0.0":
                    raise ConanException(f"{binary} does not declare compatibility version 1.0.0, "
                                         "which the system's clients of this framework recorded")
                self.run(f'"{strip}" -S -x "{binary}"')
            self.run(f'"{ldid}" -S "{binary}"')
        return stage

    def _package(self, stage):
        packages = os.path.join(self.build_folder, "packages")
        rmdir(self, packages)
        self.run(f'make -C "{os.path.join(self.recipe_folder, "packaging")}" package FINALPACKAGE=1 '
                 f'PACKAGE_VERSION={self.version} ENGINE_STAGE="{stage}" THEOS_PACKAGE_DIR="{packages}"')

    def _build_standalone_app(self):
        name = "RevWebViewHost"
        root = self.recipe_folder
        app = os.path.join(self.build_folder, f"{name}.app")
        frameworks = os.path.join(app, "Frameworks")
        rmdir(self, app)
        mkdir(self, frameworks)

        sdk = self.conf.get("tools.apple:sdk_path", check_type=str)
        ssl = self._dependency("openssl")
        linker = os.path.join(self.dependencies.build["ld64"].package_folder, "bin")
        sources = " ".join(f'"{os.path.join(root, "app", source)}"'
                           for source in ("rev-webview-host.m", "ModernTLSURLProtocol.m", "WebKitUIKitDelegate.m"))
        system_frameworks = " ".join(f"-framework {framework}" for framework in
                                     ("UIKit", "Foundation", "QuartzCore", "CoreGraphics", "ImageIO", "MobileCoreServices"))
        self.run(f'"{XCRun(self).cc}" -target armv7-apple-ios{self.settings.os.version} -isysroot "{sdk}" '
                 f'-fno-objc-arc -O0 -g -B"{linker}" '
                 f'-include "{os.path.join(root, "compat", "stubs", "ios6_class_prefix.h")}" '
                 f'-I"{os.path.join(self.build_folder, "WebKitLegacy", "Headers")}" '
                 f'-I"{os.path.join(self.build_folder, "WebCore.framework", "PrivateHeaders")}" '
                 f'-I"{os.path.join(self.build_folder, "WTF", "Headers")}" -F"{self.build_folder}" '
                 f'{system_frameworks} -framework WebKitLegacy '
                 f'-Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip {sources} '
                 f'-I"{ssl}/include" "{ssl}/lib/libssl.a" "{ssl}/lib/libcrypto.a" -lz '
                 f'-o "{os.path.join(app, name)}"')

        bundled = {}
        for framework in self._system_frameworks:
            destination = os.path.join(frameworks, f"{framework}.framework", framework)
            shutil.copytree(os.path.join(self.build_folder, f"{framework}.framework"),
                            os.path.dirname(destination), symlinks=True)
            bundled[destination] = f"@executable_path/Frameworks/{framework}.framework/{framework}"
        runtime = os.path.join(self._dependency("libcxx"), "lib")
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

        ldid = self._tool("ldid")
        for binary in bundled:
            self.run(f'"{ldid}" -S "{binary}"')
        self.run(f'"{ldid}" -S"{os.path.join(root, "app", "entitlements.xml")}" "{os.path.join(app, name)}"')
        return app

    def build(self):
        self._python("scripts/carry-check.py")
        self._build_compat()
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
        stage = self._lay_out_frameworks()
        dyld_cache = self.conf.get("user.ios6:dyld_shared_cache", check_type=str)
        if dyld_cache:
            self._python("tools/ios6-imports-check.py", "--cache", dyld_cache, "--dist", stage)
        self._package(stage)
