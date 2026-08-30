#!/usr/bin/env bash
# The Makefile generator does not order JavaScriptCore's object-library
# sub-targets against the framework link, and WebCore depends on the code-signed
# framework rather than the binary, so the targets are driven explicitly.
set -e
B=$P/build-cocoa
J=${JOBS:-8}
cd "$B"

# CMake does not track the force-included compatibility header as a PCH
# dependency, so a change to it leaves every .pch stale.
STUB=$P/compat/stubs/ios6_dispatch_compat.h
# `-nt` cannot tell "same second" from "older", and edits often land in the same
# second as the build starts, so the PCH sources are always marked dirty.
find "$B" -name "cmake_pch.hxx" -exec touch {} + 2>/dev/null

# JavaScriptCore owns the precompiled header that its own JIT sub-target needs,
# so it gets a first pass that is allowed to fail just to produce the PCH.
# A target prefixed with '?' may fail without stopping the build.
for target in bmalloc WTF ?JavaScriptCore pch:JavaScriptCore JavaScriptCoreJIT JavaScriptCore JavaScriptCore_CodeSign \
              ?PAL PAL WebCoreBindings WebCoreGeneratedSources WebCore_CopyPrivateHeaders ?WebCore pch:WebCore WebCoreJSBindings \
              WebCoreDOMAndRendering WebCoreStyle WebCoreInspector WebCoreAVFoundation \
              WebCore WebCore_CodeSign WebKitLegacy WebKitLegacy_CodeSign; do
    case "$target" in
    pch:*)
        parent="${target#pch:}"
        echo "=== precompiled header for $parent"
        for lang in "" "objcxx."; do
            pch="Source/$parent/CMakeFiles/$parent.dir/cmake_pch.${lang}hxx.pch"
            make -f "Source/$parent/CMakeFiles/$parent.dir/build.make" "$pch" > /dev/null 2>&1 \
                || make -f "Source/$parent/CMakeFiles/$parent.dir/build.make" "$pch" 2>&1 | tail -1
        done
        echo "    ok"
        continue
        ;;
    esac
    optional=""
    case "$target" in ?\?*) ;; esac
    if [ "${target#\?}" != "$target" ]; then optional=1; target="${target#\?}"; fi
    echo "=== $target"
    # A first pass can fail on generated sources that another rule is still
    # producing; a second pass with the same target then succeeds.
    if ! make -j"$J" "$target" > /tmp/wk_$target.log 2>&1; then
        make -j"$J" "$target" > /tmp/wk_$target.log 2>&1 || {
            [ -n "$optional" ] && { echo "(first pass, continuing)"; continue; }
            echo "FAILED: $target (see /tmp/wk_$target.log)"
            grep "error:" /tmp/wk_$target.log | head -5
            exit 1
        }
    fi
    tail -1 /tmp/wk_$target.log
done
