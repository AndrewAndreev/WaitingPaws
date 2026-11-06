#!/bin/zsh
# Fresh Waiting Paws screenshots for the design council (Russian UI), same recipe as Tools/screenshots/make.sh,
# written to the run folder and never touching docs/screenshots.
#   COUNCIL=<run> capture.sh <out dir> [ios|mac|all]
#   <out dir>: absolute, or inside $COUNCIL (e.g. round-3/wp). Builds are read from $DD (/tmp/wp-dd-S by default);
#   MAC_DD=… for a Mac build elsewhere; SIM_NAME=… for an iPhone simulator other than «WP Screens» (made if missing).
set -euo pipefail
source ${0:A:h}/common.zsh
OUT=$(council_path ${1:?out dir})
cd $REPO
DD=${DD:-/tmp/wp-dd-S}
WHAT=${2:-all}
mkdir -p $OUT
PLAN_RU=$'🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026\n➡️ В перерывах сидите за столом, работаете\n➡️ Все перерывы 2 минуты\n1 выход - 10 секунд\n2 выход - 30 секунд + куртка\n3 выход - 15 секунд\n4 выход - 1 минута + взять ключи\n5 выход - 45 секунд\n6 выход - 2 минуты ИЛИ до вставания\n🟡 Если встала и пошла - входим через 1 минуту\n🟢 Если легла - входим через 20 секунд\nПерерыв 5 минут\n7 выход - 30 секунд\n8 выход - 3 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'
SESSION_RU=$'🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 15 секунд\n2 выход - 30 секунд\n3 выход - 1 минута + куртка\n🟡 Если встала и пошла - входим через 30 секунд\n🟢 Если легла - входим через 20 секунд\n4 выход - 45 секунд + взять ключи\n5 выход - 2 минуты ИЛИ до вставания\n🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд'

if [[ $WHAT == all || $WHAT == ios ]]; then
  # SIM_NAME=…: another simulator of the same kind (a helper's own, so «WP Screens» is left alone).
  SIM_NAME=${SIM_NAME:-WP Screens}
  SIM=$(xcrun simctl list devices | awk -F'[()]' -v name="$SIM_NAME" 'index($0, "    " name " (") == 1 {print $2; exit}')
  if [[ -z $SIM ]]; then
    RUNTIME=$(xcrun simctl list runtimes | awk '/iOS 26/ {print $NF}' | tail -1)
    SIM=$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max $RUNTIME)
  fi
  xcrun simctl boot $SIM 2>/dev/null || true
  xcrun simctl bootstatus $SIM -b >/dev/null
  # The text size of an earlier run may outlive a shutdown that came too soon after its reset: start from the
  # default every time.
  xcrun simctl ui $SIM content_size large >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl install $SIM $DD/Build/Products/Debug-iphonesimulator/WaitingPaws.app
  xcrun simctl status_bar $SIM override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName ""
  DATA=$(xcrun simctl get_app_container $SIM su.comrade.waitingpaws data)
  mkdir -p $DATA/tmp && cp Tools/demo-camera.jpg $DATA/tmp/
  # A framing remembered from an earlier run (--demo-zoom) would zoom every shot.
  xcrun simctl spawn $SIM defaults delete "$DATA/Library/Preferences/su.comrade.waitingpaws" cameraFraming >/dev/null 2>&1 || true
  ios() { # ios <name> [args…]
    local name=$1; shift
    xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
    xcrun simctl launch $SIM su.comrade.waitingpaws -AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая" \
      -streamName hall --ui-preview "--demo-camera=$DATA/tmp/demo-camera.jpg" "$@" >/dev/null
    sleep ${WAIT:-7}
    xcrun simctl io $SIM screenshot $OUT/ios-$name.png >/dev/null 2>&1
    echo "ios-$name"
  }
  # Two videos of the demo camera's still for the history's video shots, as long as the newest sample training's
  # two recorded parts around its 2:10 break (`--demo-recording-gap`: 10:20 and 12:36): ffmpeg, else AVFoundation.
  # Made once and kept; silent AAC sound, or the app would rewrite a video without it on opening it.
  VIDEOS=/tmp/wp-demo-videos
  demo_videos() {
    mkdir -p $VIDEOS
    local name seconds
    for name seconds in demo-1 620 demo-2 756; do
      [[ -s $VIDEOS/$name.mp4 ]] && continue
      if command -v ffmpeg >/dev/null; then
        ffmpeg -loglevel error -y -loop 1 -framerate 1 -i Tools/demo-camera.jpg -f lavfi -i anullsrc=r=16000:cl=mono \
          -t $seconds -vf 'scale=1280:-2,format=yuv420p' -c:v libx264 -preset veryfast -tune stillimage -crf 26 -g 120 \
          -c:a aac -b:a 12k -shortest -movflags +faststart $VIDEOS/$name-part.mp4
      else
        [[ -x $VIDEOS/still ]] || demo_still_tool
        $VIDEOS/still Tools/demo-camera.jpg $VIDEOS/$name-part.mp4 $seconds
      fi
      mv $VIDEOS/$name-part.mp4 $VIDEOS/$name.mp4
    done
  }
  # Without ffmpeg: `still <image> <out.mp4> <seconds>`, the image as H.264 at a frame a second (no sound).
  demo_still_tool() {
    cat > $VIDEOS/still.swift <<'SWIFT'
import AVFoundation
import AppKit
let args = CommandLine.arguments
guard args.count == 4, let image = NSImage(contentsOfFile: args[1]), let seconds = Int(args[3]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(2) }
let width = 1280, height = Int((Double(cg.height) * 640 / Double(cg.width)).rounded()) * 2
let url = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000, AVVideoMaxKeyFrameIntervalKey: 120]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
var frame: CVPixelBuffer?
CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &frame)
guard let frame else { exit(1) }
CVPixelBufferLockBaseAddress(frame, [])
CGContext(data: CVPixelBufferGetBaseAddress(frame), width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
CVPixelBufferUnlockBaseAddress(frame, [])
for second in 0..<seconds {
  while !input.isReadyForMoreMediaData { usleep(2000) }
  adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
exit(writer.status == .completed ? 0 : 1)
SWIFT
    swiftc -O $VIDEOS/still.swift -o $VIDEOS/still
  }
  S=(-demoPlanText "$SESSION_RU" --demo-session --demo-exits-done 2)
  WAIT=12 ios warmup
  ios 01-home --demo-history
  ios 02-plan-review --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU"
  ios 03-away "${S[@]}" --demo-phase away --demo-recording --demo-second-camera
  # A tap on the big number: the small stopwatch beside it (no condition, no other control); past the plan («+0:16»,
  # the exit started 76 s ago: a mark flag with no such condition only moves the start back).
  ios 03k-away-stopwatch "${S[@]}" --demo-phase away --demo-recording --demo-stopwatch 7
  ios 03l-away-overdue "${S[@]}" --demo-phase away --demo-recording --demo-mark 9 --demo-mark-ago 70
  WAIT=9 ios 05-break "${S[@]}" --demo-phase break --demo-recording
  # Before the first exit, and the break after the last one («Ещё выход» / «Завершить»).
  ios 05f-ready -demoPlanText "$SESSION_RU" --demo-session --demo-recording
  WAIT=9 ios 05h-last-break -demoPlanText "$SESSION_RU" --demo-session --demo-exits-done 4 --demo-phase break --demo-recording
  ios 05b-false-start-undo "${S[@]}" --demo-phase away --demo-recording --demo-false-start
  WAIT=9 ios 06-trainer-text "${S[@]}" --demo-phase away --demo-recording --demo-trainer-text
  ios 07-log --demo-history --demo-screen history-last
  ios 07b-log-bottom --demo-history --demo-screen history-last --demo-scroll-bottom
  ios 08-history --demo-history --demo-screen history
  ios 08b-history-edit --demo-history --demo-screen history --demo-history-select 2
  # The history's videos, on disk only for these two shots (no stray recordings in the others): 07d the newest
  # training recorded in two parts (`--demo-recording-gap`: demo-1.mp4, a 2:10 break, demo-2.mp4) with the way to the
  # first; 08c the rows' signs (▶, ▶ in parts, ▶ on the Mac, none for the log alone), the progress card folded.
  REC=$DATA/tmp/WaitingPawsPreview/Recordings
  demo_videos
  mkdir -p $REC && cp $VIDEOS/demo-1.mp4 $VIDEOS/demo-2.mp4 $REC/
  WAIT=9 ios 07d-log-video-gap --demo-history --demo-screen history-last --demo-scroll-bottom --demo-recording-gap
  ios 08c-history-recordings --demo-history --demo-screen history --demo-history-recordings -historyProgressCollapsed YES
  rm -f $REC/demo-1.mp4 $REC/demo-2.mp4
  WAIT=9 ios 09-cameras --demo-cameras --demo-screen camera -streamName prihozhaya
  WAIT=9 ios 10-finish -demoPlanText "$SESSION_RU" --demo-session --demo-exits-done 5 --demo-phase finish
  ios 03g-away-no-frame "${S[@]}" --demo-phase away --demo-recording --demo-stream=stalled
  # Larger system text (Dynamic Type), then back.
  xcrun simctl ui $SIM content_size extra-extra-large >/dev/null 2>&1 || true
  ios 03h-away-large-text "${S[@]}" --demo-phase away --demo-recording
  # Accessibility sizes: the card's stacked layout (round 10).
  xcrun simctl ui $SIM content_size accessibility-extra-large >/dev/null 2>&1 || true
  ios 03i-away-ax "${S[@]}" --demo-phase away --demo-recording
  WAIT=9 ios 05d-break-ax "${S[@]}" --demo-phase break --demo-recording --demo-false-start
  WAIT=9 ios 05e-break-ax "${S[@]}" --demo-phase break --demo-recording
  xcrun simctl ui $SIM content_size large >/dev/null 2>&1 || true
  ios 02b-plan-end --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU" --demo-plan-end
  WAIT=8 ios 02c-plan-source --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU" --demo-plan-source
  # The trainer's words beside what came of them: exit 6's editor, and the owner's changes struck through.
  ios 02e-exit-editor --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU" --demo-exit-editor 6
  ios 02f-plan-changed --demo-screen plan --demo-parse -demoPlanText "$PLAN_RU" --demo-plan-changed --demo-plan-end
  WAIT=9 ios 05c-break-false-start "${S[@]}" --demo-phase break --demo-recording --demo-false-start
  # Last: the owner's framing is remembered, so it would follow into the other shots.
  ios 03f-away-zoomed "${S[@]}" --demo-phase away --demo-recording --demo-zoom=fill
  xcrun simctl spawn $SIM defaults delete "$DATA/Library/Preferences/su.comrade.waitingpaws" cameraFraming >/dev/null 2>&1 || true
  rm -f $OUT/ios-warmup.png
  xcrun simctl terminate $SIM su.comrade.waitingpaws >/dev/null 2>&1 || true
  sleep 2  # let the text size reset reach the simulator's settings before it shuts down
  xcrun simctl shutdown $SIM >/dev/null 2>&1 || true
fi

if [[ $WHAT == all || $WHAT == mac ]]; then
  # The Mac build may live elsewhere (MAC_DD=/tmp/wp-dd-mac). Window captures of a locked screen come out empty:
  # check first (lockcheck.sh), and say so instead of saving blank pictures.
  MAC_DD=${MAC_DD:-$DD}
  if ! $SKILL_SCRIPTS/lockcheck.sh >/dev/null; then
    echo "The screen is locked: no Mac shots (unlock it and run again with 'mac'). Never substitute in-app snapshots." >&2
    exit 1
  fi
  MISSING=()
  # AppKit reads launch arguments as "-key value" pairs: valued flags first (see Tools/screenshots/make.sh).
  # One shot never stops the run: a window that is late gets one more try with twice the wait, then it is listed.
  mac() { # mac <name> <window title> [args…]
    local name=$1 title=$2 delay=${WAIT:-4} round; shift 2
    for round in 1 2; do
      if APP_BUNDLE=$MAC_DD/Build/Products/Debug/WaitingPaws.app DEMO_CAMERA=1 WAIT=$delay \
        Tools/ui-shot.sh $OUT/mac-$name.png "$title" -AppleLanguages "(ru)" -AppleLocale ru_RU -cameraTitle "Прихожая" "$@" --retina
      then
        return 0
      fi
      delay=$((delay * 2))
    done
    MISSING+=(mac-$name)
  }
  # Window titles: a running training is the plan's title, a pasted one before the start too; after
  # `--demo-phase finish` the window is back to the camera's name, its summary sheet → mac-06-finish-2.png.
  mac 01-session "Тренировка на понедельник" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 2 --demo-phase away \
    --demo-session --demo-recording --demo-second-camera
  mac 02-plan "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-plan
  # A row of the plan edited: exit 6 dragged to 2:30 on the timeline («изменено», the trainer's 2 мин beside it).
  WAIT=5 mac 02b-plan-edit "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-plan --demo-timeline-edit
  WAIT=5 mac 03-review "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-review
  # The same row in the review sheet: selected (its lines lit in the trainer's text), its length's editor open — the
  # popover is a window of its own: mac-03b-review-edit-2.png.
  WAIT=6 mac 03b-review-edit "Тренировка на воскресенье" -streamName hall -demoPlanText "$PLAN_RU" --demo-review \
    --demo-review-select 6 --demo-duration-popover 6
  # The break: the strip, «Перерыв», the next exit's trigger, the number, «Вышли» / «Фальстарт».
  mac 04-break "Тренировка на понедельник" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 3 --demo-break-left 70 \
    --demo-session --demo-recording
  # After «Фальстарт» in the break: ↺ on the retried exit's chip and a small «Отменить фальстарт», no sentence.
  mac 04b-break-false-start "Тренировка на понедельник" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 2 \
    --demo-phase break --demo-session --demo-recording --demo-false-start
  WAIT=5 mac 05-history "История" -streamName hall --open history --demo-history
  WAIT=6 mac 06-finish "Прихожая" -streamName hall -demoPlanText "$SESSION_RU" --demo-exits-done 5 \
    --demo-phase finish --demo-session
  # Other windows of a shot (a sheet's own window, a popover) are not wanted, except the summary of 06-finish.
  for n in 01-session 02-plan \
           02b-plan-edit 03-review 04-break 04b-break-false-start 05-history; do
    rm -f $OUT/mac-$n-2.png
  done
  if (( ${#MISSING} )); then
    echo "Not captured: ${MISSING[*]} (see /tmp/wp-ui-shot.log)" >&2
    exit 1
  fi
fi
