#!/usr/bin/env bash
# Install the Rev-prefixed engine frameworks to a FIXED device path
# (/Library/RevenantWebKit/Frameworks), so a MobileSubstrate tweak injected
# into another app's already-running process can load them. A standalone app
# links them at @executable_path (build-app-rev.sh); a tweak has no bundle of
# its own, so an absolute install path is used instead. The Rev class prefix
# keeps them from colliding with the host process's own system WebKit by
# class name; this private path keeps them from colliding by dyld path.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
B=$P/build-254-rev
DEST=/Library/RevenantWebKit/Frameworks
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

. "$P/tools/device.sh"

SYS_JSC=/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
SYS_WC=/System/Library/PrivateFrameworks/WebCore.framework/WebCore
SYS_WKL=/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy

for fw in JavaScriptCore WebCore WebKitLegacy; do
    cp -R "$B/$fw.framework" "$STAGE/"
done
cp "$P/third_party/libcxx-armv7/lib/libc++.1.0.dylib"    "$STAGE/libc++.1.dylib"
cp "$P/third_party/libcxx-armv7/lib/libc++abi.1.0.dylib" "$STAGE/libc++abi.1.dylib"

relink() {
    local bin=$1
    install_name_tool -change "@executable_path/Frameworks/libc++.1.dylib"    "$DEST/libc++.1.dylib"    "$bin" 2>/dev/null || true
    install_name_tool -change "@executable_path/Frameworks/libc++abi.1.dylib" "$DEST/libc++abi.1.dylib" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_JSC" "$DEST/JavaScriptCore.framework/JavaScriptCore" "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WC"  "$DEST/WebCore.framework/WebCore"               "$bin" 2>/dev/null || true
    install_name_tool -change "$SYS_WKL" "$DEST/WebKitLegacy.framework/WebKitLegacy"      "$bin" 2>/dev/null || true
    install_name_tool -change "@rpath/WebCore.framework/WebCore"               "$DEST/WebCore.framework/WebCore"               "$bin" 2>/dev/null || true
    install_name_tool -change "@rpath/JavaScriptCore.framework/JavaScriptCore" "$DEST/JavaScriptCore.framework/JavaScriptCore" "$bin" 2>/dev/null || true
    install_name_tool -change "@rpath/WebKitLegacy.framework/WebKitLegacy"     "$DEST/WebKitLegacy.framework/WebKitLegacy"     "$bin" 2>/dev/null || true
}

for fw in JavaScriptCore WebCore WebKitLegacy; do
    bin="$STAGE/$fw.framework/$fw"
    install_name_tool -id "$DEST/$fw.framework/$fw" "$bin"
    relink "$bin"
    python3 "$P/tools/set-dylib-version.py" "$bin" 1.0.0
done
install_name_tool -id "$DEST/libc++.1.dylib"    "$STAGE/libc++.1.dylib"
install_name_tool -id "$DEST/libc++abi.1.dylib" "$STAGE/libc++abi.1.dylib"
install_name_tool -change "@executable_path/Frameworks/libc++abi.1.dylib" "$DEST/libc++abi.1.dylib" "$STAGE/libc++.1.dylib" 2>/dev/null || true

find "$STAGE" -type f \( -name "*.dylib" -o -path "*.framework/*" -perm +111 \) -exec ldid -S {} \; 2>/dev/null

echo "pushing to device $DEST"
device_run 20 "rm -rf /Library/RevenantWebKit && mkdir -p $DEST"
tar -C "$STAGE" -czf - . \
  | sshpass -p "$DEVICE_PASSWORD" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" \
      "root@$DEVICE_HOST" "cd $DEST && tar xzf - && chown -R root:wheel /Library/RevenantWebKit && chmod -R 755 /Library/RevenantWebKit && find /Library/RevenantWebKit -name '._*' -delete"
device_run 15 "ls -la $DEST 2>&1"
echo "installed"
