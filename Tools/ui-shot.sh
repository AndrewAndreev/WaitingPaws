#!/bin/zsh
# Screenshot of the Mac app's own windows without touching a copy of the app that is already running:
#   Tools/ui-shot.sh /tmp/history.png "История" --demo-history --open history
#   DEMO_CAMERA=1 Tools/ui-shot.sh /tmp/console.png "Waiting Paws" --demo-plan
# Launches this checkout's Debug build as a separate instance in the background (`open -n -g`, no focus
# stealing) with --ui-preview (no go2rtc, no iPhone link, temp history). DEMO_CAMERA=1 adds a still
# camera picture (Tools/demo-camera.jpg, copied into the app's sandbox). Every window of THAT process is
# captured window-only (no other apps in the picture): the one whose title contains <title> → <out>.png,
# the others (sheets, panels) → <out>-2.png, -3…; then the instance quits. App log: /tmp/wp-ui-shot.log.
set -e
OUT=$1; TITLE=$2; shift 2
cd "$(dirname "$0")/.."
BUNDLE="$PWD/${APP_BUNDLE:-DerivedData/Build/Products/Debug/WaitingPaws.app}"
WINLIST=/tmp/wp-winlist
[[ -x $WINLIST ]] || swiftc -O Tools/winlist.swift -o $WINLIST
EXTRA=()
if [[ -n "$DEMO_CAMERA" ]]; then
  CONTAINER_TMP=~/Library/Containers/su.comrade.waitingpaws.mac/Data/tmp
  mkdir -p $CONTAINER_TMP && cp Tools/demo-camera.jpg $CONTAINER_TMP/demo-camera.jpg
  EXTRA=(--demo-camera=$CONTAINER_TMP/demo-camera.jpg)
fi
pkill -f "$BUNDLE/Contents/MacOS/WaitingPaws" 2>/dev/null && sleep 1 || true
open -n -g --stdout /tmp/wp-ui-shot.log --stderr /tmp/wp-ui-shot.log "$BUNDLE" --args -ApplePersistenceIgnoreState YES --ui-preview "${EXTRA[@]}" "$@"
sleep 1
PID=$(pgrep -nf "$BUNDLE/Contents/MacOS/WaitingPaws")
sleep ${WAIT:-4}
N=2
FOUND=0
# The window titled exactly <title> wins; otherwise the first one that contains it.
TARGET=$($WINLIST $PID | awk -F'\t' -v t="$TITLE" '$3 == t {print $1; exit}')
[[ -z "$TARGET" ]] && TARGET=$($WINLIST $PID | awk -F'\t' -v t="$TITLE" 'index($3, t) {print $1; exit}')
while IFS=$'\t' read -r WID SIZE WTITLE; do
  [[ -z "$WID" ]] && continue
  if [[ $FOUND == 0 && "$WID" == "$TARGET" ]]; then
    screencapture -x -o -l "$WID" "$OUT"; FOUND=1; echo "window '$WTITLE' $SIZE → $OUT"
  else
    screencapture -x -o -l "$WID" "${OUT%.png}-$N.png"; echo "window '$WTITLE' $SIZE → ${OUT%.png}-$N.png"; N=$((N+1))
  fi
done < <($WINLIST $PID)
kill $PID 2>/dev/null || true
[[ $FOUND == 1 ]] || { echo "no window with '$TITLE' in the title"; exit 1; }
