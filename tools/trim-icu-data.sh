#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
data_dir="$root/third_party/icu/source/data/in"
full="$data_dir/icudt74l.dat.full"
icupkg="$root/build-icu-host/bin/icupkg"
keep_languages="$root/tools/icu-keep-languages.txt"
work="${TMPDIR:-/tmp}/icu-trim.$$"

[ -f "$full" ] || { echo "missing $full" >&2; exit 1; }
[ -x "$icupkg" ] || { echo "missing $icupkg (build host ICU first)" >&2; exit 1; }

trap 'rm -rf "$work"' EXIT
mkdir -p "$work/in" "$work/out"
cp "$full" "$work/in/icudt74l.dat"

"$icupkg" -l "$work/in/icudt74l.dat" > "$work/all.txt"

locale_dirs="curr zone region lang unit coll"
drop_dirs="rbnf translit"

: > "$work/keep.txt"
while read -r entry; do
    dir="${entry%%/*}"
    base="$(basename "$entry")"
    name="${base%.*}"
    language="${name%%_*}"

    case "$entry" in
        *.cnv) echo "$entry" >> "$work/keep.txt"; continue ;;
    esac

    for d in $drop_dirs; do
        [ "$dir" = "$d" ] && continue 2
    done

    case "$base" in
        pool.res|root.res|res_index.res) echo "$entry" >> "$work/keep.txt"; continue ;;
    esac

    in_locale_dir=no
    for d in $locale_dirs; do
        [ "$dir" = "$d" ] && in_locale_dir=yes
    done
    looks_like_locale=no
    case "$language" in
        [a-z][a-z]|[a-z][a-z][a-z]) looks_like_locale=yes ;;
    esac

    if [ "$looks_like_locale" = yes ] && { [ "$in_locale_dir" = yes ] || [ "$dir" = "$entry" ]; }; then
        grep -qx "$language" "$keep_languages" || continue
    fi

    echo "$entry" >> "$work/keep.txt"
done < "$work/all.txt"

comm -23 <(sort "$work/all.txt") <(sort "$work/keep.txt") > "$work/remove.txt"
"$icupkg" --ignore-deps -r "$work/remove.txt" "$work/in/icudt74l.dat" "$work/out/icudt74l.dat" > /dev/null

cp "$work/out/icudt74l.dat" "$data_dir/icudt74l.dat"
printf 'kept %s of %s items, %s -> %s\n' \
    "$(wc -l < "$work/keep.txt" | tr -d ' ')" \
    "$(wc -l < "$work/all.txt" | tr -d ' ')" \
    "$(du -h "$full" | cut -f1 | tr -d ' ')" \
    "$(du -h "$data_dir/icudt74l.dat" | cut -f1 | tr -d ' ')"
