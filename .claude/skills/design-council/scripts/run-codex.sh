#!/bin/zsh
# The GPT delegate of the design council: codex exec, read-only, with retries on 429.
#   COUNCIL=<run> run-codex.sh round-N        (or an absolute round folder)
# CODEX_MODEL (gpt-6-astra) picks the model; the report goes to round-N/<CODEX_NAME:-$CODEX_MODEL>.md, the log next to it.
set -u
source ${0:A:h}/common.zsh
need_council
ROUND=$(council_path ${1:?round dir})
MODEL=${CODEX_MODEL:-gpt-6-astra}; NAME=${CODEX_NAME:-$MODEL}
OUT=$ROUND/$NAME.md
LOG=$ROUND/$NAME.log
REFS=${REFS:-$COUNCIL/refs}
IMAGES=()
WP=$ROUND/wp; [[ -d $WP ]] || WP=$COUNCIL/wp
for f in $ROUND/sheets/*.jpg(N) $WP/*.png(N); do IMAGES+=(-i "$f"); done
PROMPT="Ты эксперт консилиума по UI/UX. Полный бриф ниже (он же лежит в $ROUND/brief.md). К сообщению приложены листы сравнения по кейсам (c0…c7) и оригиналы скриншотов Waiting Paws ($WP/*.png). Оригиналы референсов лежат в $REFS/ — открой их, если нужно рассмотреть детали. Код приложения — в $REPO (рабочая папка). Ответ — только итоговый отчёт в формате из брифа.

$(cat $ROUND/brief.md)"
cd $REPO
for attempt in 1 2 3 4 5 6; do
  echo "attempt $attempt $(date +%T)" >> $LOG
  codex exec -m $MODEL -s read-only --skip-git-repo-check -C "$REPO" "${IMAGES[@]}" -o $OUT "$PROMPT" < /dev/null >> $LOG 2>&1
  if [[ -s $OUT ]] && grep -q 'OVERALL_SCORE' $OUT; then echo "done $(date +%T)" >> $LOG; exit 0; fi
  echo "no report, waiting 180 s" >> $LOG
  sleep 180
done
echo "gave up" >> $LOG
exit 1
