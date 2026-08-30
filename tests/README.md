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
