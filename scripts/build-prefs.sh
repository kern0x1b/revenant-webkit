#!/usr/bin/env bash
# Build the RevWebKit Settings PreferenceBundle: a real PSListController-based
# Preferences pane (no Theos) that writes the space.kern0x1b.rev domain the
# Safari compat dylib reads. Output layout, ready to push to the device:
#
#   dist/RevPrefs.bundle/                -> /Library/PreferenceBundles/RevPrefs.bundle
#   dist/RevWebKit.plist (entry)         -> /Library/PreferenceLoader/Preferences/RevWebKit.plist
#
#   ./build-prefs.sh
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
SRC="$P/platform/prefs"
SDK=${IOS_SDK:-$HOME/Git/tools/sdks/iPhoneOS13.7.sdk}
TC=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
BUNDLE="$P/dist/RevPrefs.bundle"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"

# The PS* superclasses (PSListController, PSSpecifier) live in Preferences.framework,
# present in the Preferences.app process that loads this bundle, not in the SDK; a
# loadable bundle resolves them at load time via dynamic_lookup + flat namespace.
"$TC/usr/bin/clang" \
    -target armv7-apple-ios6.0 -isysroot "$SDK" -Os -fno-objc-arc \
    -Wno-deprecated-declarations -Wno-unused \
    -I "$SRC" \
    -bundle -undefined dynamic_lookup -flat_namespace \
    -framework Foundation -framework UIKit -framework CoreFoundation -lobjc \
    "$SRC/RevRootListController.m" "$SRC/RevAppsListController.m" \
    -o "$BUNDLE/RevPrefs"
ldid -S "$BUNDLE/RevPrefs" 2>/dev/null || true

cp "$SRC/Resources/Info.plist" "$BUNDLE/Info.plist"
cp "$SRC/Resources/icon.png" "$BUNDLE/icon.png" 2>/dev/null || true
cp "$SRC/Resources/icon@2x.png" "$BUNDLE/icon@2x.png" 2>/dev/null || true
cp "$SRC/Resources/Root.plist" "$BUNDLE/Root.plist"
cp "$SRC/entry.plist" "$P/dist/RevWebKit.plist"

echo "built $BUNDLE"
echo "entry $P/dist/RevWebKit.plist"
