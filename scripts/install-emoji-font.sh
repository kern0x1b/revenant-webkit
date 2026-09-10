#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/tools/device.sh"

FONTS=/System/Library/Fonts/Cache
BACKUP=/var/mobile/emoji-backup

if [ "${1:-}" = "--status" ]; then
    device_run 20 "cat $BACKUP/installed.txt 2>/dev/null || echo 'no font installed by this script'"
    device_run 20 "ls -l '$FONTS/AppleColorEmoji@2x.ttf' $FONTS/AppleColorEmoji.ttf"
    exit 0
fi

if [ "${1:-}" = "--restore" ]; then
    device_run 60 "cp $BACKUP/AppleColorEmoji*.ttf $FONTS/ && rm -f $BACKUP/installed.txt && echo restored"
    device_run 30 "killall SpringBoard" || true
    echo "restored; the phone is respringing"
    exit 0
fi

SOURCE=${EMOJI_SOURCE:-/System/Library/Fonts/Apple Color Emoji.ttc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$SOURCE" "$WORK/AppleColorEmoji@2x.ttf" "$WORK/AppleColorEmoji.ttf" <<'PY'
import sys
from fontTools.ttLib import TTCollection, TTFont

source = sys.argv[1]

for destination, keep in ((sys.argv[2], (40, 64, 96)), (sys.argv[3], (20, 40, 48, 96))):
    font = TTCollection(source).fonts[0] if source.endswith(".ttc") else TTFont(source)

    for ppem in list(font["sbix"].strikes):
        if ppem not in keep:
            del font["sbix"].strikes[ppem]

    for tag in ("DSIG", "trak", "meta"):
        if tag in font:
            del font[tag]

    for table in font["cmap"].tables:
        if (table.platformID, table.platEncID) == (0, 4):
            table.platEncID = 3

    font.save(destination)
PY

echo "backing up the device's own fonts to $BACKUP"
device_run 30 "mkdir -p $BACKUP; cp -n '$FONTS/AppleColorEmoji@2x.ttf' $BACKUP/; cp -n $FONTS/AppleColorEmoji.ttf $BACKUP/"

for file in "AppleColorEmoji@2x.ttf" "AppleColorEmoji.ttf"; do
    echo "copying $file ($(du -h "$WORK/$file" | cut -f1))"
    device_copy "$WORK/$file" /var/mobile/emoji-new.ttf

    device_run 60 "cp /var/mobile/emoji-new.ttf '$FONTS/$file.new' \
      && chown root:wheel '$FONTS/$file.new' \
      && chmod 644 '$FONTS/$file.new' \
      && mv '$FONTS/$file.new' '$FONTS/$file' \
      && rm -f /var/mobile/emoji-new.ttf"
done

VERSION=$(python3 - "$WORK/AppleColorEmoji@2x.ttf" <<'PY'
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
name = font["name"].getDebugName(5) or "unknown version"
print(f"{name}, {len(font.getGlyphOrder())} glyphs")
PY
)
device_run 20 "echo '$VERSION, installed $(date +%Y-%m-%d)' > $BACKUP/installed.txt"

echo "installed: $VERSION"
echo "respringing"
device_run 30 "killall SpringBoard" || true

cat <<NOTE

If the interface comes back without text, restore over SSH:
  cp $BACKUP/AppleColorEmoji*.ttf $FONTS/ && killall SpringBoard
NOTE
