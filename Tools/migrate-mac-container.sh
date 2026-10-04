#!/bin/zsh
# One-time move of the Mac app's data after its bundle id changed from su.comrade.waitingpaws.mac to
# su.comrade.waitingpaws (one App Store record for iPhone and Mac). Copies history, recordings, the go2rtc
# config (Xiaomi sign-in, streams) and the settings into the new sandbox container; the old one is left as is.
#
#   1. Run the new build once (it creates the new container), then quit it.
#   2. Tools/migrate-mac-container.sh   (macOS may ask to allow Terminal to access another app's data)
#   3. Start the app again.
set -euo pipefail
OLD=~/Library/Containers/su.comrade.waitingpaws.mac/Data
NEW=~/Library/Containers/su.comrade.waitingpaws/Data
[[ -d $OLD ]] || { echo "Nothing to move: $OLD does not exist"; exit 0; }
[[ -d $NEW ]] || { echo "Start the new build once first (it creates $NEW), quit it, then run this again"; exit 1; }
pgrep -f "/WaitingPaws.app/Contents/MacOS/WaitingPaws" >/dev/null && { echo "Quit Waiting Paws first"; exit 1; }

mkdir -p "$NEW/Documents" "$NEW/Library/Application Support"
rsync -a "$OLD/Documents/" "$NEW/Documents/"
rsync -a "$OLD/Library/Application Support/go2rtc" "$NEW/Library/Application Support/"
# Settings: through cfprefsd (it caches preferences), into the new domain's file.
if [[ -f "$OLD/Library/Preferences/su.comrade.waitingpaws.mac.plist" ]]; then
  defaults export "$OLD/Library/Preferences/su.comrade.waitingpaws.mac.plist" - \
    | defaults import "$NEW/Library/Preferences/su.comrade.waitingpaws.plist" -
fi
echo "Moved history, recordings, go2rtc config and settings to the new container."
