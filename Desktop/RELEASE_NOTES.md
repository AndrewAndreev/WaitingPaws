**Waiting Paws for Windows** — the training console of the Mac app as a Windows desktop app.

**New in 1.7.17**

* The same version as iPhone and Mac 1.7.17, built from the same code (1.7.16 was a Mac-only build).
* Xiaomi cameras: a camera serves one session at a time, and go2rtc now tells it when a session ends instead of just
  dropping it, so the camera is free for the next one sooner. A session the camera turns away (it still holds another
  one) ends at once instead of after go2rtc's 15-second wait. The camera search on the local network keeps trying
  when a send fails, and the log follows every connection step: the Mi Cloud key time, the handshake, the first video
  frame and how a session ended.
* Adding a camera by its address offers rtsp:// and http:// (an ONVIF camera by its rtsp:// address). onvif:// was
  offered before, but the built-in go2rtc has no ONVIF module.
* The third-party licenses shipped with the app list every package.
* On the Mac: the session's capsule in the window's header, with the window's buttons, no longer shakes; a zoomed
  camera picture pans up under the header and fills the window; the C302's SD picture no longer leaves a black strip
  at the left.

**In 1.7.15**

* The same version as iPhone and Mac 1.7.15, built from the same code. The Windows app itself has not changed since
  1.6.12. 1.7.15 fixes «Подключаемся к камере…» staying over a camera picture that plays (on the Mac, after the
  training window was closed and opened again from the Dock). In the Mac's schedule check the trainer's text slides
  away and back, the buttons over it light up under the pointer and when pressed, and «Готово» is back beside
  «Начать тренировку»: it keeps the schedule without starting the training.

**In 1.7.14**

* The same version as iPhone and Mac 1.7.14, built from the same code. The Windows app itself has not changed since
  1.6.12: 1.7 redesigned the iPhone and Mac screens, and 1.7.14 brings them a zoomed camera picture that fills the
  space behind the panels, the orange of a running-over exit or break back in place of 1.7's yellow, a stronger
  vibration when the break ends and a double tap that zooms in where you tap.

**In 1.6.12**

* «45 секунд + куртка + ключ ИЛИ до вставания» is read right: «ключ» is a trigger and «до вставания» the exit's
  condition, «встала → сразу». It used to become one trigger, «ключ ИЛИ до вставания». Plans saved with it come back
  right; «ключ или телефон» stays one trigger.
* Conditions the trainer wrote once for the whole training now go to the exits of a minute and longer by default
  («К длинным ≥ 1 мин» in the schedule check): on a 15-second exit «легла → 1:00» never comes. «Ко всем» and «Выбрать»
  are still there.
* «К длинным» / «Ко всем» stays when you add an exit or change an exit's time, in the schedule check, in the timeline
  and in the running schedule: a new short exit doesn't get the common conditions, an exit stretched past a minute
  does. Exits picked one by one are left as they are.
* The trainer's 🚩 rule reads ⛔ «ждать тишины» instead of 🚩 «не входить», which looked like a command for right now.

**In 1.6.11**

* «ИЛИ до вставания» is no longer a separate switch beside the exit's conditions: it is one of them, «Встала →
  сразу», and can be changed or removed like the others. The «До вставания» column in the schedule check, the switch
  in the exit's panel and «Или до вставания» in the timeline menu are gone. The switch could contradict the
  conditions («до вставания» ticked, «встала и пошла → 4:00» below it).
* The exit's «до вставания» wins over the training's common conditions about standing up: such an exit gets
  «встала → сразу» and keeps the rest of them («легла → 3:00»). Lines written right under the exit stay as they are
  («3 минуты ИЛИ до вставания» with «встала и пошла → 1:00» under it). Plans saved by older versions are read the
  same way. «или до вставания» in the timeline and the * in the history now follow the exit's conditions.

**In 1.6.10**

* One version for iPhone, Mac and Windows: this release follows 1.2.0 and matches iPhone and Mac 1.6.10, built from
  the same code. About and Diagnostics show the version with the commit it was built from, e.g. «1.6.10 (ab24690)».
* The exit strip marks exits: ⚡ the exit has triggers («+ куртка»), 🏃 it may end before its planned time («ИЛИ до
  вставания» or a condition that comes sooner). The strip scrolls to the current exit.
* «Остановить запись?» before a recording stops by a press (REC, Ctrl+R, the clip panel); Enter keeps recording.
  The compact window asks right in its strip. Starting a recording never asks.
* The open list of a select is readable in the dark theme.

**In 1.2.0**

* Exits get triggers («+ куртка»), conditions for coming back early («🟡 Если встала — входим через 2 минуты») and
  their own notes; the trainer's «🚩 … не входить» rule stands out in red. The schedule check shows them under each
  exit, the training shows the condition plates under the timer and the trainer's text at the bottom of the panel.
* Conditions written once go to all exits, to the long ones (≥ 1 min) or one by one. Times are read from words too
  («через минуту», «через секунд 30», «через 1,5 минуты»); one that can't be read is shown in the trainer's words
  instead of «сразу», and «не заходя в комнату» is no longer taken for a rule.
* A second camera (another room): the «Прихожая · Комната» switcher, Ctrl+1 / Ctrl+2. Recording stays with the main
  camera.
* A training ends only with «Завершить»; after the last exit the break runs on, and «Ещё выход» adds an exit without
  a planned time. «Фальстарт» folds away when the trainer's window for it is over.
* Recording is safer: two quick stops, a full disk or a file held open by Explorer or an antivirus no longer lose
  the video; after a camera drop-out each part lands at its first frame, so «jump to the exit» matches the video.
  A training is saved when Windows shuts down or signs out.
* Shortcuts as on the Mac: Ctrl+E edits the running schedule, Ctrl+. finishes; letters work in the Russian layout
  too.
* The server can't be switched during a training or a recording, and «Свой сервер go2rtc» no longer sends you back
  to the first-launch screen before its address is saved.
* Security: the built-in go2rtc refuses requests that would re-point the camera from a web page, camera settings
  reach only the cameras set up here, the iPhone link refuses browser pages, and a forgotten iPhone loses camera
  access at once. Error messages are in English with the English interface.

* The trainer's schedule (paste from Telegram/WhatsApp, Ctrl+Shift+V), review and editing before the start, big
  timers for exits and breaks, the plan-and-actual timeline, the log for the trainer.
* Live camera through the built-in go2rtc 1.9.14 (Mi Home cameras, including homes shared with the account, and any
  go2rtc stream), a second camera; quality and the camera's night mode and other settings.
* Recording with the training or on its own; recordings are finished as regular MP4 with AAC sound; history with
  the progress chart, the video player and "jump to the exit".
* The iPhone app links to this computer like to a Mac (Settings → iPhone).
* Russian and English, light and dark themes.

**Install**: `WaitingPaws-<version>-Setup.exe` (for all users; adds Windows Firewall rules for the camera on
private networks), or unpack `WaitingPaws-<version>-win-x64.zip` and run `Waiting Paws.exe`.
The app is not code-signed yet: SmartScreen asks once — "More info" → "Run anyway".

Windows 10/11 x64. Playing HEVC (H.265) recordings in other Windows players needs the "HEVC Video Extensions";
Waiting Paws itself, Telegram and browsers play them as is.
