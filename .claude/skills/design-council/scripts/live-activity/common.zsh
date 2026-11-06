# Shared by the Live Activity scripts (sourced). LA is the working folder (shots/, sheet/, the tapper build, the
# simulator's id in LA/sim); one per round keeps rounds apart: LA=/tmp/wp-live/r7.
LA_SCRIPTS=${${(%):-%x}:A:h}
source $LA_SCRIPTS/../common.zsh
LA=${LA:-/tmp/wp-live/current}
mkdir -p $LA
SIM=$( [[ -s $LA/sim ]] && cat $LA/sim || true )
SESSION_RU=$'🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 15 секунд\n2 выход - 30 секунд\n3 выход - 1 минута + куртка\n🟡 Если встала и пошла - входим через 30 секунд\n🟢 Если легла - входим через 20 секунд\n4 выход - 45 секунд + взять ключи\n5 выход - 2 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'
need_sim() { [[ -n $SIM ]] || { echo "No simulator in $LA/sim: run setup.sh first." >&2; exit 2; }; }
