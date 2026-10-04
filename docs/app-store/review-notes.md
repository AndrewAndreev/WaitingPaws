# App Review notes (paste into App Store Connect → App Review Information → Notes)

Waiting Paws helps dog owners do separation training: the trainer sends a schedule of short "exits"
(leave the apartment for N seconds, then a break), and the app turns it into big step buttons, timers,
a live camera view of the dog while the owner is outside, an optional video recording and a log for the trainer.

HOW TO REVIEW WITHOUT A CAMERA
1. On the first screen tap "Continue Without Camera" (iPhone), or choose "Continue Without Camera" in the
   welcome window (Mac). Timers, schedules and logs work without any hardware.
2. Tap "Paste Schedule" (Mac: "Paste" or Shift-Command-V) and paste this sample, then tap "Parse":

   Monday training - Anna - 25.10.2026
   All breaks 1 minute
   Exit 1 - 5 seconds
   Exit 2 - 10 seconds
   Exit 3 - 30 seconds OR until the dog stands up

3. Review the parsed exits and tap "Start Training". Then "Start Exit" → "Outside" → "Back Inside". Breaks count
   down and the next exit starts by itself; after the last one the training is saved to History with a text log
   for the trainer ("Send Log").

CAMERA FEATURES (need hardware)
The live view and recording need a Xiaomi (Mi Home) camera on the same Wi-Fi network, or any RTSP/ONVIF camera.
A video of these features with a real camera: <ADD LINK TO A SCREEN RECORDING>.

- Sign-in to Xiaomi is performed by go2rtc, an open-source (MIT) streaming component compiled into the app,
  directly against the user's own Xiaomi account. The password is not stored and nothing is sent to the
  developer; the token stays on the device and can be removed in Settings → "Sign Out of Xiaomi".
- Video goes from the camera to the device over the local network (local network permission). The app does not
  run in the background: recording pauses when the app is suspended and resumes when it is opened again.
- iPhone and Mac can be linked over the local network (Bonjour) so the iPhone shows the Mac's camera; the first
  connection must be allowed on the Mac. The link is encrypted end to end between the two devices.

PRIVACY
No accounts, analytics, ads or tracking. All data (settings, logs, videos) stays on the user's devices.
Photos access is add-only, to save training videos.
