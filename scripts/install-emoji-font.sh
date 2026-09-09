#!/usr/bin/env bash
# Puts a current Apple Color Emoji on the device, in place of the 2013 one.
#
# The device's font is version 8.0: 1336 code points, nothing added to Unicode
# since. Anything newer draws as a missing-glyph box, and a skin tone or a ZWJ
# sequence draws as its parts. A current font is version 21.4 - measured on the
# device, this CoreText reads its sbix bitmaps and applies its morx shaping, so
# skin tones and ZWJ sequences compose into one glyph.
#
# The font is Apple's and is not in this repository. It is taken from the Mac
# running this script, which is where the user's copy already lives.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/tools/device.sh"

SOURCE=${EMOJI_SOURCE:-/System/Library/Fonts/Apple Color Emoji.ttc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The device is a 2x screen and reads the @2x file, whose strikes are 40, 64 and
# 96 pixels. A current font carries nine strikes; the rest are 100MB this device
# has no room for and no use for.
python3 - "$SOURCE" "$WORK/AppleColorEmoji@2x.ttf" <<'PY'
import sys
from fontTools.ttLib import TTCollection, TTFont

source, destination = sys.argv[1], sys.argv[2]
font = TTCollection(source).fonts[0] if source.endswith(".ttc") else TTFont(source)

for ppem in list(font["sbix"].strikes):
    if ppem not in (40, 64, 96):
        del font["sbix"].strikes[ppem]

for tag in ("DSIG", "trak", "meta"):
    if tag in font:
        del font[tag]

# The 2013 font advertises its full-repertoire cmap under encoding 3, the
# current one under encoding 4. Match the one this CoreText was shipped with.
for table in font["cmap"].tables:
    if (table.platformID, table.platEncID) == (0, 4):
        table.platEncID = 3

font.save(destination)
PY

FONTS=/System/Library/Fonts/Cache
BACKUP=/var/mobile/emoji-backup

echo "backing up the device's own font to $BACKUP"
device_run 30 "mkdir -p $BACKUP; cp -n $FONTS/AppleColorEmoji@2x.ttf $BACKUP/"

echo "copying $(du -h "$WORK/AppleColorEmoji@2x.ttf" | cut -f1)"
device_copy "$WORK/AppleColorEmoji@2x.ttf" /var/mobile/emoji-new.ttf

# Written beside the live file and moved into place, so nothing reads a half
# written font.
device_run 60 "cp /var/mobile/emoji-new.ttf $FONTS/AppleColorEmoji@2x.ttf.new \
  && chown root:wheel $FONTS/AppleColorEmoji@2x.ttf.new \
  && chmod 644 $FONTS/AppleColorEmoji@2x.ttf.new \
  && mv $FONTS/AppleColorEmoji@2x.ttf.new $FONTS/AppleColorEmoji@2x.ttf \
  && rm -f /var/mobile/emoji-new.ttf"

echo "installed; respringing"
device_run 30 "killall SpringBoard" || true

cat <<NOTE

If the interface comes back without text, restore over SSH:
  cp $BACKUP/AppleColorEmoji@2x.ttf $FONTS/AppleColorEmoji@2x.ttf && killall SpringBoard
NOTE
