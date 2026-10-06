**Waiting Paws for Windows** — the training console of the Mac app as a Windows desktop app.

**New in 1.1.0**

* Two steps and two timers: «Вышли» (Outside) once the door is closed and «Вернулись» (Back Inside); «Фальстарт»
  works outside and in the break. A break that runs out keeps going until «Вышли», its timer turns red and counts up.
* The new training panel: the exit strip, a big timer over a progress line, two buttons with their keys;
  «Вернулись» is blue, the colour of the break. Door icons on both buttons.
* The schedule can be edited during the training («Расписание»), and on the timeline: click an exit or a break to
  type its length or drag its edge (Shift — 5 s grid). The countdown recalculates at once.
* The timeline starts at the first exit; what happened outside is pink, every overrun is yellow.
* Presses on a linked iPhone land at their real moment, even over a weak Wi-Fi.
* «Начать тренировку и запись» / «Завершить тренировку и запись» when the recording goes with the training;
  «Повторить прошлое» is gone.
* Schedule parser: a time sets the common break only when it belongs to «перерыв» (false-start rules no longer
  turn into 20 s breaks).
* A wider navigation rail with labels that always fit; timeline legend entries that do not fit drop out whole.
* Dialogs put the main button on the right with «Отмена» next to it, as on the Mac, the iPhone and the web;
  the selected tab's accent mark runs the full height of the tab.

* The trainer's schedule (paste from Telegram/WhatsApp, Ctrl+Shift+V), review and editing before the start, big
  timers for exits and breaks, the plan-and-actual timeline, the log for the trainer.
* Live camera through the built-in go2rtc 1.9.14 (Mi Home cameras, including homes shared with the account, and any
  go2rtc stream); quality and the camera's night mode and other settings.
* Recording with the training or on its own; recordings are finished as regular MP4 with AAC sound; history with
  the progress chart, the video player and "jump to the exit".
* The iPhone app links to this computer like to a Mac (Settings → iPhone).
* Russian and English, light and dark themes.

**Install**: `WaitingPaws-<version>-Setup.exe` (for all users; adds Windows Firewall rules for the camera on
private networks), or unpack `WaitingPaws-<version>-win-x64.zip` and run `Waiting Paws.exe`.
The app is not code-signed yet: SmartScreen asks once — "More info" → "Run anyway".

Windows 10/11 x64. Playing HEVC (H.265) recordings in other Windows players needs the "HEVC Video Extensions";
Waiting Paws itself, Telegram and browsers play them as is.
