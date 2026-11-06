#!/bin/zsh
# Launch the demo in front, wait, then send it to the background (Settings in front): bg.sh <seconds in front> [args…]
source ${0:A:h}/common.zsh
need_sim
before=$1; shift
$LA_SCRIPTS/launch.sh "$@"
sleep $before
xcrun simctl io $SIM screenshot $LA/last-app.png >/dev/null 2>&1
xcrun simctl launch $SIM ${FRONT:-com.apple.Preferences} >/dev/null
