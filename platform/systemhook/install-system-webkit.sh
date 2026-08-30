#!/usr/bin/env bash
# Replace the device's system WebKitLegacy/WebCore/JavaScriptCore with this
# port's build, so every app on the device that uses UIWebView - not just the
# ones this repo packages - gets the same engine.
#
# NOT SAFE TO RUN UNATTENDED. This overwrites frameworks every UIWebView-based
# app on the device links against, on a device shared with another project.
# A bad build here does not just break LegacyBrowser - it can break Safari,
# Mail, Cydia's own UI, anything else that opens a web view, on first launch
# after this runs. Read this whole script before running it, run it only
# against a device you can afford to be wrong about, and keep the backup this
# script makes (BACKUP below) until you have confirmed several other apps
# still open pages correctly.
#
# Usage: DEVICE=root@host PORT=22 ./install-system-webkit.sh
# Reversed by: ./uninstall-system-webkit.sh (same DEVICE/PORT)
set -euo pipefail
P=$(cd "$(dirname "$0")/../.." && pwd)
B=${WEBKIT_BUILD_DIR:-$P/build-254}
DEVICE=${DEVICE:?set DEVICE=root@host}
PORT=${PORT:-22}
PASS=${DEVICE_PASSWORD:-}
SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
BACKUP=/var/backups/revenant-system-frameworks
LIBCXX_DIR=/usr/lib/revenant

dev_ssh() { sshpass -p "$PASS" ssh $SSH_OPTS -p "$PORT" "$DEVICE" "$@"; }

# All three frameworks link libc++ as @executable_path/Frameworks/libc++*.dylib,
# which resolves fine inside an app bundle (build-app.sh copies those dylibs
# into each bundle's own Frameworks/) but means nothing to Safari, Mail, or any
# other app that did not bundle them. Installed system-wide too, at a fixed
# path every app can reach regardless of its own executable location.
LIBCXX=(libc++.1.dylib libc++abi.1.dylib)

FRAMEWORKS=(
    "JavaScriptCore.framework/JavaScriptCore:/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"
    "WebCore.framework/WebCore:/System/Library/PrivateFrameworks/WebCore.framework/WebCore"
    "WebKitLegacy.framework/WebKitLegacy:/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy"
)

echo "This will overwrite system frameworks on $DEVICE. Backups go to $BACKUP."
read -r -p "Type YES to continue: " confirm
[ "$confirm" = "YES" ] || { echo "aborted"; exit 1; }

# Not every framework in $B already declares a system absolute install name
# (checked empirically: JavaScriptCore and WebKitLegacy do, WebCore's own ID
# is @rpath/WebCore.framework/WebCore, which only resolves inside an app
# bundle carrying the matching LC_RPATH - not as a bare system file). Rather
# than assume, every ID and cross-reference is rewritten on a scratch copy so
# what actually lands on the device is unambiguously self-consistent, the same
# way build-app.sh rewrites a copy for @executable_path bundling instead of
# trusting the raw build output.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
for entry in "${FRAMEWORKS[@]}"; do
    local_path=${entry%%:*}
    cp "$B/$local_path" "$SCRATCH/$(basename "$local_path")"
done
for lib in "${LIBCXX[@]}"; do
    cp "$P/third_party/libcxx-armv7/lib/$lib" "$SCRATCH/$lib"
done

for entry in "${FRAMEWORKS[@]}"; do
    sys_path=${entry##*:}
    bin="$SCRATCH/$(basename "$sys_path")"
    install_name_tool -id "$sys_path" "$bin"
    for dep in "${FRAMEWORKS[@]}"; do
        dep_local=${dep%%:*}; dep_sys=${dep##*:}
        for old in "@rpath/$(basename "$dep_local").framework/$(basename "$dep_local")" \
                   "$(otool -D "$B/$dep_local" | tail -1)"; do
            install_name_tool -change "$old" "$dep_sys" "$bin" 2>/dev/null || true
        done
    done
    for lib in "${LIBCXX[@]}"; do
        install_name_tool -change "@executable_path/Frameworks/$lib" "$LIBCXX_DIR/$lib" "$bin" 2>/dev/null || true
    done
    if otool -L "$bin" | tail -n +2 | grep -qE '@rpath/|@executable_path/'; then
        echo "refusing: $bin still has an unresolved relocatable dependency" >&2
        otool -L "$bin" >&2
        exit 1
    fi
    # Signed on the host, same as build-app.sh does for every executable and
    # dylib it ships - the device's own ldid is not assumed to be present.
    ldid -S "$bin"
done
for lib in "${LIBCXX[@]}"; do
    install_name_tool -id "$LIBCXX_DIR/$lib" "$SCRATCH/$lib"
    # libc++.1.dylib itself depends on libc++abi.1.dylib the same
    # @executable_path-relative way, needing the identical fixup.
    for dep in "${LIBCXX[@]}"; do
        install_name_tool -change "@executable_path/Frameworks/$dep" "$LIBCXX_DIR/$dep" "$SCRATCH/$lib" 2>/dev/null || true
    done
    if otool -L "$SCRATCH/$lib" | tail -n +2 | grep -qE '@rpath/|@executable_path/'; then
        echo "refusing: $SCRATCH/$lib still has an unresolved relocatable dependency" >&2
        otool -L "$SCRATCH/$lib" >&2
        exit 1
    fi
    ldid -S "$SCRATCH/$lib"
done

dev_ssh "mkdir -p $BACKUP $LIBCXX_DIR"
for entry in "${FRAMEWORKS[@]}"; do
    sys_path=${entry##*:}
    name=$(basename "$sys_path")
    echo "backing up $sys_path"
    dev_ssh "test -f '$BACKUP/$name' || cp '$sys_path' '$BACKUP/$name'"
done

for lib in "${LIBCXX[@]}"; do
    echo "installing $lib -> $LIBCXX_DIR/$lib"
    sshpass -p "$PASS" scp $SSH_OPTS -P "$PORT" "$SCRATCH/$lib" "$DEVICE:$LIBCXX_DIR/$lib.new"
    dev_ssh "chown root:wheel '$LIBCXX_DIR/$lib.new' && chmod 755 '$LIBCXX_DIR/$lib.new' && mv '$LIBCXX_DIR/$lib.new' '$LIBCXX_DIR/$lib'"
done
for entry in "${FRAMEWORKS[@]}"; do
    sys_path=${entry##*:}
    bin="$SCRATCH/$(basename "$sys_path")"
    echo "installing $(basename "$sys_path") -> $sys_path"
    sshpass -p "$PASS" scp $SSH_OPTS -P "$PORT" "$bin" "$DEVICE:$sys_path.new"
    dev_ssh "chown root:wheel '$sys_path.new' && chmod 755 '$sys_path.new' && mv '$sys_path.new' '$sys_path'"
done

echo "respringing"
dev_ssh "killall SpringBoard"
echo "done. verify Safari, Mail, and any other UIWebView app still opens a page before trusting this."
echo "backup kept at $BACKUP on device; run uninstall-system-webkit.sh to restore."
