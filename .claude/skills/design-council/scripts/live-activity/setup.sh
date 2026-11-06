#!/bin/zsh
# A private simulator for the Live Activity shots, the app installed, and the SpringBoard tapper built.
#   LA=/tmp/wp-live/rN setup.sh [iOS derived data]      (default $DD or /tmp/wp-dd-S)
# The sheets' crops are measured on an iPhone 17 Pro (1206×2622) with iOS 26: keep that device. Russian system
# language, so the lock screen and notifications read like the app.
set -euo pipefail
source ${0:A:h}/common.zsh
DD=${1:-${DD:-/tmp/wp-dd-S}}
if [[ -z $SIM ]] || ! xcrun simctl list devices | grep -q $SIM; then
  RUNTIME=$(xcrun simctl list runtimes | awk '/iOS 26/ {print $NF}' | tail -1)
  SIM=$(xcrun simctl create "WP Live ${LA:t}" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro $RUNTIME)
  print -r -- $SIM > $LA/sim
  xcrun simctl boot $SIM; xcrun simctl bootstatus $SIM -b >/dev/null
  xcrun simctl spawn $SIM defaults write -g AppleLanguages -array ru
  xcrun simctl spawn $SIM defaults write -g AppleLocale ru_RU
  xcrun simctl shutdown $SIM
fi
xcrun simctl boot $SIM 2>/dev/null || true
xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $DD/Build/Products/Debug-iphonesimulator/WaitingPaws.app
DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
mkdir -p $DATA/tmp && cp $REPO/Tools/demo-camera.jpg $DATA/tmp/
# The tapper: a UI-test bundle that presses lock/home, long-presses the island and takes screenshots
# (simctl screenshots often catch the Dynamic Island hidden).
if [[ -z $(print -l $LA/tapper-dd/Build/Products/*.xctestrun(N)) ]]; then
  rm -rf $LA/tapper && cp -R $LA_SCRIPTS/tapper $LA/tapper
  (cd $LA/tapper && xcodegen generate --quiet && xcodebuild build-for-testing -project Tapper.xcodeproj -scheme Tapper \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath $LA/tapper-dd -quiet 2>&1 | grep -E 'error' || true)
fi
ls $LA/tapper-dd/Build/Products/*.xctestrun
echo "simulator $SIM ready in $LA"
