#!/bin/zsh
# App Store screenshots (iPhone 6.9" and Mac, English and Russian) and showcase pictures → docs/screenshots.
#
#   Tools/screenshots/make.sh            build, shoot both platforms, compose
#   Tools/screenshots/make.sh ios|mac    one platform only (then compose)
#   Tools/screenshots/make.sh compose    only recompose the raw shots already in /tmp/wp-shots/raw
#   Tools/screenshots/make.sh showcase <dir>   only the showcase pictures, as PNG into <dir> (Design/showcase-lab)
#
# WP_BG=<palette> picks the background (compose.swift); without it the chosen default. WP_DD (derived data), WP_SIM
# (simulator name) and WP_RAW (raw shots) keep a run apart from other sessions that use the default ones.
#
# Uses DEBUG launch arguments only (demo schedule, history, cameras, a still camera picture): nothing real is read
# or written. iPhone shots come from a separate simulator ("WP Screens", iPhone 17 Pro Max, clean 9:41 status bar);
# Mac shots from separate background copies of the app (Tools/ui-shot.sh with --retina, so they are 2× even when the
# main display is a 1× external monitor). Raw shots stay in /tmp/wp-shots/raw.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
DD=${WP_DD:-/tmp/wp-dd-S}
RAW=${WP_RAW:-/tmp/wp-shots/raw}
SIM_NAME=${WP_SIM:-WP Screens}
OUT=$ROOT/docs/screenshots
WHAT=${1:-all}
mkdir -p $RAW

if [[ $WHAT != compose && $WHAT != showcase ]]; then
  # The Mac welcome shot shows the version: the latest release's (its tag, Tools/release.sh) instead of "dev".
  VERSION=()
  if TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
    VERSION=(MARKETING_VERSION=${TAG#v} CURRENT_PROJECT_VERSION=${TAG##*.} WP_GIT_COMMIT=$(git rev-parse --short=7 "$TAG^{commit}"))
  fi
  xcodebuild -project WaitingPaws.xcodeproj -scheme WaitingPaws-iOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO "${VERSION[@]}" build -quiet
  xcodebuild -project WaitingPaws.xcodeproj -scheme WaitingPaws-macOS -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO "${VERSION[@]}" build -quiet
fi

# MARK: iPhone

# The schedule to check (plan and review shots) and the one being trained (session shots: exit 3 is under way, the
# break shot waits for exit 4). Both carry triggers («+ jacket») and conditions for coming back early (🟡/🟢).
PLAN_EN=$'🐶 Sunday training - Anna/Mark - 04.10.2026\n➡️ During breaks sit at the table and work\n➡️ All breaks 2 minutes\nExit 1 - 10 seconds\nExit 2 - 30 seconds + jacket\nExit 3 - 15 seconds\nExit 4 - 1 minute + take the keys\nExit 5 - 45 seconds\nExit 6 - 2 minutes OR until the dog stands up\n🟡 If she stands up and walks off - come back in 1 minute\n🟢 If she lies down - come back in 20 seconds\nBreak 5 minutes\nExit 7 - 30 seconds\nExit 8 - 3 minutes OR until the dog stands up'
PLAN_RU=$'🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026\n➡️ В перерывах сидите за столом, работаете\n➡️ Все перерывы 2 минуты\n1 выход - 10 секунд\n2 выход - 30 секунд + куртка\n3 выход - 15 секунд\n4 выход - 1 минута + взять ключи\n5 выход - 45 секунд\n6 выход - 2 минуты ИЛИ до вставания\n🟡 Если встала и пошла - входим через 1 минуту\n🟢 Если легла - входим через 20 секунд\nПерерыв 5 минут\n7 выход - 30 секунд\n8 выход - 3 минуты ИЛИ до вставания'
SESSION_EN=$'🐶 Monday training - Anna/Mark - 05.10.2026\n➡️ All breaks 2 minutes\nExit 1 - 15 seconds\nExit 2 - 30 seconds\nExit 3 - 1 minute + jacket\n🟡 If she stands up and walks off - come back in 30 seconds\n🟢 If she lies down - come back in 20 seconds\nExit 4 - 45 seconds + take the keys\nExit 5 - 2 minutes OR until the dog stands up'
SESSION_RU=$'🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 15 секунд\n2 выход - 30 секунд\n3 выход - 1 минута + куртка\n🟡 Если встала и пошла - входим через 30 секунд\n🟢 Если легла - входим через 20 секунд\n4 выход - 45 секунд + взять ключи\n5 выход - 2 минуты ИЛИ до вставания'

if [[ $WHAT == all || $WHAT == ios ]]; then
  SIM=$(xcrun simctl list devices | awk -F'[()]' -v name="    $SIM_NAME " 'index($0, name) == 1 {print $2; exit}')
  if [[ -z $SIM ]]; then
    RUNTIME=$(xcrun simctl list runtimes | awk '/iOS 26/ {print $NF}' | tail -1)
    SIM=$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max $RUNTIME)
  fi
  xcrun simctl boot $SIM 2>/dev/null || true
  xcrun simctl bootstatus $SIM -b >/dev/null
  xcrun simctl install $SIM $DD/Build/Products/Debug-iphonesimulator/WaitingPaws.app
  xcrun simctl status_bar $SIM override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName ""
  DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
  mkdir -p $DATA/tmp && cp Tools/demo-camera.jpg $DATA/tmp/

  ios() { # ios <lang> <name> [args…]
    local lang=$1 name=$2; shift 2
    local -a L
    if [[ $lang == ru ]]; then L=(-AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая")
    else L=(-AppleLanguages "(en)" -AppleLocale en_US -cameraTitle "Hallway"); fi
    xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
    xcrun simctl launch $SIM su.comrade.waitingpaws "${L[@]}" -streamName hall --ui-preview \
      "--demo-camera=$DATA/tmp/demo-camera.jpg" "$@" >/dev/null
    sleep ${WAIT:-7}
    xcrun simctl io $SIM screenshot $RAW/ios-$lang-$name.png >/dev/null 2>&1
    echo "ios-$lang-$name"
  }
  WAIT=12 ios en warmup   # the first launch of a fresh simulator is slow and may show system banners
  for lang in en ru; do
    if [[ $lang == en ]]; then plan=$PLAN_EN; session=$SESSION_EN; else plan=$PLAN_RU; session=$SESSION_RU; fi
    ios $lang 01-outside -demoPlanText "$session" --demo-session --demo-exits-done 2 --demo-phase away --demo-recording \
      --demo-second-camera
    ios $lang 02-plan --demo-screen plan --demo-parse -demoPlanText "$plan"
    # The iPhone's «--demo-phase break» does one more exit first: 2 done + 1 → the break before exit 4 (the Mac's 3).
    WAIT=9 ios $lang 03-break -demoPlanText "$session" --demo-session --demo-exits-done 2 --demo-phase break --demo-recording
    ios $lang 04-log --demo-history --demo-screen history-last
    ios $lang 05-history --demo-history --demo-screen history
    ios $lang 06-home --demo-history
    ios $lang 07-record --demo-recording
    WAIT=9 ios $lang 08-cameras --demo-cameras --demo-screen camera
  done
  xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
  # Shut down, so that `simctl … booted` in other tools never lands in this simulator.
  xcrun simctl shutdown $SIM >/dev/null 2>&1 || true
fi

# MARK: Mac

if [[ $WHAT == all || $WHAT == mac ]]; then
  # AppKit reads launch arguments as "-key value" pairs: a lone value (e.g. the "2" of a misplaced
  # "--demo-exits-done 2") is opened as a document and the app shows no window. Valued flags come first.
  mac() { # mac <lang> <name> <window title> [args…]
    local lang=$1 name=$2 title=$3; shift 3
    local -a L
    if [[ $lang == ru ]]; then L=(-AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая")
    else L=(-AppleLanguages "(en)" -AppleLocale en_US -cameraTitle "Hallway"); fi
    APP_BUNDLE=$DD/Build/Products/Debug/WaitingPaws.app DEMO_CAMERA=1 WAIT=${WAIT:-4} \
      Tools/ui-shot.sh $RAW/mac-$lang-$name.png "$title" "${L[@]}" "$@" --retina
  }
  for lang in en ru; do
    if [[ $lang == en ]]; then t1="Monday training"; t2="Sunday training"; th=History; ts=Camera; tw=Welcome
      plan=$PLAN_EN; session=$SESSION_EN
    else t1="Тренировка на понедельник"; t2="Тренировка на воскресенье"; th=История; ts=Камера; tw="Добро пожаловать"
      plan=$PLAN_RU; session=$SESSION_RU; fi
    mac $lang m01-session "$t1" -streamName hall -demoPlanText "$session" --demo-exits-done 2 --demo-phase away \
      --demo-session --demo-recording --demo-second-camera
    mac $lang m02-plan "$t2" -streamName hall -demoPlanText "$plan" --demo-plan
    WAIT=5 mac $lang m03-review "$t2" -streamName hall -demoPlanText "$plan" --demo-review   # -2: the window with its sheet
    mac $lang m04-break "$t1" -streamName hall -demoPlanText "$session" --demo-exits-done 3 --demo-break-left 70 \
      --demo-session --demo-recording
    WAIT=5 mac $lang m05-history "$th" -streamName hall --open history --demo-history
    WAIT=5 mac $lang m06-settings "$ts" --open settings --demo-pane camera --demo-cameras
    WAIT=5 mac $lang m07-welcome "$tw" --demo-cameras --preview-unconfigured
  done
fi

# MARK: Compose

swiftc -O Tools/screenshots/compose.swift -o /tmp/wp-compose

# The README pictures: <dir>/iphone-<lang>.png and mac-<lang>.png.
showcase() {
  local dir=$1
  mkdir -p $dir
  /tmp/wp-compose showcase-ios $dir/iphone-en.png "Separation training, one tap per step" \
    "Your trainer’s schedule, exit and break timers, a live camera while you’re outside, and a log for the trainer." \
    $RAW/ios-en-02-plan.png $RAW/ios-en-01-outside.png $RAW/ios-en-04-log.png
  /tmp/wp-compose showcase-ios $dir/iphone-ru.png "Тренировка выходов — шаг за шагом" \
    "Расписание тренера, таймеры выходов и перерывов, камера, пока вы за дверью, и лог для тренера." \
    $RAW/ios-ru-02-plan.png $RAW/ios-ru-01-outside.png $RAW/ios-ru-04-log.png
  /tmp/wp-compose showcase-mac $dir/mac-en.png "Mac and iPhone together" \
    $'The Mac keeps the camera, the timeline and the recording.\nThe iPhone in your hand drives the same training from behind the door.' \
    $RAW/mac-en-m01-session.png $RAW/ios-en-01-outside.png
  /tmp/wp-compose showcase-mac $dir/mac-ru.png "Mac и iPhone вместе" \
    "На Mac — камера, таймлайн и запись. iPhone в руке ведёт ту же тренировку из-за двери." \
    $RAW/mac-ru-m01-session.png $RAW/ios-ru-01-outside.png
}
if [[ $WHAT == showcase ]]; then
  showcase ${2:?usage: make.sh showcase <dir>}
  exit
fi

jpeg() { magick "$1" -alpha off -quality 92 -sampling-factor 4:4:4 "${1%.png}.jpg" && rm "$1"; }
rm -rf $OUT && mkdir -p $OUT
for lang in en ru; do
  mkdir -p $OUT/app-store/$lang/iphone-6.9 $OUT/app-store/$lang/mac
  for name in 01-outside 02-plan 03-break 04-log 05-history 06-home 07-record 08-cameras; do
    cp $RAW/ios-$lang-$name.png $OUT/app-store/$lang/iphone-6.9/$name.png
  done
  for pair in 01-session:m01-session 02-plan:m02-plan 03-review:m03-review-2 04-break:m04-break \
              05-history:m05-history 06-settings:m06-settings 07-welcome:m07-welcome; do
    /tmp/wp-compose mac-store $OUT/app-store/$lang/mac/${pair%%:*}.png $RAW/mac-$lang-${pair##*:}.png
  done
done
showcase $OUT/showcase
for file in $OUT/**/*.png; do jpeg $file; done
echo "Wrote $(find $OUT -name '*.jpg' | wc -l | tr -d ' ') images to docs/screenshots"
