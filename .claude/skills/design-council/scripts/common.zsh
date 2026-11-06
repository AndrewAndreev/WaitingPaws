# Shared by the council scripts (sourced): where the Waiting Paws checkout and the council run are.
#   WP_REPO  the checkout (default: the repository this skill lives in)
#   COUNCIL  the run folder, e.g. ~/projects/WaitingPaws-design-history/2026-11-council (never inside the repo)
SKILL_SCRIPTS=${${(%):-%x}:A:h}
REPO=${WP_REPO:-$(git -C $SKILL_SCRIPTS rev-parse --show-toplevel)}
# A path given to a script: absolute as is, else inside $COUNCIL (the current folder when COUNCIL is not set).
council_path() { [[ $1 == /* ]] && print -r -- $1 || print -r -- ${COUNCIL:-$PWD}/$1; }
need_council() {
  [[ -n ${COUNCIL:-} && -d $COUNCIL ]] || { echo "Set COUNCIL to the run folder (see SKILL.md)." >&2; exit 2; }
}
