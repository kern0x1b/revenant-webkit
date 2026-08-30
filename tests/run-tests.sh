#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
what="${1:-all}"
failures=0

run_host_tests() {
    local icu_lib="$root/build-icu-host/lib"
    if [ ! -f "$icu_lib/libicudata.a" ]; then
        echo "skip host tests: build-icu-host not built" >&2
        return 0
    fi
    local bin="${TMPDIR:-/tmp}/legacy-webkit-tests"
    mkdir -p "$bin"

    "$root/tests/host/gen-required-encodings.sh" > /dev/null

    for name in icu-sanity icu-locales; do
        clang++ -o "$bin/$name" "$root/tests/host/$name.cpp" \
            -I "$root/third_party/icu/source/common" \
            -I "$root/third_party/icu/source/i18n" \
            -L "$icu_lib" -licui18n -licuuc -licudata || { failures=$((failures + 1)); continue; }
    done

    echo "== icu-sanity =="
    "$bin/icu-sanity" "$root/tests/host/required-encodings.txt" \
        "$root/tests/host/known-missing-encodings.txt" | tail -6 || failures=$((failures + 1))
    echo "== icu-locales =="
    "$bin/icu-locales" | tail -2 || failures=$((failures + 1))
}

IPHONE_UDID=${IPHONE_UDID:-7bbc450898f1db61da9a5aac3e4c5d8119d7d358}
SSH_PORT=${SSH_PORT:-2225}
ssh_opts=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
    -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no)

# The phone answers over the USB tunnel or over Wi-Fi; whichever is up is used,
# so unplugging the cable does not turn the device tests into a failure.
DEVICE_HOST=127.0.0.1
device_ready() {
    if pgrep -f "iproxy $SSH_PORT:22 -u $IPHONE_UDID" > /dev/null \
        && $DEVICE_SSH "${ssh_opts[@]}" -p "$SSH_PORT" root@127.0.0.1 true 2>/dev/null; then
        DEVICE_HOST=127.0.0.1
        return 0
    fi
    for address in ${DEVICE_WIFI_ADDRESSES:-${DEVICE_HOST:-}}; do
        if $DEVICE_SSH "${ssh_opts[@]}" -p 22 "root@$address" true 2>/dev/null; then
            DEVICE_HOST=$address
            SSH_PORT=22
            return 0
        fi
    done
    return 1
}

DEVICE_DIR=/tmp/jscrun

sync_engine() {
    local built="$root/build-254"
    [ -f "$built/jsc" ] || (cd "$built" && ninja jsc > /dev/null 2>&1)
    [ -f "$built/jsc" ] || { echo "cannot build jsc" >&2; return 1; }

    device_run "mkdir -p $DEVICE_DIR/Frameworks" > /dev/null

    local remote_sizes
    remote_sizes=$(device_run "ls -l $DEVICE_DIR/jsc $DEVICE_DIR/Frameworks/*.dylib $DEVICE_DIR/Frameworks/*.framework/* 2>/dev/null" | awk 'NF >= 9 { print $NF, $5 }')

    push_if_changed "$built/jsc" "$DEVICE_DIR/jsc" "$remote_sizes" || return 1
    local lib base
    for lib in libc++.1.0.dylib libc++abi.1.0.dylib; do
        base=$(echo "$lib" | sed "s/\.1\.0\./.1./")
        push_if_changed "$root/third_party/libcxx-armv7/lib/$lib" \
            "$DEVICE_DIR/Frameworks/$base" "$remote_sizes" || return 1
    done

    local framework
    for framework in JavaScriptCore WebCore WebKitLegacy; do
        local binary="$built/$framework.framework/$framework"
        [ -f "$binary" ] || continue
        device_run "mkdir -p $DEVICE_DIR/Frameworks/$framework.framework" > /dev/null
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
    $DEVICE_SCP "${ssh_opts[@]}" -P "$SSH_PORT" "$local_path" \
        "root@$DEVICE_HOST:$remote_path" > /dev/null 2>&1
}

device_run() {
    $DEVICE_SSH "${ssh_opts[@]}" -p "$SSH_PORT" root@$DEVICE_HOST "$1" 2>/dev/null
}

run_device_tests() {
    if ! device_ready; then
        echo "device tests: iPhone not reachable" >&2
        echo "  start the tunnel with: iproxy 2225:22 -u $IPHONE_UDID &" >&2
        echo "  or put its Wi-Fi address in DEVICE_WIFI_ADDRESSES" >&2
        failures=$((failures + 1))
        return
    fi

    sync_engine || { failures=$((failures + 1)); return; }

    $DEVICE_SCP "${ssh_opts[@]}" -P "$SSH_PORT" \
        "$root"/tests/js/*.js "root@$DEVICE_HOST:$DEVICE_DIR/" > /dev/null 2>&1

    local script name output status verdict
    for script in "$root"/tests/js/*.js; do
        name="$(basename "$script")"
        output=$(device_run "cd $DEVICE_DIR && DYLD_FRAMEWORK_PATH=$DEVICE_DIR/Frameworks ./jsc $name 2>&1; echo EXIT=\$?")
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
