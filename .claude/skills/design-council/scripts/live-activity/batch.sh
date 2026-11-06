#!/bin/zsh
# Round 13: every state left for the sheets (compact, expanded, lock), the ones that switch by themselves while the
# app is suspended, and the notifications.
S=(--demo-session --demo-exits-done 2)
PLAN_MAC=$'🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 1 минута\n2 выход - 30 секунд\n3 выход - 1 минута + куртка\n🟡 Если встала и пошла - входим через 30 секунд\n🟢 Если легла - входим через 20 секунд\n4 выход - 45 секунд + взять ключи\n5 выход - 2 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'
if [[ ${1:-scenes} == scenes || ${1:-} == all ]]; then
$LA_SCRIPTS/scene.sh a-away 3 $S --demo-phase away
$LA_SCRIPTS/scene.sh b-over 20 --demo-session --demo-exits-done 0 --demo-phase away
$LA_SCRIPTS/scene.sh g-break 4 --demo-session --demo-exits-done 3 --demo-break-left 110
$LA_SCRIPTS/scene.sh g2-break-plain 4 --demo-session --demo-exits-done 4 --demo-break-left 100
$LA_SCRIPTS/scene.sh g3-last-break 4 --demo-session --demo-exits-done 5 --demo-break-left 100
$LA_SCRIPTS/scene.sh h-breakover 4 --demo-session --demo-exits-done 3 --demo-break-over 20
PLAN=$PLAN_MAC $LA_SCRIPTS/scene.sh i-mac 8 --demo-mac-session --demo-remote-steps
PLAN=$PLAN_MAC $LA_SCRIPTS/scene.sh i2-mac-stale 8 --demo-mac-session --demo-remote-steps --demo-live-stale
PLAN=$PLAN_MAC $LA_SCRIPTS/scene.sh j-maclost 8 --demo-mac-session --demo-remote-steps --demo-live-link-lost
fi
if [[ ${1:-} == switch || ${1:-} == all ]]; then
# Exit 3 (1 min) runs out ~60 s after launch; the app is suspended after ~33 s: the card turns by itself.
AFTER=64 $LA_SCRIPTS/scene.sh k-timeup 3 $S --demo-phase away
# A Mac's training: exit 1 (1 min) runs out after the suspension; «с Mac в …» comes as the app is about to sleep.
PLAN=$PLAN_MAC AFTER=58 $LA_SCRIPTS/scene.sh m-mac-timeup 8 --demo-mac-session --demo-remote-steps
fi
if [[ ${1:-} == notify || ${1:-} == all ]]; then
$LA_SCRIPTS/notify.sh n1-plan 62 $S --demo-phase away
$LA_SCRIPTS/notify.sh n2-break 30 --demo-session --demo-exits-done 3 --demo-break-left 14
PLAN=$PLAN_MAC $LA_SCRIPTS/notify.sh n3-maclost 62 --demo-mac-session --demo-remote-steps --demo-live-link-lost
fi
echo done
