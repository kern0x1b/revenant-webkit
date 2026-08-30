# Building WebKit 603 for armv7

The source is a sparse checkout of the upstream tag `Safari-603.1.30`, `Source/`
only — the full tree with tests and history is several gigabytes and none of it
is needed. It is not committed here; `fetch-source.sh` reproduces it.

## What the toolchain has to be told

**The SDK.** iPhoneOS 10.3, because iOS 11 dropped 32-bit and 10.3 is the newest
SDK that still carries armv7 slices. It matches this WebKit's own era.

**C++ headers.** Modern clang looks for them inside its own toolchain, and this
SDK carries none at all. Modern libc++ headers cannot stand in: they reference
symbols that iOS 6's libc++ does not export. So the build uses libc++ 3.9
headers — the compiler era of the SDK — via `-nostdinc++ -isystem`.

**Python.** WebKit of 2017 generates code with Python 2 scripts, and `print` as
a statement does not parse under Python 3. Five scripts under
`Source/JavaScriptCore` need converting; `patch-python2.sh` does it with
lib2to3. They are: generate-bytecode-files, ud_opcode.py,
CodeGeneratorReplayInputs.py, and two under inspector/scripts.

**gtest.** The bundled test framework includes `crt_externs.h`, a macOS header
absent from any iOS SDK. Building the `JavaScriptCore` target directly steps
around it; `ENABLE_API_TESTS=OFF` alone does not, once a build directory has
been configured with it on.

## Reproducing

```bash
./fetch-source.sh          # sparse checkout of Safari-603.1.30
./patch-python2.sh         # make the generators run under python3
./configure-jsc.sh         # cmake, armv7, iOS 6 deployment target
cd build-jsc && make -j8 JavaScriptCore
```

## Where it stands

`libWTF.a` builds for armv7. JavaScriptCore is the current step. Nothing has run
on a device yet — that is the point of milestone 1, and until a script executes
on the 4S none of this counts as working.
