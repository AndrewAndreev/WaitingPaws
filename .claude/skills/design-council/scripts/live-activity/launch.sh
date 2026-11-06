#!/bin/zsh
# Launch the Waiting Paws demo in the private simulator, in front: launch.sh [extra args…]
# PLAN=… another trainer's text; NOTIFY=1 lets the demo post its notifications.
set -euo pipefail
source ${0:A:h}/common.zsh
need_sim
DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
find $DATA -name "*.log" -path "*Logs*" -delete
xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
xcrun simctl terminate $SIM com.apple.Preferences >/dev/null 2>&1 || true; xcrun simctl terminate $SIM test.tapper.app >/dev/null 2>&1 || true
xcrun simctl launch --terminate-running-process $SIM su.comrade.waitingpaws -AppleLanguages "(ru)" -AppleLocale ru_RU \
  -cameraTitle "Прихожая" -streamName hall --ui-preview "--demo-camera=$DATA/tmp/demo-camera.jpg" \
  -demoPlanText "${PLAN:-$SESSION_RU}" --demo-live-activity ${NOTIFY:+--demo-notifications} "$@" >/dev/null
