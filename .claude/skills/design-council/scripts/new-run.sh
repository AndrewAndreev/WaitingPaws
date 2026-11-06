#!/bin/zsh
# A new council run, outside the repository: new-run.sh <slug> [criterion text]
#   → ${COUNCIL_HOME:-~/projects/WaitingPaws-design-history}/<YYYY-MM-DD>-<slug>/ with
#     criterion.md   the achievement criterion, verbatim (the default from SKILL.md when none is given)
#     council.json   the run's settings for report.py / build.py (templates/council.json)
#     refs/          an APFS clone of the last run's references (REFS_FROM=… for others; never commit them)
#     final/         rounds.json and sections.py to fill in; main/ gets the base build's shots (capture-pair.sh)
#     round-1/       the first round's folder
# Prints the folder; use it as COUNCIL for every other script.
set -euo pipefail
source ${0:A:h}/common.zsh
SKILL=${SKILL_SCRIPTS:h}
HOME_DIR=${COUNCIL_HOME:-$HOME/projects/WaitingPaws-design-history}
SLUG=${1:?slug, e.g. minimal-mac}
RUN=$HOME_DIR/$(date +%F)-$SLUG
[[ -e $RUN ]] && { echo "$RUN already exists" >&2; exit 1; }
mkdir -p $RUN/final $RUN/round-1
if [[ -n ${2:-} ]]; then
  print -r -- "$2" > $RUN/criterion.md
else
  sed -n '/^<!-- default-criterion -->$/,/^<!-- \/default-criterion -->$/p' $SKILL/SKILL.md | sed '1d;$d' > $RUN/criterion.md
fi
cp $SKILL/templates/council.json $RUN/council.json
cp $SKILL/templates/rounds.json $RUN/final/rounds.json
cp $SKILL/templates/sections.py $RUN/final/sections.py
previous=($HOME_DIR/*/refs(N/))
REFS_FROM=${REFS_FROM:-${previous[-1]:-}}
if [[ -n $REFS_FROM && -d $REFS_FROM ]]; then
  cp -cR ${REFS_FROM%/} $RUN/refs
else
  mkdir -p $RUN/refs
  echo "No references to clone: fetch them (reference/pipeline.md, «References»)." >&2
fi
print -r -- $RUN
