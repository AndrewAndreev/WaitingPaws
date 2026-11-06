#!/bin/zsh
# The council's three Live Activity sheets from $LA/shots/: $LA/island-sheet.png, lock-sheet.png, notify-sheet.png.
# Then into the round: magick $LA/island-sheet.png +repage <run>/round-N/wp/ios-11-island.png (lock → ios-12-lock,
# notify → ios-13-notify). The captions are round 16's: rewrite them to say what this round's states show.
set -euo pipefail
source ${0:A:h}/common.zsh
cd $LA
S=shots; W=sheet; F=/System/Library/Fonts/SFNS.ttf
mkdir -p $W
title() { magick -background white -fill '#111' -font $F -pointsize 27 -size $(( ${2:-1230} - 60 ))x -gravity west label:"$1" -bordercolor white -border 30x14 +repage $3; }
cap() { magick -background white -fill '#555' -font $F -pointsize 21 -size $(( $2 - 18 ))x34 -gravity southwest label:"$1" -gravity west -splice 18x0 +repage $3; }

# Compact island: caption on the left, the island on the right.
title "Компактный остров: сверх плана — один жёлтый, как в приложении; оранжевый — только «нет связи»" 1230 $W/t1.png
rows=()
i=0
for pair in "a-away|Выход: отсчёт" "b-over|Сверх плана" "g-break|Перерыв: знак «пауза»" \
            "h-breakover|Перерыв дольше плана" "k-timeup|План вышел, приложение спит: сам" "j-maclost|Нет связи с Mac"; do
  n=${pair%%|*} t=${pair#*|}; i=$((i+1))
  # The status bar's Wi-Fi sign starts just right of the narrow islands: covered (the wide ones hide it).
  cover=(-fill white -draw "rectangle 736,0 759,149")
  # Without a link the island is the sign alone: the status bar shows on both sides of it.
  [[ $n == j-maclost ]] && cover=(-fill white -draw "rectangle 0,0 84,149" -draw "rectangle 606,0 759,149")
  magick $S/$n-compact.png -crop 760x150+246+22 +repage $cover -resize 58% $W/ci.png
  magick -background white -fill '#222' -font $F -pointsize 23 -size 400x90 -gravity west label:"$t" $W/cl.png
  magick $W/cl.png $W/ci.png +append -background white -gravity west -extent 1230x90 -splice 30x0 -crop 1230x90+0+0 +repage $W/c$i.png
  rows+=($W/c$i.png)
done
magick $rows -background white -splice 0x6 -append $W/compact.png

# Expanded island: two columns, a caption over each.
title "Раскрытый остров: название, число, «Вернулись»/«Вышли»; справа только триггер перерыва (молния) или «с Mac в …» старых данных" 1230 $W/t2.png
EH=${EH:-430}
cell() { # cell <shot> <caption> <out>
  magick $S/$1-exp.png -crop 1206x${EH}+0+8 +repage -resize 50% $W/x.png
  cap "$2" 603 $W/xc.png
  magick $W/xc.png $W/x.png -background white -append $3
}
cell a-away "Выход 3 из 5: отсчёт" $W/e1.png
cell b-over "Сверх плана: жёлтое «+…» (как в приложении)" $W/e2.png
cell k-timeup "План вышел, приложение спит: само" $W/e3.png
cell g-break "Перерыв перед выходом 4: молния «взять ключи»" $W/e4.png
cell g2-break-plain "Перерыв без триггера" $W/e5.png
cell h-breakover "Перерыв дольше плана" $W/e6.png
cell i-mac "С Mac, приложение в фоне: данные свежие" $W/e7.png
cell m-mac-timeup "С Mac, приложение уснуло: «с Mac в …»" $W/e8.png
cell j-maclost "Нет связи с Mac: справа «Открыть»" $W/e9.png
cell g3-last-break "Последний перерыв: своё время растёт, без линии и кнопки" $W/e10.png
for r in 1 2 3 4 5; do
  magick $W/e$((2*r-1)).png $W/e$((2*r)).png -background white -gravity north +smush 12 -gravity center -extent 1230x -gravity north -splice 0x8 $W/er$r.png
done
magick $W/t1.png $W/compact.png $W/t2.png $W/er1.png $W/er2.png $W/er3.png $W/er4.png $W/er5.png -background white -append \
  -bordercolor white -border 0x16 +repage island-sheet.png

# Lock screen: two columns.
title "Экран блокировки: сверх плана — жёлтый приложения; оранжевые — только молния и «Нет связи с Mac»" 1230 $W/t3.png
LY=${LY:-1760}; LH=${LH:-470}
lcell() {
  magick $S/$1-lock.png -crop 1206x${LH}+0+$LY +repage -resize 50% $W/x.png
  cap "$2" 603 $W/xc.png
  magick $W/xc.png -background white -extent 603x46 $W/xc.png
  magick $W/xc.png $W/x.png -background white -append $3
}
lcell a-away "Выход 3 из 5: отсчёт" $W/l1.png
lcell b-over "Сверх плана: жёлтое «+…» (как в приложении)" $W/l2.png
lcell k-timeup "План вышел, приложение спит: само" $W/l3.png
lcell g-break "Перерыв перед выходом 4: молния «взять ключи»" $W/l4.png
lcell g2-break-plain "Перерыв без триггера" $W/l5.png
lcell h-breakover "Перерыв дольше плана" $W/l6.png
lcell i-mac "С Mac, приложение в фоне: данные свежие" $W/l7.png
lcell m-mac-timeup "С Mac, приложение уснуло: «с Mac в …»" $W/l8.png
lcell j-maclost "Нет связи с Mac: числа нет, справа «Открыть»" $W/l9.png
lcell g3-last-break "Последний перерыв: своё время растёт, без линии и кнопки" $W/l10.png
for r in 1 2 3 4 5; do
  magick $W/l$((2*r-1)).png $W/l$((2*r)).png -background white -gravity north +smush 12 -gravity center -extent 1230x -gravity north -splice 0x10 $W/lr$r.png
done
magick $W/t3.png $W/lr1.png $W/lr2.png $W/lr3.png $W/lr4.png $W/lr5.png -background white -append -bordercolor white -border 0x16 +repage lock-sheet.png

# Notifications: the whole lock screen, a caption over each.
ncol() { # ncol <shot> <caption line 1> <caption line 2> <out>
  magick -background black -fill white -font $F -pointsize 22 -gravity center label:"$2\n$3" -extent 603x76 $W/nc.png
  magick $S/$1.png -resize 50% $W/n.png
  magick $W/nc.png $W/n.png -background black -append $4
}
ncol n1-plan "«Выход 3 — время вышло»" "одной строкой" $W/n1.png
ncol n2-break "«Перерыв закончился»" "одной строкой, без «Перед выходом 4»" $W/n2.png
ncol n3-maclost "С Mac без связи: та же одна строка;" "«Нет связи с Mac» — на карточке" $W/n3.png
magick $W/n1.png $W/n2.png $W/n3.png -background black +smush 8 -bordercolor black -border 10x10 +repage notify-sheet.png
magick identify island-sheet.png lock-sheet.png notify-sheet.png
