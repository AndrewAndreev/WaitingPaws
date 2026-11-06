#!/bin/zsh
# SpringBoard steps through the tapper (setup.sh builds it): tap.sh "lock;sleep:1;wake;tap:Вернулись"
# Steps: lock, wake, home, sleep:<s>, island (long press), nc, tap:<button>, tapany:<label>, swipeleft:<label>,
# apptap:<label>, appswipeup, shot:<png>, dump, appdump. xcodebuild hands TEST_RUNNER_STEPS to the test as STEPS.
source ${0:A:h}/common.zsh
need_sim
XCTESTRUN=$(ls $LA/tapper-dd/Build/Products/*.xctestrun | head -1)
mkdir -p $LA/xcr
TEST_RUNNER_STEPS="$1" xcodebuild test-without-building -xctestrun $XCTESTRUN \
  -destination "id=$SIM" -resultBundlePath $LA/xcr/r-$(date +%s)-$RANDOM.xcresult 2>&1 | grep -E "\[tapper\]|error|failed|passed|Test Case" | grep -v "^$" | head -${LINES_MAX:-40}
