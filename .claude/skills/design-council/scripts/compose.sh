#!/bin/zsh
# Comparison sheets for the design council: per case, a row of Waiting Paws screenshots and a row of references.
#   COUNCIL=<run> W=round-N/wp compose.sh round-N/sheets      (paths inside $COUNCIL; REFS=… for refs elsewhere)
# A screenshot that does not exist is left out of its row. The cases and their reference pictures are Waiting
# Paws' own (reference/product.md); edit the sheet() calls when a run judges other screens.
set -euo pipefail
source ${0:A:h}/common.zsh
need_council
cd $COUNCIL
OUT=${1:-round-1/sheets}
mkdir -p $OUT
FONT="/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
BG='#1b1b1d'
H=1300
TMP=$(mktemp -d)

tile() { # tile <out> <image> <caption>   → image at height H with a caption under it
  local out=$1 img=$2 cap=$3
  magick "$img" +repage -resize x$H -background $BG -flatten $TMP/r.png
  local w=$(magick identify -format '%w' $TMP/r.png)
  magick $TMP/r.png \( -size ${w}x110 -background $BG -fill '#e8e8ea' -font "$FONT" -pointsize 38 -gravity center caption:"$cap" \) \
    -append -bordercolor $BG -border 24 $out
}
row() { # row <out> <title> <accent> (<image> <caption>)…
  local out=$1 title=$2 accent=$3; shift 3
  local -a tiles; local i=0
  while (( $# )); do
    if [[ -f $1 ]]; then i=$((i+1)); tile $TMP/t$i.png "$1" "$2"; tiles+=($TMP/t$i.png); fi
    shift 2
  done
  magick $tiles -background $BG +append $TMP/strip.png
  local w=$(magick identify -format '%w' $TMP/strip.png)
  magick \( -size ${w}x120 -background $BG -fill $accent -font "$FONT" -pointsize 60 -gravity west \
      label:"   $title" \) $TMP/strip.png -background $BG -append $out
}
sheet() { # sheet <name> <case title> -- wp pairs… -- ref pairs…
  local name=$1 title=$2; shift 2
  local -a wp refs; local mode=
  for a in "$@"; do
    if [[ $a == -- ]]; then [[ -z $mode ]] && mode=wp || mode=ref; continue; fi
    [[ $mode == wp ]] && wp+=("$a") || refs+=("$a")
  done
  row $TMP/wp.png "Waiting Paws" '#ffb3cf' "${wp[@]}"
  row $TMP/ref.png "Референсы" '#9ecbff' "${refs[@]}"
  local w=$(magick $TMP/wp.png $TMP/ref.png -format '%w\n' info: | sort -n | tail -1)
  magick \( -size ${w}x170 -background '#0d0d0f' -fill white -font "$FONT" -pointsize 80 -gravity west label:"  $title" \) \
    $TMP/wp.png $TMP/ref.png -background $BG -gravity northwest -append -resize '3600x>' -quality 88 $OUT/$name.jpg
  echo "$OUT/$name.jpg $(magick identify -format '%wx%h' $OUT/$name.jpg)"
}

W=${W:-wp}; R=${REFS:-refs}
# Case 4 without a Live Activity shot: a card that says there is none.
NONE=$TMP/none.png
if [[ -f $W/ios-11-island.png ]]; then
  NONE=/nonexistent
else
  magick -size 1320x2868 xc:'#000' -fill '#8e8e93' -font "$FONT" -pointsize 64 -gravity center -annotate +0+0 \
    "Нет Live Activity,\nDynamic Island,\nвиджетов, Apple Watch,\nзвуков и вибрации.\n\nВидео на iPhone идёт,\nтолько пока приложение\nна экране." $NONE
fi

sheet c1-plan "Кейс 1 · Расписание тренера: вставка и проверка плана" -- \
  $W/ios-01-home.png "iPhone · главный экран" \
  $W/ios-02-plan-review.png "iPhone · «Проверьте план»" \
  $W/ios-02b-plan-end.png "iPhone · конец плана: свой перерыв" \
  $W/ios-02c-plan-source.png "iPhone · текст тренера из проверки" \
  $W/ios-02e-exit-editor.png "iPhone · редактор выхода" \
  $W/ios-02f-plan-changed.png "iPhone · правки владельца против слов тренера" \
  $W/mac-02-plan.png "Mac · план на таймлайне" \
  $W/mac-03-review.png "Mac · «Расписание разобрано»" -- \
  $R/apple-support/fitness-custom-workout.png "Apple Fitness · Custom Workout" \
  $R/crouton/02.png "Crouton · шаги, время → таймер" \
  $R/runna/01.jpg "Runna · обзор плана" \
  $R/runna/04.jpg "Runna · план готов"

sheet c2-away "Кейс 2 · «За дверью»: идёт выход (iPhone)" -- \
  $W/ios-03-away.png "iPhone · выход" \
  $W/ios-03k-away-stopwatch.png "тап по числу: секундомер" \
  $W/ios-03l-away-overdue.png "сверх плана" \
  $W/ios-03f-away-zoomed.png "владелец приблизил кадр" \
  $W/ios-03g-away-no-frame.png "кадр застыл: «Нет кадра»" \
  $W/ios-03h-away-large-text.png "крупный системный шрифт" \
  $W/ios-03i-away-ax.png "шрифт AX" \
  $W/ios-06-trainer-text.png "iPhone · текст тренера" -- \
  $R/runna/02.jpg "Runna · live coaching" \
  $R/runna/08.jpg "Runna · текущий интервал" \
  $R/crouton/04.png "Crouton · пошаговый режим" \
  $R/gentler-streak/06.jpg "Gentler Streak · тренировка на часах"

sheet c2b-away-mac "Кейс 2 · «За дверью»: идёт выход (Mac)" -- \
  $W/mac-01-session.png "Mac · выход" -- \
  $R/runna/02.jpg "Runna · live coaching" \
  $R/runna/08.jpg "Runna · текущий интервал" \
  $R/crouton/04.png "Crouton · пошаговый режим"

sheet c3-break "Кейс 3 · Перерыв до следующего выхода" -- \
  $W/ios-05f-ready.png "iPhone · перед первым выходом" \
  $W/ios-05-break.png "iPhone · перерыв" \
  $W/ios-05b-false-start-undo.png "iPhone · после «Фальстарт»: «Отменить»" \
  $W/ios-05c-break-false-start.png "iPhone · фальстарт в перерыве" \
  $W/ios-05h-last-break.png "iPhone · последний перерыв" \
  $W/ios-05d-break-ax.png "шрифт AX: перерыв после фальстарта" \
  $W/mac-04-break.png "Mac · перерыв" \
  $W/mac-04b-break-false-start.png "Mac · фальстарт в перерыве" -- \
  $R/runna/08.jpg "Runna · текущий и следующий" \
  $R/crouton/02.png "Crouton · таймер шага" \
  $R/flighty/03.jpg "Flighty · Live Activity"

sheet c4-glance "Кейс 4 · Взгляд мимоходом: экран блокировки, Dynamic Island, часы" -- \
  $NONE "Waiting Paws · этого нет" \
  $W/ios-11-island.png "iPhone · Dynamic Island: компактный и раскрытый" \
  $W/ios-12-lock.png "iPhone · Live Activity (баннер / экран блокировки)" \
  $W/ios-13-notify.png "iPhone · уведомления в фоне" \
  $W/ios-03-away.png "iPhone · то же в приложении" -- \
  $R/flighty/03.jpg "Flighty · Live Activity, Dynamic Island" \
  $R/apple-sports/01.jpg "Apple Sports · Live Activity" \
  $R/flighty/07.jpg "Flighty · уведомления" \
  $R/gentler-streak/06.jpg "Gentler Streak · часы"

sheet c5-summary "Кейс 5 · Итог тренировки и лог для тренера" -- \
  $W/ios-10-finish.png "iPhone · «Тренировка завершена»" \
  $W/ios-07-log.png "iPhone · тренировка из истории" \
  $W/ios-07b-log-bottom.png "iPhone · она же, низ" \
  $W/ios-07d-log-video-gap.png "iPhone · запись прерывалась" \
  $W/mac-06-finish-2.png "Mac · итог тренировки" \
  $W/mac-05-history.png "Mac · тренировка в истории" -- \
  $R/apple-health/02.jpg "Health · Sleep Score" \
  $R/flighty/08.jpg "Flighty · план и факт" \
  $R/runna/06.jpg "Runna · итоги" \
  $R/gentler-streak/03.jpg "Gentler Streak · итог сна"

sheet c6-history "Кейс 6 · История и прогресс" -- \
  $W/ios-08-history.png "iPhone · история" \
  $W/ios-08b-history-edit.png "iPhone · правка истории" \
  $W/ios-08c-history-recordings.png "iPhone · значки записи" \
  $W/mac-05-history.png "Mac · история и график" -- \
  $R/apple-fitness/01.jpg "Apple Fitness · Summary" \
  $R/apple-health/01.jpg "Apple Health · Summary" \
  $R/gentler-streak/07.jpg "Gentler Streak · прогресс" \
  $R/gentler-streak/10.jpg "Gentler Streak · месяц" \
  $R/runna/05.jpg "Runna · динамика"

sheet c7-camera "Кейс 7 · Камера, выбор камеры, таймлайн" -- \
  $W/ios-01-home.png "iPhone · камера на главном" \
  $W/ios-09-cameras.png "iPhone · выбор камеры" \
  $W/mac-01-session.png "Mac · камера и таймлайн" -- \
  $R/apple-home/01.jpg "Apple Home · камеры" \
  $R/apple-home/02.jpg "Apple Home · лента событий" \
  $R/final-cut-pro/04.jpg "Final Cut Pro · таймлайн" \
  $R/final-cut-pro/07.jpg "Final Cut Pro · дорожки"
rm -rf $TMP
