# Waiting Paws for Windows (Electron)

The Windows version of Waiting Paws: the same training flow as the Mac app — the trainer's schedule, timers for
exits and breaks, live camera, recording and the log — in one Electron window. The UI is web code that talks to its
backend only through `window.wp` (`src/shared/api.ts`), so the same UI can run in a browser next to a small server.

```
┌──────────────────────────────────────────────────────────┐   P2P (LAN)   ┌──────────────┐
│ Waiting Paws.exe (Electron)                               │ ────────────▶ │ Xiaomi camera│
│  UI (React, renderer) ◀─ MSE/WebRTC ─ go2rtc.exe (child)  │               │   (Mi Home)  │
│  backend (main): sessions, recording, files, iPhone link  │               └──────────────┘
│  media window: recordings → MP4 + AAC (WebCodecs)         │ ◀── iPhone app (same protocol as the Mac)
└──────────────────────────────────────────────────────────┘
```

* **go2rtc** is the same patched 1.9.14 the iOS/macOS apps embed (`GoMobile/`), built as `go2rtc.exe` by
  `scripts/build-go2rtc.mjs` (the `GoMobile/build.sh` patches as exact string replacements) with
  `GoMobile/desktop/main.go`. It runs as a child process on `127.0.0.1:11984` (next free pair if taken), exits with
  the app (`-parent-pid`), restarts after a crash (with the current LAN password; a linked iPhone gets the new ports);
  its output goes to the app log.
* **Live view**: go2rtc's `video-rtc.js` runs right in the window (`src/renderer/src/player/`), with the Mac app's
  jitter-buffered MSE path, phases for the status overlay and the delay figures. The main process strips the browser
  `Origin` from requests to go2rtc (its guard refuses foreign origins — that protects it from web pages, not from us)
  and adds Basic auth for a user's server.
* **Recording**: `GET /api/stream.mp4` into `Documents\Waiting Paws\Recordings`, in parts when the camera drops out.
  Afterwards a hidden window turns it into a regular MP4 with **mediabunny + WebCodecs**: video copied as is, the
  camera's Opus/FLAC/PCM sound → AAC 48 kHz with silence for pauses, a silent track when the camera gave no sound,
  parts joined at their real time — each at its first frame, as on the Mac (the port of the Mac's `RecordingFinalizer`,
  no ffmpeg needed). A part without video or one that can't be read is left out and kept in `Recordings\.parts`.
  A finished file that can't replace the recording (a player or the antivirus holds it for seconds) is kept next to
  it as `<name>.finalizing-<time>.mp4` and put in place at the next launch.
  Closing the window, quitting, or a Windows shutdown/sign-out during a training saves it (on shutdown the parts of a
  recording stay unjoined). Deleting a recording removes its parts too, also while it is still being joined.
* **History** is the Mac/iPhone format (`Documents\Waiting Paws\Sessions\*.json|txt`): a history folder copied from
  a Mac opens here and back.
* **iPhone link**: the computer advertises itself over Bonjour exactly like the Mac (`_waitingpaws._tcp`, WebSocket,
  X25519 + ChaChaPoly), so the existing iPhone app pairs with it as with a Mac. Off by default (Settings → iPhone):
  opening go2rtc to the LAN makes Windows Firewall ask. Handshakes from a browser (with an `Origin` header) are
  refused; a known iPhone id that can't prove its pairing gets a warning in the prompt, with «Отклонить» as the
  default. Switching to your own go2rtc server stops the bundled one (the iPhone then runs the training without video);
  the server can't be changed during a training or a recording.
* **Settings** `%APPDATA%\Waiting Paws\settings.json` (the server password encrypted with DPAPI via safeStorage),
  go2rtc config with Mi Home tokens `%APPDATA%\Waiting Paws\go2rtc\go2rtc.yaml`, logs `%APPDATA%\Waiting Paws\Logs`
  (last 5 runs, passwords and tokens masked).

## Layout

```
src/core       TypeScript port of Packages/WaitingPawsCore (parser, engine, log, store, go2rtc client, camera
               modes, sync protocol; node/syncCrypto.ts for the main process) — tests in test/
src/shared     UI ↔ backend contract, settings, i18n (English keys, Russian from Tools/strings/ru.json + strings/*.ru.json)
src/main       backend: go2rtc process, recorder, finalizer bridge, storage, camera modes, sync/ (iPhone host)
src/preload    window.wp (and the media window's file access)
src/renderer   React UI: training/, history/, settings/, onboarding/, plan/, player/, media/ (finalizer)
scripts        build-go2rtc.mjs, make-icons.cjs, notices.mjs
build          installer icon and NSIS hooks (firewall rules), generated notices
docs/ui-guide.md  design rules of the Windows/Web UI
```

## Build

Requirements: Node 22+ (24 LTS used), Go 1.24+, git.

```bash
cd Desktop
npm ci
npm run go2rtc          # resources/bin/go2rtc.exe (clones go2rtc v1.9.14 into build/go2rtc, patches, builds)
npm test                # core, sync host and UI logic tests
npm run dev             # development (hot reload)
npm run dist            # dist/WaitingPaws-<version>-Setup.exe and dist/WaitingPaws-<version>-win-x64.zip
```

`npm run icons` re-renders the icon from `Design/app-icon/AppIcon-ios.svg`; `npm run notices` refreshes the
third-party notices (run by `dist`).

Releases: one tag `vX.Y.N` for iPhone, Mac and Windows (`Tools/release.sh tag X.Y`, see DEVELOPMENT.md «Версии и
выпуски»); push it, and `.github/workflows/windows.yml` builds on `windows-latest` with the tag's version and attaches
the installer and the zip to that tag's release (a draft when it creates it). `package.json` keeps `0.0.0`: any
other build shows "dev (commit)" as its version.

## Installer

`WaitingPaws-<version>-Setup.exe` installs for all users (one UAC prompt) and adds two Windows Firewall rules for
private networks: `go2rtc.exe` (Xiaomi cameras answer over UDP) and `Waiting Paws.exe` (the iPhone link). Without
them Windows asks on first use — and a "Cancel" there leaves Block rules that silently break the camera; the
installer removes those for its own programs. The uninstaller removes the rules; history and settings stay.

The zip is portable: unpack and run `Waiting Paws.exe` (firewall prompts appear on first use; answer "Allow" for
private networks).

The build is not code-signed: the first launch shows SmartScreen ("Windows protected your PC" → More info → Run
anyway).

## Updates

An installed release updates itself from GitHub (electron-updater, `src/main/updater.ts`), like the Mac app from
GitHub (Sparkle, which checks at launch and every 6 hours): once a day, never during a training or a recording, it
reads `latest.yml` of the Latest release
(and, with «Тестовые сборки», of the `nightly` pre-release — the newer one wins). A new version shows as «Обновление»
in the title bar; Settings → About → «Обновления» has the mode (install automatically / notify only / don't check),
test builds, the waiting version and «Проверить сейчас». It installs on quit or with «Перезапустить» (one UAC
prompt: the app is installed for all users). The portable zip and development builds (version 0.0.0) don't update.
CI puts `latest.yml`, the installer and its blockmap into each release, and a test build into `nightly` whenever
`Tools/release.sh publish-nightly` moves that tag.

`--demo-update` (a downloaded 1.7.21) or `--demo-update found` shows the UI without GitHub;
`--eval="__wpUI.set({showUpdatePopover:true})"` opens the popover. In the web preview: `?demo-update[=found]`.

## Checks without a camera

```bash
npx electron . --data-dir=%TEMP%\wp-check --demo-history --demo-plan
npx electron . --data-dir=%TEMP%\wp-check --demo-session --demo-exits-done=3 --demo-phase=away
npx electron . --data-dir=%TEMP%\wp-check --capture=shot.png --quit-after-capture --eval="__wpUI.set({route:'history'})"
```

`--data-dir` keeps settings, history, go2rtc config and logs in that folder. Keyboard (the Mac's shortcuts with Ctrl
for ⌘): Space next step, Backspace false start, Ctrl+Enter start, Ctrl+Shift+V paste schedule, Ctrl+R record, Ctrl+E
edit the running schedule, Ctrl+. finish, Ctrl+1 / Ctrl+2 the training page with the main / second camera, Ctrl+H
history (⌘Y on the Mac), Ctrl+, settings, Ctrl+= / Ctrl+− / Ctrl+0 zoom the schedule's timeline, F11 full screen, F12
developer tools (development builds only).

Opened in a plain browser (`npm run dev`, then the dev server URL) the UI runs on an in-page backend
(`src/renderer/src/platform/browserBackend.ts`): schedule, timers, log and history work, without a camera — the
starting point of a web version.
