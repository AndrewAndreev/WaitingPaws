#!/bin/zsh
# One state for the sheets: scene.sh <name> <seconds in front> [app args…] → $LA/shots/<name>-{app,compact,exp,lock}.png
# AFTER=… seconds in the background before the shots (a state that switches by itself while the app is suspended).
source ${0:A:h}/common.zsh
mkdir -p $LA/shots
name=$1 before=$2; shift 2
$LA_SCRIPTS/bg.sh $before "$@"
cp $LA/last-app.png $LA/shots/$name-app.png
sleep ${AFTER:-1.5}
$LA_SCRIPTS/tap.sh "shot:$LA/shots/$name-compact.png;island;sleep:1.3;shot:$LA/shots/$name-exp.png;home;sleep:1;lock;sleep:1.2;wake;sleep:2;shot:$LA/shots/$name-lock.png;home" | grep -E "fail|error"
$LA_SCRIPTS/log.sh > $LA/shots/$name.log
ls $LA/shots/$name-*.png | tr '\n' ' '; echo
