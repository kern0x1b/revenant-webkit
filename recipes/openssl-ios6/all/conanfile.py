from conan import ConanFile
from conan.tools.files import copy, replace_in_file, chdir
from conan.tools.apple import XCRun
from conan.tools.scm import Git
import os


class OpenSSLIos6Conan(ConanFile):
    name = "openssl-ios6"
    description = "OpenSSL for armv7 / iOS 6, with the ARM assembly kept"
    license = "Apache-2.0"
    homepage = "https://www.openssl.org"
    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"

    # Xcode 27's linker asserts on a named atom in a __nl_symbol_ptr section
    # (setGotCoalescable, DynamicAtom.cpp). OpenSSL's ARM generator emits one
    # for OPENSSL_armcap_P in every module that dispatches on NEON, and one such
    # object in the archive kills the link whether or not anything references it.
    # A plain data word holds the same address without being a GOT atom.
    _armcap_old = (
        '\t$ret .= ".non_lazy_symbol_pointer\\n";\n'
        '\t$ret .= "$name:\\n";\n'
        '\t$ret .= ".indirect_symbol\\t_$name\\n";\n'
        '\t$ret .= ".long\\t0";'
    )
    _armcap_new = (
        '\t$ret .= ".data\\n";\n'
        '\t$ret .= ".align\\t2\\n";\n'
        '\t$ret .= "$name:\\n";\n'
        '\t$ret .= ".long\\t_$name\\n";\n'
        '\t$ret .= ".text";'
    )

    def source(self):
        source = self.conan_data["sources"][self.version]
        git = Git(self)
        git.fetch_commit(source["url"], source["commit"])
        # replace_in_file raises when the text is absent, which is what this
        # needs: silently skipping it builds the form the linker rejects, and
        # the failure then looks unrelated to OpenSSL.
        replace_in_file(self, os.path.join(self.source_folder, "crypto", "perlasm", "arm-xlate.pl"),
                        self._armcap_old, self._armcap_new)

    def build(self):
        sdk = self.conf.get("tools.apple:sdk_path")
        target = f"{self.settings.arch}-apple-ios{self.settings.os.version}"
        xcrun = XCRun(self)
        flags = f"-target {target} -isysroot {sdk} -O2 -DBROKEN_CLANG_ATOMICS"
        env = {
            "CC": xcrun.cc,
            "CFLAGS": flags,
            "LDFLAGS": f"-target {target} -isysroot {sdk}",
        }
        with chdir(self, self.source_folder):
            exports = " ".join(f'{k}="{v}"' for k, v in env.items())
            self.run(f"{exports} ./Configure ios-cross --prefix={self.package_folder}"
                     " no-shared no-tests no-ui-console no-engine no-async")
            self.run(f"make -j{os.cpu_count()} build_libs")

    def package(self):
        copy(self, "LICENSE.txt", self.source_folder, os.path.join(self.package_folder, "licenses"))
        copy(self, "*.a", self.source_folder, os.path.join(self.package_folder, "lib"), keep_path=False)
        copy(self, "*.h", os.path.join(self.source_folder, "include", "openssl"),
             os.path.join(self.package_folder, "include", "openssl"))

    def package_info(self):
        self.cpp_info.libs = ["ssl", "crypto"]
