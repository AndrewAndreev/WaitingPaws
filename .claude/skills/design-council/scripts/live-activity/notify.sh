#!/bin/zsh
# A notification on the lock screen under the Live Activity: notify.sh <name> <seconds locked before waking> [app args…]
# The app goes to the background, the iPhone is locked, the timer runs out (the notification comes), then it is woken.
source ${0:A:h}/common.zsh
mkdir -p $LA/shots
name=$1 wait=$2; shift 2
NOTIFY=1 $LA_SCRIPTS/bg.sh 2 "$@"
$LA_SCRIPTS/tap.sh "home;sleep:0.5;lock;sleep:$wait;wake;sleep:2;shot:$LA/shots/$name.png;home" | grep -E "fail|error"
$LA_SCRIPTS/log.sh > $LA/shots/$name.log
date +%T; cat $LA/shots/$name.log
