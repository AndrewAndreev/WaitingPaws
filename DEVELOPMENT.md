# Разработка

Сборка, структура проекта, локализация, диагностика и отладка iPhone- и Mac-приложения (на русском). Как оно устроено —
в [ARCHITECTURE.md](ARCHITECTURE.md), встроенный go2rtc — в [GoMobile/README.md](GoMobile/README.md), версия для
Windows — в [Desktop/README.md](Desktop/README.md).

## Структура

```
project.yml                      — спецификация xcodegen (два таргета: WaitingPaws-iOS, WaitingPaws-macOS)
App/Sources                      — общий SwiftUI-код для обеих платформ
  AppModel.swift                 — состояние приложения: сессия, запись, история
  AppSettings.swift              — настройки (UserDefaults + Keychain для пароля go2rtc)
  Views/Session                  — главный экран: камера + HUD
  Views/Plan                     — ввод и редактор расписания
  Views/Onboarding               — приветствие → вход в Xiaomi → камера (iPhone; на Mac — Mac/Onboarding)
  Views/History, Views/Settings
  Views/Camera/CameraStreamView  — WKWebView с плеером go2rtc
  Go2RTC/EmbeddedGo2RTC.swift    — запуск встроенного go2rtc (конфиг, статус)
GoMobile/                        — Go-обёртка go2rtc и build.sh для сборки xcframework (desktop/ — go2rtc.exe для Windows)
Desktop/                         — версия для Windows (Electron + React, ядро портировано на TypeScript)
Frameworks/Go2RTC.xcframework    — результат сборки (не в git, собирается скриптом)
Packages/WaitingPawsCore         — Swift Package без UI, с тестами
  Parser/PlanParser.swift        — разбор текста расписания
  Engine/TrainingSession.swift   — машина состояний тренировки и лог событий
  Go2RTC/Go2RTCClient.swift      — API go2rtc (потоки, Xiaomi-логин, список камер)
  Go2RTC/StreamRecorder.swift    — запись MP4 в файл
  Storage/SessionStore.swift     — сохранение логов/видео
Design/logos-v2                  — все концепты логотипа кодом (SVG) + галерея-мокап, см. README там
Design/app-icon                  — исходники иконки приложения (концепт 07 «Песочные часы», палитра «Ночь»)
```

Иконка приложения генерируется из кода: `node Design/logos-v2/app-icon.js` пересобирает SVG в
`Design/app-icon` и все PNG в `App/Resources/Assets.xcassets/AppIcon.appiconset` (нужны
`rsvg-convert` и ImageMagick: `brew install librsvg imagemagick`).

## Сборка

1. Фреймворк go2rtc (один раз и после обновления версии go2rtc) — подробности и список патчей в
   [GoMobile/README.md](GoMobile/README.md):

   ```bash
   brew install go xcodegen
   go install golang.org/x/mobile/cmd/gomobile@latest && ~/go/bin/gomobile init
   ./GoMobile/build.sh
   ```

2. Проект:

   ```bash
   xcodegen generate
   open WaitingPaws.xcodeproj
   ```

Схемы `WaitingPaws-iOS` и `WaitingPaws-macOS`. Команда разработчика задана в `project.yml`
(`DEVELOPMENT_TEAM`); для своей сборки поменяйте её там.

### Локализация

Языки — английский (базовый: на всех языках устройства, кроме русского) и русский.

Тексты в коде — русские, они же ключи `App/Resources/Localizable.xcstrings` (английский — базовый язык,
`developmentLanguage: en`). В SwiftUI литералы переводятся сами (`Text("…")`, `Button("…")`), всё, что становится
`String`, оборачивается в `String(localized: "…")`, множественное число — `pluralText(n, ru:, en:)` из ядра.
Ядро (`WaitingPawsCore`) двуязычное без каталога: `tr(ru, en)` по `CoreLanguage.current`, парсер расписания понимает
русский и английский текст тренера («1 выход - 30 секунд», "Exit 1 - 30 seconds") при любом языке интерфейса.

После изменения текстов:

```bash
xcodebuild -scheme WaitingPaws-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wp-dd build
xcodebuild -scheme WaitingPaws-macOS -destination 'generic/platform=macOS' -derivedDataPath /tmp/wp-dd build
Tools/strings/build_catalog.py /tmp/wp-dd   # пересобирает каталог и перечисляет ключи без перевода
```

Переводы — `Tools/strings/en.json` (русский ключ → английский текст). Строки `Info.plist` по-русски —
`App/Resources/InfoPlist.xcstrings`.

### Перед публикацией

* Одна запись в App Store для iPhone и Mac (Universal Purchase): у обоих таргетов bundle id `su.comrade.waitingpaws`.
* `App/Resources/PrivacyInfo.xcprivacy` — манифест приватности (UserDefaults, даты файлов, `mach_absolute_time` рантайма Go).
* `App/Resources/Legal/` — политика конфиденциальности (ru/en, показывается в «О приложении») и лицензии открытого ПО.
  `GoMobile/licenses.sh` пересобирает лицензии по модулям, реально попадающим во встроенный go2rtc;
  `Tools/legal_html.py` пишет `docs/privacy.html` для URL политики в App Store Connect.
* `docs/` — страницы поддержки и политики (GitHub Pages из папки `/docs`), `docs/app-store/` — заметки для App Review
  и черновик метаданных.
* `docs/screenshots/app-store/<en|ru>/` — скриншоты для App Store (iPhone 6.9″ 1320×2868, Mac 2880×1800),
  `docs/screenshots/showcase/` — картинки с рамками устройств и подписями. Пересъёмка: `Tools/screenshots/make.sh`
  (отдельный симулятор «WP Screens», фоновые копии Mac-приложения с `--retina`, только DEBUG-демо-данные;
  `make.sh compose` пересобирает картинки из уже снятых кадров).

### Тесты

```bash
cd Packages/WaitingPawsCore && swift test   # ядро: парсер, тренировка, лог, синхронизация
```

Тесты патчей go2rtc — в [GoMobile/README.md](GoMobile/README.md#тесты), версии для Windows — `npm test` в `Desktop/`.

## Диагностика

Отклик UI оценивайте при запуске с домашнего экрана, а не из Xcode: под отладчиком каждая первая
загрузка системного фреймворка (клавиатура, диктовка, презентация листа) ждёт lldb, и первое открытие
редактора расписания занимает в разы дольше, чем без отладчика. Клавиатура прогревается через 2 с после
старта, чтобы первый ввод не ждал её загрузки.

Журнал приложения (stdout/stderr, go2rtc) — `Library/Caches/Logs`, последние 5 запусков, пароли в адресах
(`rtsp://user:pass@…`) маскируются. На Mac: Настройки → Диагностика → «Показать в Finder».

Плеер (MSE) — своя замена `onmse` из `video-rtc.js` в `CameraStreamView`: воспроизведение отстаёт от «живого края»
на адаптивный запас: 0,8 с, сразу растёт (до 3,5 с), чтобы покрыть паузу в данных, и каждые 10 с плавно (по 0,3 с)
подтягивается к самой длинной паузе за последние 30 с + 0,4 с. За дверью, где паузы ~0,8 с, это ~1,3 с запаса
(прежнее правило держало 1,8 с, пока не пройдут 30 с почти без пауз). Ожидание первого ключевого кадра после
подключения — до целого GOP, ~3 с у C302 — паузой не считается. Скорость подстраивается мягко (0,95–1,3×; отставание
сверх запаса догоняется на 1,15–1,3× за секунды; медленнее 1× — только до базовых 0,8 с: выросший запас наполняют
сами опоздавшие данные, а если они так и не пришли, замедление только добавило бы задержки), длительность MediaSource бесконечная. В оригинале скорость равнялась
запасу (до 0,1×), а кончившиеся данные WebKit считал концом потока и ставил видео на паузу до следующей перемотки —
отсюда «фриз — кадры через 3 с — фриз». Строки в журнале для разбора лагов:

* `[player] 12:03:30 stats 30s: stalls …, max data gap … ms, lag …, cushion …` — плеер (только если что-то случилось или отставание больше 1,5 с);
* `[go2rtc] 12:03:30 mse/fmp4 ws … fell behind: N frames dropped` — go2rtc выбросил кадры отставшему зрителю;
* `12:03:30 cs2: connected to 192.168.1.20:13780 over UDP in 840 ms` — как камера подключилась;
* `12:03:30 cs2: 30s over TCP: 450 video frames (15.0 fps), … kbit/s, longest pause … ms (camera time … ms),
  delivery spread … ms` — вход потока от камеры (через 30 с после подключения и дальше только при паузах от 0,7 с,
  ожидании потерянного UDP-пакета от 0,3 с или переполнении). Пауза в доставке при ровном времени камеры — данные задержались в сети (их догонит запас
  плеера); пауза и во времени камеры — камера кадры не прислала. Разброс доставки — какой запас нужен плееру.
  Если эта строка спокойная, а плеер на iPhone видит паузы, — дело в Wi-Fi между Mac и iPhone.

Пока картинки нет, поверх плеера видно, что происходит (`PlayerPhase` из строк `state …` страницы):
«Подключаемся к камере…» (через 10 с — подсказка, что камера может быть не в сети или занята), «Камера на связи,
ждём первый кадр…» (go2rtc уже прислал кодеки, ждём ключевой кадр), «Камера не отвечает» с причиной от go2rtc
(тайм-аут, отказ; video-rtc.js переподключается сам), а над застывшим больше 2 с кадром — плашка «Нет новых кадров».
На карточке камеры в настройках Mac слой выключен: там своя подпись.

DEBUG `--player-trace` пишет состояние плеера каждую секунду. Проверка без камеры: локальный go2rtc с потоком
`exec:ffmpeg … testsrc …` и приложение в режиме «Свой сервер», провалы — `kill -STOP`/`-CONT` его процесса.

Каждое зависание главного потока дольше 250 мс пишется в консоль Xcode строкой
`[perf] main thread hang 1200 ms at 10:34:12.345`. Настройки → «Показывать нагрузку» (или аргумент
запуска `--perf`) дополнительно выводит над камерой строку:
CPU приложения и главного потока, память, максимальная задержка главного потока за секунду
(`UI +… мс`, больше 250 мс = заметные подвисания) и число потоков. Видео рендерит WebKit в отдельном
процессе, его нагрузка сюда не входит. Чтобы отделить встроенный go2rtc от видео, переключитесь в
«Свой сервер go2rtc» на Mac с той же камерой и сравните.

Первой строкой — задержка картинки: `Задержка ≈ 1,6 с: сеть 0,4 с + буфер 1,2 с`. На Mac та же панель — в углу
картинки камеры. Обе части меряет сам плеер (MSE), поэтому цифра одна и та же для любого пути — и для iPhone,
смотрящего через Mac (камера → Mac → Wi-Fi → iPhone). «Сеть» — насколько позже, чем самые быстрые за последнюю минуту,
приходит свежее видео: время внутри ролика — это время кадров камеры (go2rtc переносит его как есть), и «приход минус
время в ролике» растёт, только когда кто-то в пути держит кадры. Абсолютного времени съёмки нет (C302 ставит на кадры
свой счётчик с момента включения, а не настоящее время), поэтому кодирование в камере и базовая передача (~0,2–0,3 с)
в сумму не входят. «Буфер» — сколько прошло с прихода свежих данных плюс сколько видео ещё впереди в буфере плеера
(во время фриза растёт). Пачка, догнавшая паузу, показывается как рост буфера, а не сети: свежий её кусок пришёл
вовремя, а запас вырос. Пока «сеть» не набралась (первые секунды) — `Задержка ≥ 0,8 с: только буфер плеера`.
Жёлтым — больше 1,2 с, красным — больше 2 с.

Запись запрашивается у go2rtc как `video=h264,h265&audio=aac,opus,pcma,pcmu`. Без ffmpeg go2rtc
не умеет делать AAC: Opus он кладёт в MP4 как есть, а PCMA/PCMU (звук многих Xiaomi) сам превращает
в FLAC. AVFoundation оба читает, но Фото и большинство плееров принимают в MP4 только AAC, поэтому
приложение после записи перекодирует звук в AAC (`RecordingFinalizer`). Если
перекодировать не удалось, файл остаётся как был, ошибка пишется в лог (`[rec] finalize failed`).

## Отладка без камеры

Встроенный go2rtc доступен с Mac по `http://127.0.0.1:11984` и в симуляторе, и в macOS-приложении
(если запустить обе копии на одном Mac, вторая возьмёт следующий свободный порт — 11986 и дальше; фактический адрес виден в настройках Mac-приложения → Подключение). Во встроенной сборке нет модуля ffmpeg, поэтому тестовый
поток удобно отдать с отдельного go2rtc по RTSP:

```bash
# внешний go2rtc (с ffmpeg) на других портах
printf 'api:\n  listen: ":1985"\nrtsp:\n  listen: ":8554"\nstreams:\n  testcam: ffmpeg:virtual?video&size=1280x720#video=h264#audio=aac\n' > /tmp/go2rtc.yaml
go2rtc -config /tmp/go2rtc.yaml &
# и подключить его к встроенному
curl -X PUT "http://127.0.0.1:11984/api/streams?name=testcam&src=rtsp://127.0.0.1:8554/testcam"
```

У `ffmpeg:virtual` нет звука. Чтобы проверить запись со звуком «как у Xiaomi», поток с синусом можно
отдать через `exec` (`-c:a libopus -ar 48000 -ac 2` для Opus или `-c:a pcm_alaw -ar 8000 -ac 1` для PCMA):

```yaml
streams:
  opuscam: "exec:ffmpeg -hide_banner -v error -re -f lavfi -i testsrc=size=1280x720:rate=20 -re -f lavfi -i sine=frequency=440:sample_rate=48000 -c:v libx264 -g 40 -preset superfast -tune zerolatency -pix_fmt yuv420p -c:a libopus -ar 48000 -ac 2 -f rtsp {output}"
```

В Debug-сборке есть аргументы запуска: `--demo-session` (сразу стартует демонстрационное расписание),
`--demo-phase leaving|away|break|finish` (состояния HUD), `--demo-finish-after 12` (завершить через
12 с, проверяет запись и сохранение в Фото), `--demo-clip 10` (записать 10 с без тренировки),
`--demo-screen plan|plan-twice|camera|history|history-last` (открыть лист расписания,
открыть-закрыть-открыть его, выбор камеры, историю или сразу последнюю запись в ней),
`--demo-parse` (сразу разобрать текст
из прошлого расписания и показать редактор), `--demo-plan-edit` (редактор сразу в режиме «Править»),
`--demo-duration-editor` (открыть выбор перерыва после первого выхода), `--perf` (строка нагрузки).
Связка: `--demo-hosts` (на iPhone рядом два Mac и ПК, ничего не слушает), `--demo-screen settings-sync` (настройки
iPhone, сразу на «Синхронизации»), на Mac — `--demo-iphone` (подключённый и разрешённые iPhone), `--demo-pairing`
(запрос «Подключить?»), `--demo-settings-pane iPhone` (настройки сразу на панели iPhone).

## Планы

* Другие платформы камер — любой источник, который понимает go2rtc, уже можно выбрать как поток;
  отдельный мастер пока есть только для Xiaomi. Чтобы добавить модули go2rtc во встроенную сборку,
  допишите их `Init()` в `GoMobile/mobile/mobile.go` и пересоберите фреймворк.
* Push-уведомления/виджет для таймера, Live Activity на iOS.
