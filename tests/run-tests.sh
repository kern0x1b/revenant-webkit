#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
what="${1:-all}"
failures=0

run_host_tests() {
    local deps="$root/build/host-tests"
    mkdir -p "$deps"
    if ! conan install "$root/tests/host" -pr:h default -pr:b default --build=missing \
            --lockfile="$root/conan.lock" --lockfile-partial --output-folder="$deps" \
            > "$deps/conan-install.log" 2>&1; then
        echo "host tests: conan install failed, see $deps/conan-install.log" >&2
        failures=$((failures + 1))
        return
    fi
    . "$deps/ios6-deps.env"
    local bin="${TMPDIR:-/tmp}/revenant-tests"
    mkdir -p "$bin"

    "$root/tests/host/gen-required-encodings.sh" > /dev/null

    for name in icu-sanity icu-locales; do
        clang++ -o "$bin/$name" "$root/tests/host/$name.cpp" \
            -I "$IOS6_HOST_ICU/include" \
            -L "$IOS6_HOST_ICU/lib" -licui18n -licuuc -licudata || { failures=$((failures + 1)); continue; }
    done

    echo "== icu-sanity =="
    "$bin/icu-sanity" "$root/tests/host/required-encodings.txt" \
        "$root/tests/host/known-missing-encodings.txt" | tail -6 || failures=$((failures + 1))
    echo "== icu-locales =="
    "$bin/icu-locales" | tail -2 || failures=$((failures + 1))
}

. "$root/tools/device.sh"

device_ready() {
    device_run 12 "echo ok" 2>/dev/null | grep -q ok
}

DEVICE_DIR=/tmp/jscrun

sync_engine() {
    local built="${ENGINE_BUILD:-$root/build-254-lto}"
    . "$root/scripts/deps.sh" > "$root/build/deps-install.log" 2>&1 \
        || { echo "device tests: conan install failed, see $root/build/deps-install.log" >&2; return 1; }
    [ -f "$built/jsc" ] || (cd "$built" && ninja jsc > /dev/null 2>&1)
    [ -f "$built/jsc" ] || { echo "cannot build jsc" >&2; return 1; }

    device_run 30 "mkdir -p $DEVICE_DIR/Frameworks" > /dev/null

    local remote_sizes
    remote_sizes=$(device_run 30 "ls -l $DEVICE_DIR/jsc $DEVICE_DIR/Frameworks/*.dylib $DEVICE_DIR/Frameworks/*.framework/* 2>/dev/null" | awk 'NF >= 9 { print $NF, $5 }')

    push_if_changed "$built/jsc" "$DEVICE_DIR/jsc" "$remote_sizes" || return 1
    local lib base
    for lib in libc++.1.0.dylib libc++abi.1.0.dylib; do
        base=$(echo "$lib" | sed "s/\.1\.0\./.1./")
        push_if_changed "$IOS6_HOST_LIBCXX/lib/$lib" \
            "$DEVICE_DIR/Frameworks/$base" "$remote_sizes" || return 1
    done

    local framework
    for framework in JavaScriptCore WebCore WebKitLegacy; do
        local binary="$built/$framework.framework/$framework"
        [ -f "$binary" ] || continue
        device_run 30 "mkdir -p $DEVICE_DIR/Frameworks/$framework.framework" > /dev/null
        push_if_changed "$binary" "$DEVICE_DIR/Frameworks/$framework.framework/$framework" "$remote_sizes" || return 1
    done
}

push_if_changed() {
    local local_path="$1" remote_path="$2" sizes="$3"
    local local_size remote_size
    local_size=$(stat -f '%z' "$local_path")
    remote_size=$(echo "$sizes" | awk -v p="$remote_path" '$1 == p { print $2 }')
    [ "$local_size" = "$remote_size" ] && return 0
    echo "  syncing $(basename "$remote_path") ($((local_size / 1024)) KB)" >&2
    device_copy "$local_path" "$remote_path" > /dev/null 2>&1
}

run_device_tests() {
    if ! device_ready; then
        echo "device tests: the phone is not reachable - check device.env (see device.env.example)" >&2
        failures=$((failures + 1))
        return
    fi

    sync_engine || { failures=$((failures + 1)); return; }

    local battery
    for battery in "$root"/tests/js/*.js; do
        device_copy "$battery" "$DEVICE_DIR/" > /dev/null 2>&1
    done

    local script name output status verdict
    for script in "$root"/tests/js/*.js; do
        name="$(basename "$script")"
        output=$(device_run 300 "cd $DEVICE_DIR && DYLD_FRAMEWORK_PATH=$DEVICE_DIR/Frameworks ./jsc $name 2>&1; echo EXIT=\$?")
        status="${output##*EXIT=}"
        output="$(echo "${output%EXIT=*}" | grep -v '^[[:space:]]*$')"
        verdict="$(echo "$output" | grep -iE 'ALL OK|FAILURE' | tail -1)"
        if [ "$status" != "0" ] || [ -z "$verdict" ] || echo "$output" | grep -qiE '^FAIL|Exception|Segmentation'; then
            echo "== $name FAILED (exit $status) =="
            echo "$output" | grep -iE '^FAIL|Exception|Segmentation|FAILURE' | head -10
            [ -z "$verdict" ] && echo "  no verdict line: battery did not finish"
            failures=$((failures + 1))
        else
            echo "$name: $verdict"
        fi
    done
}

case "$what" in
    host) run_host_tests ;;
    device) run_device_tests ;;
    all) run_host_tests; run_device_tests ;;
    *) echo "usage: $0 [host|device|all]" >&2; exit 2 ;;
esac

echo
if [ "$failures" -eq 0 ]; then
    echo "run-tests: PASSED"
else
    echo "run-tests: FAILED ($failures)"
fi
exit $((failures ? 1 : 0))
