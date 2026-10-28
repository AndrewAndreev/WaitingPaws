**Waiting Paws for Windows** — the training console of the Mac app as a Windows desktop app.

**New in 1.2.0**

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
