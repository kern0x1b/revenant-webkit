# Tests

Run before every deploy: `tests/run-tests.sh`

    tests/run-tests.sh host      ICU data checks on this Mac, a few seconds
    tests/run-tests.sh device    JavaScript batteries under jsc on the iPhone
    tests/run-tests.sh all       both (default)

## host

`icu-sanity` opens the resource bundles, the time zone enumeration and every
character encoding the engine hands to ICU, against the trimmed data package in
`third_party/icu/source/data/in/icudt74l.dat`.

The encoding list is not maintained by hand. `gen-required-encodings.sh` reads
it out of `TextCodecICU.cpp`, so it tracks the engine: everything else is
decoded by WebKit itself (`TextCodecCJK`, `TextCodecSingleByte`,
`TextCodecLatin1`, `TextCodecUTF8`) and needs nothing from ICU. Re-run the
generator after updating WebKit.

`known-missing-encodings.txt` lists encodings ICU 74 genuinely does not ship, so
a real gap stays visible without failing the build.

`icu-locales` formats a relative time and a grouped number in 37 languages and
fails if any of them comes back in English, which is what a locale trimmed too
far looks like.

This half exists because a damaged ICU package still loads and then fails far
away from the cause: the last one surfaced on device as a SIGTRAP inside
`CommonIdentifiers::appendExternalName`, and took a full deploy cycle to trace.
The same fault takes two seconds to find here.

## device

`tests/js/*.js` run under `jsc` on the phone with the freshly built engine.
The runner syncs `jsc` and any framework whose size differs, so the batteries
never run against a stale engine, and it pins the connection to the iPhone's
UDID through iproxy so a connected iPad cannot answer instead.

Requires `iproxy 2225:22 -u <iphone-udid> &`.

Each battery prints its own verdict line. A battery that produces no verdict is
a failure — it died partway through.

The batteries cover what the 32-bit JIT work touched: `correct.js` arithmetic,
strings, arrays and the modulo and double paths that the softfp ABI fix broke;
`poly.js` polymorphic inline caches; `coverage.js` Map/Set/iterator builtins;
`mapdfg.js` the Map and Set DFG intrinsics written by hand for 32-bit.

## In a browser, by hand

Three pages measure the engine under a feed, which is the shape of page this
device is asked to render and the shape that used to be measured against a live
site - where the content changes between runs and every comparison is therefore
worthless.

    tests/enginebench.html    four timings: building a feed, megamorphic property
                              access, allocation churn, forced relayout
    tests/membench.html       a long session's feed, built in batches, printing
                              posts and document height as it grows
    tests/scrollbench.html    scrolling: the gap distribution between animation
                              frames, not a mean

`scrollbench.html` has two knobs, because the regime is part of what is
measured: `?posts=1400` puts the collector in the band a content-bearing feed
puts it in, and `?heap=40` retains forty megabytes of live objects in the shape
a component tree has. Its own DOM is 2.2 MB of heap even at 1400 posts, so
without them the collector never leaves its cheap band and the emergency policy
under test never engages.

## jsc32: the 32-bit engine, without the phone

The most expensive thing this port carries is the part of JavaScriptCore that
upstream deleted: the 32-bit JSValue representation and the ARMv7 JIT. Neither
needs iOS to run, so neither needs the device to be tested.

    tests/jsc32/build-and-test.sh            build, then a smoke run
    tests/jsc32/build-and-test.sh stress     and a slice of JSTests/stress

A Debian container cross-compiles `jsc` for `armv7` at native speed - the
compiler runs on the host architecture and only the product is 32-bit - and the
binary is then run under `qemu-arm-static`. The engine under test is this port's
own tree, mounted read-only, so what runs is the same JSValue layout, the same
macro assembler and the same DFG that run on the phone.

It earned its place on the first build it completed: `DFGSpeculativeJIT32_64.cpp`
used `JSSet::offsetOfStorage()` without including `JSSet.h`, which the device
build never noticed because it bundles that file into a unified source that
happens to include the header. Compiled on its own, it does not build.

**Where this stands.** The build works, the binary is a real 32-bit ARM
executable, and it does not run yet. Under emulation it aborts during
`JSGlobalObject::init`, and the stack says exactly where:

    #1 WTFCrashWithInfo () at wtf/Assertions.h:1057
    #2 JSC::DisallowVMEntryImpl<JSC::VM>::~DisallowVMEntryImpl
         at runtime/DisallowVMEntry.h:56
    #3 std::_Optional_payload_base<...>::_M_destroy
    ...
    #6 JSC::setupAdaptiveWatchpoint (JSGlobalObject*, JSObject*, Identifier const&)
    #7 JSC::JSGlobalObject::init (JSC::VM&)

The failing line is `RELEASE_ASSERT(m_vm->disallowVMEntryCount)` in that
destructor: the count is already zero when the scope ends. The object lives
inside the `std::optional` a `PropertySlot` holds when it is constructed for a
`VMInquiry`, which is what `setupAdaptiveWatchpoint` does while wiring the array
iterator watchpoints.

What is known: it is not the JIT (`--useJIT=0` aborts identically), and it is
not 32-bit as such - the phone runs this same code every day. So it is something
about this configuration, and the next step is a build with assertions enabled,
which will name the imbalance rather than leave it to be inferred. Until then
this tier is a compiler, not a test runner, and the README says so rather than
implying coverage that does not exist.

Two real defects came out of the compiler alone:

- `DFGSpeculativeJIT32_64.cpp` used `JSSet::offsetOfStorage()` without including
  `JSSet.h`. The device build hides it inside a unified source.
- `Source/bmalloc/CMakeLists.txt` defined `PAS_BMALLOC=1` for every target,
  while `BPlatform.h` enables libpas only on 64-bit. A 32-bit CMake build
  compiled bmalloc with the two disagreeing. That one is not iOS 6 specific: any
  CMake port built for 32-bit hits it, and the GLib ports still build for
  32-bit ARM.
