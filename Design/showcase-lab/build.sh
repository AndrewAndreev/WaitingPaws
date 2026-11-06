#!/bin/zsh
# Every background palette of Tools/screenshots/compose.swift on the showcase pictures and two Mac App Store shots,
# composed from the raw shots Tools/screenshots/make.sh left in /tmp/wp-shots/raw (or $WP_RAW) → shots/<palette>-<kind>-<lang>.jpg,
# 1200 px wide. index.html shows them side by side (launch config "showcase", node serve.js → :8772).
#
#   Design/showcase-lab/build.sh                  all palettes
#   Design/showcase-lab/build.sh night paper      only these
set -euo pipefail
LAB=${0:A:h}
ROOT=${LAB:h:h}
RAW=${WP_RAW:-/tmp/wp-shots/raw}
cd $ROOT
PALETTES=(night black paper blush sand sage midnight rose)
(( $# )) && PALETTES=($@)
TMP=$(mktemp -d)
small() { magick "$1" -resize 1200x -alpha off -quality 82 -sampling-factor 4:4:4 "$2"; }
for bg in $PALETTES; do
  WP_BG=$bg Tools/screenshots/make.sh showcase $TMP/$bg >/dev/null
  for lang in en ru; do
    WP_BG=$bg /tmp/wp-compose mac-store $TMP/$bg/store-session-$lang.png $RAW/mac-$lang-m01-session.png
    WP_BG=$bg /tmp/wp-compose mac-store $TMP/$bg/store-review-$lang.png $RAW/mac-$lang-m03-review-2.png
    for kind in iphone mac store-session store-review; do
      small $TMP/$bg/$kind-$lang.png $LAB/shots/$bg-$kind-$lang.jpg
    done
  done
  echo $bg
done
rm -rf $TMP
