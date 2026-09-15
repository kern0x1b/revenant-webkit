import os
import shutil

from conan import ConanFile
from conan.errors import ConanException
from conan.tools.cmake import CMake, CMakeToolchain
from conan.tools.env import Environment


class RevenantWebKit(ConanFile):
    name = "revenant-webkit"
    description = "WebKit for armv7 / iOS 6"
    package_type = "application"
    options = {"prefixed": [True, False]}
    default_options = {"prefixed": False}
    generators = "VirtualBuildEnv"

    python_requires = "ios6-base/1.0@ios6/stable"
    python_requires_extend = "ios6-base.Ios6Port"

    _libraries = ("openssl", "brotli", "libwebp", "libxslt", "libpsl", "icu", "woff2", "libcxx")

    def requirements(self):
        self.requires("openssl/3.0.15@ios6/stable")
        self.requires("brotli/1.1.0@ios6/stable")
        self.requires("libwebp/1.4.0@ios6/stable")
        self.requires("libxslt/1.1.43@ios6/stable")
        self.requires("libpsl/0.23.3@ios6/stable")
        self.requires("icu/74.2@ios6/stable")
        self.requires("woff2/1.0.2@ios6/stable")
        self.requires("libcxx/21.1.0@ios6/stable")
        self.requires("wasm3/cci.20260905@ios6/stable")

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

    def generate(self):
        super().generate()
        root = self.recipe_folder
        sdk = self.conf.get("tools.apple:sdk_path", check_type=str)
        if not sdk:
            raise ConanException("tools.apple:sdk_path is not set; install with the port's profile")
        libcxx, icu, xslt, ssl, webp, brotli, woff2, psl = (
            self._dependency(n) for n in ("libcxx", "icu", "libxslt", "openssl", "libwebp", "brotli", "woff2", "libpsl"))
        linker = os.path.join(self.dependencies.build["ld64"].package_folder, "bin")
        stubs = os.path.join(root, "compat", "stubs")
        prefix_header = "ios6_class_prefix.h" if self.options.prefixed else "ios6_class_names.h"
        target = f"armv7-apple-ios{self.settings.os.version}"
        tuning = " ".join(self.conf.get("tools.build:cxxflags", default=[], check_type=list))
        defines = "-DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
        common = f"-flto=thin -mllvm -hot-cold-split=false -target {target} {tuning} -isysroot {sdk}"
        cxx_flags = (f"{common} -nostdinc++ -isystem {libcxx}/include/c++/v1 -isystem {xslt}/include "
                     f"-isystem {stubs} -include {stubs}/ios6_dispatch_compat.h -include {stubs}/{prefix_header} "
                     f"-D_LIBCPP_DISABLE_AVAILABILITY {defines}")
        c_flags = f"{common} -isystem {xslt}/include -isystem {stubs} -include {stubs}/{prefix_header} {defines}"

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
            "ICU_UC_LIBRARY": f"{icu}/lib/libicuuc.a",
            "ICU_I18N_LIBRARY": f"{icu}/lib/libicui18n.a",
            "ICU_DATA_LIBRARY": f"{icu}/lib/libicudata.a",
            "ICU_INCLUDE_DIR": f"{icu}/include",
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

        environment = Environment()
        environment.define("CCACHE_BASEDIR", root)
        environment.vars(self, scope="build").save_script("ccache_basedir")

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

    def build(self):
        self._build_compat()
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
