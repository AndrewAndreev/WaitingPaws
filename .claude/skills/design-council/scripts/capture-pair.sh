#!/bin/zsh
# The same screens of two builds with the same launch flags, for the «base → сейчас» tab of the comparison page:
#   COUNCIL=<run> capture-pair.sh <out dir> <iOS derived data> <Mac derived data> [ios|mac|all]
#   base:  capture-pair.sh final/main /tmp/wp-dd-main-S /tmp/wp-dd-main-M
#   now:   capture-pair.sh round-N/pair /tmp/wp-dd-S /tmp/wp-dd-M
# Only flags the BASE build already understood (these are main 8cc5a85's), so both pictures show the same state:
# check `git show <base>:App/Sources/Debug/DemoData.swift` and drop the rest. Screens that exist only now come from
# capture.sh.
set -euo pipefail
source ${0:A:h}/common.zsh
OUT=$(council_path ${1:?out dir}); DD=${2:?iOS derived data}; MAC_DD=${3:?Mac derived data}; WHAT=${4:-all}
cd $REPO
mkdir -p $OUT
PLAN_RU=$'🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026\n➡️ В перерывах сидите за столом, работаете\n➡️ Все перерывы 2 минуты\n1 выход - 10 секунд\n2 выход - 30 секунд + куртка\n3 выход - 15 секунд\n4 выход - 1 минута + взять ключи\n5 выход - 45 секунд\n6 выход - 2 минуты ИЛИ до вставания\n🟡 Если встала и пошла - входим через 1 минуту\n🟢 Если легла - входим через 20 секунд\nПерерыв 5 минут\n7 выход - 30 секунд\n8 выход - 3 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'
SESSION_RU=$'🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 15 секунд\n2 выход - 30 секунд\n3 выход - 1 минута + куртка\n🟡 Если встала и пошла - входим через 30 секунд\n🟢 Если легла - входим через 20 секунд\n4 выход - 45 секунд + взять ключи\n5 выход - 2 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'

if [[ $WHAT == all || $WHAT == ios ]]; then
  SIM_NAME=${SIM_NAME:-WP Screens}
  SIM=$(xcrun simctl list devices | awk -F'[()]' -v name="$SIM_NAME" 'index($0, "    " name " (") == 1 {print $2; exit}')
  xcrun simctl boot $SIM 2>/dev/null || true
  xcrun simctl bootstatus $SIM -b >/dev/null
  # The text size of an earlier run may outlive a shutdown that came too soon after its reset: start from the
  # default every time.
  xcrun simctl ui $SIM content_size large >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl uninstall $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
  xcrun simctl install $SIM $DD/Build/Products/Debug-iphonesimulator/WaitingPaws.app
  xcrun simctl status_bar $SIM override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName ""
  xcrun simctl ui $SIM content_size large >/dev/null 2>&1 || true
  DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
  mkdir -p $DATA/tmp && cp Tools/demo-camera.jpg $DATA/tmp/
  ios() { # ios <name> [args…]
    local name=$1; shift
    xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
    xcrun simctl launch $SIM su.comrade.waitingpaws -AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая" \
      -streamName hall --ui-preview "--demo-camera=$DATA/tmp/demo-camera.jpg" "$@" >/dev/null
    sleep ${WAIT:-7}
    xcrun simctl io $SIM screenshot $OUT/ios-$name.png >/dev/null 2>&1
    echo "ios-$name"
  }
  S=(-demoPlanText "$SESSION_RU" --demo-session --demo-exits-done 2)
  WAIT=12 ios warmup
  ios 01-home --demo-history
  ios 02-plan-review --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU"
  ios 03-away "${S[@]}" --demo-phase away --demo-recording --demo-second-camera
  WAIT=9 ios 05-break "${S[@]}" --demo-phase break --demo-recording
  WAIT=9 ios 06-trainer-text "${S[@]}" --demo-phase away --demo-trainer-text
  ios 07-log --demo-history --demo-screen history-last
  ios 08-history --demo-history --demo-screen history
  WAIT=9 ios 09-cameras --demo-cameras --demo-screen camera
  WAIT=9 ios 10-finish -demoPlanText "$SESSION_RU" --demo-session --demo-exits-done 5 --demo-phase finish
  xcrun simctl ui $SIM content_size extra-extra-large >/dev/null 2>&1 || true
  ios 03h-away-large-text "${S[@]}" --demo-phase away --demo-recording
  xcrun simctl ui $SIM content_size accessibility-extra-large >/dev/null 2>&1 || true
  ios 03i-away-ax "${S[@]}" --demo-phase away --demo-recording
  WAIT=9 ios 05d-break-ax "${S[@]}" --demo-phase break --demo-recording
  xcrun simctl ui $SIM content_size large >/dev/null 2>&1 || true
  rm -f $OUT/ios-warmup.png
  xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
  sleep 2  # let the text size reset reach the simulator's settings before it shuts down
  xcrun simctl shutdown $SIM >/dev/null 2>&1 || true
fi

if [[ $WHAT == all || $WHAT == mac ]]; then
  if ! $SKILL_SCRIPTS/lockcheck.sh >/dev/null; then
    echo "The screen is locked: no Mac shots. Never substitute in-app snapshots." >&2; exit 1
  fi
  MISSING=()
  mac() { # mac <name> <window title> [args…]
    local name=$1 title=$2 delay=${WAIT:-4} round; shift 2
    for round in 1 2; do
      if APP_BUNDLE=$MAC_DD/Build/Products/Debug/WaitingPaws.app DEMO_CAMERA=1 WAIT=$delay \
        Tools/ui-shot.sh $OUT/mac-$name.png "$title" -AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая" "$@" --retina
      then
        return 0
      fi
      delay=$((delay * 2))
    done
    MISSING+=(mac-$name)
  }
  mac 01-session "Тренировка на понедельник" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 2 --demo-phase away \
    --demo-session --demo-recording --demo-second-camera
  mac 02-plan "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-plan
  WAIT=5 mac 03-review "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-review
  mac 04-break "Тренировка на понедельник" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 3 --demo-break-left 70 \
    --demo-session --demo-recording
  WAIT=5 mac 05-history "История" -streamName hall --open history --demo-history
  WAIT=6 mac 06-finish "Прихожая" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 5 \
    --demo-phase finish --demo-session
  for n in 01-session 02-plan 03-review 04-break 05-history; do rm -f $OUT/mac-$n-2.png; done
  (( ${#MISSING} )) && echo "Not captured: ${MISSING[*]}" >&2
fi
exit 0
