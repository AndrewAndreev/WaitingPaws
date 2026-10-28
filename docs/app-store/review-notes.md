# App Review notes (paste into App Store Connect → App Review Information → Notes)

Waiting Paws helps dog owners do separation training: the trainer sends a schedule of short "exits"
(leave the apartment for N seconds, then a break), and the app turns it into big step buttons, timers,
the trainer's conditions for each exit, a live camera view of the dog while the owner is outside, an optional video
recording and a log for the trainer.

HOW TO REVIEW WITHOUT A CAMERA
1. On the first screen tap "Continue Without Camera" (iPhone), or choose "Continue Without Camera" in the
   welcome window (Mac). Timers, schedules and logs work without any hardware.
2. Copy this sample schedule. Tap "Paste Schedule", then "Paste" and "Parse" (Mac: Training → "Paste Schedule",
   or Shift-Command-V):

   Sunday training - Anna - 25.10.2026
   All breaks 1 minute
   Exit 1 - 5 seconds
   Exit 2 - 10 seconds + jacket
   Exit 3 - 30 seconds OR until the dog stands up
   🟡 If she stands up and walks off - come back in 10 seconds
   🟢 If she lies down - come back in 20 seconds

   Exit 2 gets the trigger "jacket", exit 3 its two conditions for coming back early. Tap an exit to edit its
   triggers, conditions and note.
3. Tap "Start Training". Then "Outside" → "Back Inside" ("False Start" when the dog reacts). You don't have to wait
   for the timers: breaks count down to the next exit, and past the plan they count up in yellow.
   - The card shows the current exit's conditions; tap it to open the exit's details.
   - The document button at the top (iPhone) or the panel (Mac) shows the trainer's original text.
   - The ••• menu has "Edit Schedule".
   After the last exit, tap "Another Exit" or "Finish". A training ends only with "Finish". It is then saved to
   History with a text log for the trainer ("Send Log").

CAMERA FEATURES (need hardware)
The live view and recording need a Xiaomi (Mi Home) camera on the same Wi-Fi network, or any RTSP/ONVIF camera.
A video of these features with real cameras: <ADD LINK TO A SCREEN RECORDING>.

- Sign-in to Xiaomi is performed by go2rtc, an open-source (MIT) streaming component compiled into the app,
  directly against the user's own Xiaomi account. The password is not stored and nothing is sent to the
  developer; the token stays on the device and can be removed in Settings → "Sign Out of Xiaomi".
- Video goes from the camera to the device over the local network (local network permission). The app does not
  run in the background: recording pauses when the app is suspended and resumes when it is opened again.
- Cameras with a motor can be turned from the app (the arrows button on the picture; Mac: View → "Turn Camera"),
  with the same command the Mi Home app sends to the user's own camera.
- A second camera can be added to look at ("Second Camera…" in the camera menu, the camera's name at the top).
  The recording follows the camera on screen, and the parts are joined into one video.
- iPhone and Mac can be linked over the local network (Bonjour) so the iPhone shows the Mac's camera and drives the
  same training; both show the same camera. The first connection must be allowed on the Mac. The link is encrypted
  end to end between the two devices.

PRIVACY
No accounts, analytics, ads or tracking. All data (settings, logs, videos) stays on the user's devices.
Photos access is add-only, to save training videos.

---

Not for pasting. What the screen recording should show, on a real camera (iPhone and Mac):
- setup: sign in to Xiaomi (or enter an RTSP address), pick the camera, the local network prompt;
- a training with the live picture: "Outside" → "Back Inside", the recording indicator;
- turning the camera, adding the second camera and switching to it during the recording;
- the finished training in History: the joined video plays, "Save to Photos" / "Send Log";
- the iPhone linked to the Mac: the same training and camera on both.
