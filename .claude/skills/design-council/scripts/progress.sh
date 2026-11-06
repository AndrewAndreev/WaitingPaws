#!/bin/zsh
# "Было → стало" for the user: the same screen across rounds, side by side.
#   COUNCIL=<run> progress.sh <out.jpg> <title> (<round label> <image>)…   (relative paths inside $COUNCIL)
# Also makes the custom sheets, e.g. round-N/sheets/c0-main-vs-now.jpg: (main final/main/…) (R11 …) (сейчас …).
set -euo pipefail
source ${0:A:h}/common.zsh
need_council
cd $COUNCIL
OUT=$1; TITLE=$2; shift 2
FONT="/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
BG='#1b1b1d'
TMP=$(mktemp -d); i=0; tiles=()
while (( $# )); do
  label=$1 img=$2; shift 2
  [[ -f $img ]] || continue
  i=$((i+1))
  magick "$img" +repage -resize x1400 -background $BG -flatten $TMP/r.png
  w=$(magick identify -format '%w' $TMP/r.png)
  magick \( -size ${w}x90 -background $BG -fill '#ffb3cf' -font "$FONT" -pointsize 48 -gravity center label:"$label" \) \
    $TMP/r.png -append -bordercolor $BG -border 20 $TMP/t$i.png
  tiles+=($TMP/t$i.png)
done
magick $tiles -background $BG +append $TMP/strip.png
w=$(magick identify -format '%w' $TMP/strip.png)
magick \( -size ${w}x110 -background '#0d0d0f' -fill white -font "$FONT" -pointsize 60 -gravity west label:"  $TITLE" \) \
  $TMP/strip.png -append -resize '3000x>' -quality 85 $OUT
rm -rf $TMP
echo "$OUT"
