#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/webkit-254/Source/WebCore/PAL/pal/text/TextCodecICU.cpp"
out="$root/tests/host/required-encodings.txt"

grep -oE 'DECLARE_ENCODING_NAME(_NO_ALIASES)?\("[^"]+"' "$source_file" \
    | sed -E 's/.*"([^"]+)"/\1/' | sort -u > "$out.tmp"

echo "UTF-8" >> "$out.tmp"
sort -u "$out.tmp" > "$out"
rm -f "$out.tmp"
echo "$(wc -l < "$out" | tr -d ' ') encodings -> $out"
