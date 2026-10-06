# App Store Connect metadata (draft)

One app record, bundle id `su.comrade.waitingpaws`, platforms iOS and macOS (Universal Purchase).

- Primary category: Lifestyle (matches `LSApplicationCategoryType` in the Mac Info.plist). Secondary: Utilities.
- Age rating: 4+ (no objectionable content, no user-generated content shared with others, no web access).
- Price: free.
- Privacy Policy URL: https://andrewandreev.github.io/WaitingPaws/privacy.html (enable GitHub Pages: Settings → Pages →
  Deploy from branch `main`, folder `/docs`; the repository must be public, otherwise host docs/privacy.html elsewhere).
- Support URL: https://andrewandreev.github.io/WaitingPaws/ (docs/index.html).
- App Privacy ("nutrition label"): Data Not Collected. Tracking: No.
- Export compliance: `ITSAppUsesNonExemptEncryption = NO` in Info.plist. The app uses only standard encryption
  (TLS/HTTPS to Xiaomi, WebRTC DTLS/SRTP, ChaCha20-Poly1305 and Curve25519 from CryptoKit for the iPhone ↔ Mac link)
  in a free, mass-market consumer app.
- iPad: not supported in 1.0 (iPhone app runs on iPad in compatibility mode). Screenshots: iPhone 6.9" and Mac,
  ready in `docs/screenshots/app-store/en` and `.../ru` (regenerate with `Tools/screenshots/make.sh`).
- iPhone apps on Apple silicon Macs: not needed (native Mac app under the same record).

## English

**Name:** Waiting Paws
**Subtitle (30):** Dog separation training

**Promotional text (170):** Your trainer's schedule, one tap per step, timers that never lose count, and a live camera on the dog while you wait outside the door.

**Description:**
Waiting Paws makes separation training with your dog calm and precise.

Paste the schedule your trainer sent, check the exits and start. Two big buttons, the same on iPhone and Mac: Outside or Back inside, and False start. The app counts every exit and break, shows only what matters right now — the plan of this exit, or the next one during a break — and a break that runs long turns red and counts up. Spotted a mistake in the schedule mid-training? Fix it right there.

• Schedules from your trainer: exits, durations, "or until the dog stands up", breaks after a particular exit or for all of them
• Exit and break timers with an overrun warning
• Live camera while you are behind the door: Xiaomi (Mi Home) cameras or any RTSP/ONVIF stream through the built-in go2rtc
• Video recording of the training, saved with sound and ready to share
• A text log for the trainer, one line per attempt, in the trainer's own notation
• History of trainings and videos
• iPhone and Mac together: the iPhone shows the Mac's camera and drives the same training
• Works without a camera too

Your data stays on your devices: no accounts, no analytics, no tracking.

**Keywords (100):** dog,separation,anxiety,training,puppy,trainer,timer,pet camera,home alone,leave,exit,log,video

(No brand names in keywords — guideline 2.3.7; Xiaomi is mentioned only in the description as a compatible camera.)

## Русский

**Название:** Waiting Paws
**Подзаголовок (30):** Тренировка выходов с собакой

**Промотекст (170):** Расписание тренера, одно нажатие на шаг, таймеры, которые не собьются, и живая камера, пока вы ждёте за дверью.

**Описание:**
Waiting Paws помогает спокойно и точно проводить тренировки коротких выходов из дома с собакой.

Вставьте расписание от тренера, проверьте выходы и начинайте. Две крупные кнопки, одинаковые на iPhone и Mac: «Вышли» или «Вернулись» и «Фальстарт». Приложение считает каждый выход и перерыв, показывает только нужное сейчас — план этого выхода или, в перерыве, следующий выход, — а затянувшийся перерыв краснеет и считает вверх. Заметили ошибку в расписании посреди тренировки? Поправьте прямо там.

• Расписание от тренера: выходы, длительность, «или до вставания», перерывы после конкретного выхода или для всех
• Таймеры выходов и перерывов с подсветкой перебора
• Живая камера, пока вы за дверью: камеры Xiaomi (Mi Home) или любой поток RTSP/ONVIF через встроенный go2rtc
• Запись тренировки на видео со звуком, готовая для отправки
• Лог для тренера: строка на каждую попытку в нотации расписания
• История тренировок и видео
• iPhone и Mac вместе: iPhone показывает камеру Mac и ведёт ту же тренировку
• Работает и без камеры

Ваши данные остаются на ваших устройствах: без аккаунтов, аналитики и отслеживания.

**Ключевые слова (100):** собака,щенок,тренировка,выходы,одна дома,сепарация,кинолог,таймер,камера,видео,лог,тревога
