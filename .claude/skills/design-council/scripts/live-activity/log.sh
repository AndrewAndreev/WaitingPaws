#!/bin/zsh
# The app's own log lines about the Live Activity: log.sh [regex]
source ${0:A:h}/common.zsh
need_sim
DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
find $DATA -name "*.log" -path "*Logs*" -exec cat {} + | grep -E "${1:-\[live\]|\[glance\]|\[app\]}"
