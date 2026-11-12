# Разработка

Сборка, структура проекта, локализация, диагностика и отладка iPhone- и Mac-приложения (на русском). Как оно устроено —
в [ARCHITECTURE.md](ARCHITECTURE.md), встроенный go2rtc — в [GoMobile/README.md](GoMobile/README.md), версия для
Windows — в [Desktop/README.md](Desktop/README.md).

## Структура

```
project.yml                      — спецификация xcodegen: WaitingPaws-iOS, WaitingPaws-macOS (App Store) и
                                   WaitingPaws-macOS-Direct (с GitHub, обновления через Sparkle)
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

Дизайн-консилиум 1.7 (три модели оценивали экраны раундами) лежит вне репозитория, в
`~/projects/WaitingPaws-design-history/2026-11-council/`. Его скрипты для Waiting Paws (съёмка экранов, листы,
страница сравнения) остались в git, в коммите e667bb2.

Иконка приложения генерируется из кода: `node Design/logos-v2/app-icon.js` пересобирает SVG в
`Design/app-icon` и все PNG в `App/Resources/Assets.xcassets/AppIcon.appiconset` (нужны
`rsvg-convert` и ImageMagick: `brew install librsvg imagemagick`).

## Сборка

1. Фреймворк go2rtc (один раз и после обновления версии go2rtc) — подробности и список патчей в
   [GoMobile/README.md](GoMobile/README.md):

   ```bash
   brew install go xcodegen
   go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260908204917-8b95e45f8d3e && ~/go/bin/gomobile init
   ./GoMobile/build.sh
   ```

   Версия gomobile — та же, что `XMOBILE_VERSION` в `GoMobile/build.sh`.

2. Проект:

   ```bash
   xcodegen generate
   open WaitingPaws.xcodeproj
   ```

Схемы `WaitingPaws-iOS` и `WaitingPaws-macOS`. Команда разработчика задана в `project.yml`
(`DEVELOPMENT_TEAM`); для своей сборки поменяйте её там.

Своя сборка (форк): в `project.yml` — своя `DEVELOPMENT_TEAM`, `bundleIdPrefix` и `PRODUCT_BUNDLE_IDENTIFIER` вместо
`su.comrade.waitingpaws` (iPhone и Mac) и `su.comrade.waitingpaws.widgets` (виджет: id приложения + суффикс), в
`Tools/ExportOptions-AppStore.plist` — свой `teamID`. Имя «Waiting Paws» и иконка под лицензию не попадают
([README](README.ru.md#лицензия)): у форка свои — `CFBundleDisplayName`/`CFBundleName` в `project.yml`, `AppIcon` и
`AppIconImage` в `App/Resources/Assets.xcassets`.

### Локализация

Языки — английский (базовый: на всех языках устройства, кроме русского) и русский.

Тексты в коде — английские, они же ключи `App/Resources/Localizable.xcstrings` (английский — базовый язык,
`developmentLanguage: en`), русский — перевод. В SwiftUI литералы переводятся сами (`Text("…")`, `Button("…")`), всё,
что становится `String`, оборачивается в `String(localized: "…")`, множественное число — `pluralText(n, en:, ru:)` из
ядра. Ядро (`WaitingPawsCore`) двуязычное без каталога: `tr("Break", ru: "Перерыв")` по `CoreLanguage.current`, парсер
расписания понимает русский и английский текст тренера («1 выход - 30 секунд», "Exit 1 - 30 seconds") при любом языке
интерфейса.

Если одному английскому тексту нужны два русских, у второго ключа после `|` — контекст: `Button("Cancel")` → «Отмена»,
`Button("Cancel|verb")` → «Отменить». По-английски показывается текст до `|` (каталог даёт такому ключу английское
значение, Windows-версия отрезает контекст сама).

После изменения текстов:

```bash
xcodebuild -scheme WaitingPaws-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wp-dd build
xcodebuild -scheme WaitingPaws-macOS-Direct -destination 'generic/platform=macOS' -derivedDataPath /tmp/wp-dd build
Tools/strings/build_catalog.py /tmp/wp-dd   # пересобирает каталог и перечисляет ключи без перевода
```

Mac собирают схемой `WaitingPaws-macOS-Direct`: в ней те же исходники плюс обновления (`#if WP_DIRECT`), а
строки, которых нет в сборке, каталог выбрасывает.

Переводы — `Tools/strings/ru.json` (английский ключ → русский текст; тот же файл читает Windows-версия, её
собственные строки — в `Desktop/src/shared/strings/*.ru.json`). Текст, который по-русски пишется так же («REC»,
«go2rtc %@»), переводится сам в себя; ключам без букв («%@», «—») запись не нужна. Строки `Info.plist` по-русски —
`App/Resources/InfoPlist.xcstrings`.

### Перед публикацией

* Одна запись в App Store для iPhone и Mac (Universal Purchase): у обоих таргетов bundle id `su.comrade.waitingpaws`.
* `App/Resources/PrivacyInfo.xcprivacy` — манифест приватности (UserDefaults, даты файлов, `mach_absolute_time` рантайма Go).
* `App/Resources/Legal/` — политика конфиденциальности (ru/en, показывается в «О приложении») и лицензии открытого ПО.
  `GoMobile/licenses.sh` пересобирает лицензии по модулям, реально попадающим во встроенный go2rtc;
  `Tools/legal_html.py` пишет `docs/privacy.html` для URL политики в App Store Connect.
* `docs/` — страницы поддержки и политики (GitHub Pages из папки `/docs`).
* `docs/screenshots/app-store/<en|ru>/` — скриншоты для App Store: `iphone-6.3` (1206×2622, iPhone 17 Pro —
  обязательный набор App Store Connect «iPhone with Dynamic Island, medium display», 6.9″ туда не принимается),
  `iphone-6.9` (1320×2868, iPhone 17 Pro Max — необязательный набор для больших экранов, его же показывает README),
  `mac` (2880×1800); `docs/screenshots/showcase/` — картинки с рамками устройств и подписями. Пересъёмка:
  `Tools/screenshots/make.sh` (симуляторы «WP Screens 6.3» и «WP Screens», каждый в своём родном разрешении, без
  масштабирования; фоновые копии Mac-приложения с `--retina`, только DEBUG-демо-данные;
  `make.sh compose` пересобирает картинки из уже снятых кадров). Фон — палитры в `compose.swift` (`WP_BG=<имя>`,
  по умолчанию светло-серый `paper`); варианты рядом — `Design/showcase-lab`. `WP_DD`, `WP_SIM` и `WP_RAW` уводят
  сборку, симулятор и кадры в свои папки, чтобы не мешать другим сессиям.

### Версии и выпуски

* Версия `X.Y.N` одна на iPhone, Mac и Windows. `X.Y` — набор функций, его поднимают руками: новые функции — `Y`,
  крупные перемены — `X`. `N` — номер сборки: растёт на 1 с каждым выпуском и не сбрасывается при смене `X.Y`
  (1.6.12 → 1.7.13). На iPhone и Mac он же `CFBundleVersion`.
* Выпуск — один тег `vX.Y.N` на коммит, из которого собраны все платформы. Версия, номер сборки и коммит берутся
  из тега при сборке, в файлах проекта только заглушки (`0.0.0` в `project.yml` и `Desktop/package.json`). «О
  приложении» показывает `1.6.10 (9a8e796)`, а сборка в обход тега — `dev`: так видно, из какого кода сборка.
  Одинаковая версия на двух платформах значит один и тот же коммит.
* `Tools/release.sh tag 1.6` ставит на HEAD следующий тег `v1.6.N` (только при чистом дереве). `Tools/release.sh build
  v1.6.N [ios] [mac]` архивирует iPhone и Mac из чистой копии тега (незакоммиченное и неотслеживаемое в сборку не
  попадает) и проверяет версию и коммит в собранных `Info.plist`. Результат — в `DerivedData/Release/v1.6.N/`:
  архивы, `WaitingPaws-1.6.N-mac.zip` и `manifest.txt` (коммит, версии, sha256 zip). Windows собирает GitHub
  Actions после `git push origin v1.6.N`: версия из тега, установщик — в черновике релиза. Если Windows в этом
  выпуске не выходит, черновик удаляют.
* `WP_NO_XIAOMI=1 Tools/release.sh build|export v1.6.N …` — сборка без входа в Xiaomi (условие компиляции Swift
  `WP_NO_XIAOMI`) в отдельную папку `DerivedData/Release/v1.6.N-no-xiaomi/`; вариант записан в `manifest.txt`.
* go2rtc для iPhone и Mac — `Frameworks/Go2RTC.xcframework`, его нет в git. `GoMobile/build.sh` записывает рядом
  `Go2RTC.source` — git-дерево `GoMobile/`, из которого он собран, а `release.sh build` сверяет его с тегом. После
  любой правки в `GoMobile/` перед выпуском — `GoMobile/build.sh`.
* Пересобрать тот же код (например, загрузка в App Store не прошла) — ещё один тег на тот же коммит: номер сборки
  новый, правило «версия = коммит» сохраняется.
* Mac для GitHub — отдельная сборка `release.sh direct` (ниже, «С GitHub»): Developer ID, нотаризация, обновления
  через Sparkle. В App Store идут не архивы и не zip, а файлы из `release.sh export` (ниже).
* Выпуски до 1.6 — теги `ios-v*`, `mac-v*`, `windows-v*` (у каждой платформы своя версия; последняя сборка iPhone и
  Mac — 9).

### В App Store

Один раз, владелец:

* Платное членство Apple Developer Program у команды `849CANCD26`, вход в неё в Xcode → Settings → Accounts.
* Сертификаты Apple Distribution (подпись приложений iPhone и Mac) и Mac Installer Distribution (подпись `.pkg` для
  Mac App Store, в подписи — «3rd Party Mac Developer Installer»). При автоматической подписи они облачные (cloud
  managed): их хранит Apple, а `release.sh export` (`-allowProvisioningUpdates`) подписывает ими от имени команды,
  поэтому экспорт запускает только владелец. В «Связке ключей» их нет, так и должно быть; проверка — вывод
  `release.sh export`. Профили App Store для `su.comrade.waitingpaws` и `su.comrade.waitingpaws.widgets` Xcode делает
  при экспорте сам.
* До первой загрузки — запись в App Store Connect (iOS и macOS, bundle id `su.comrade.waitingpaws`).

Каждый выпуск:

1. Тег ставят на main, в котором уже есть слитая работа: `git switch main && git pull --ff-only`, затем
   `git cat-file -e HEAD:Tools/ExportOptions-AppStore.plist` (код 0). Иначе тег встанет на старый локальный main
   (c041ec9), и все проверки `export` всё равно пройдут. Потом `Tools/release.sh tag 1.7`,
   `Tools/release.sh build v1.7.N` — архивы.
2. `Tools/release.sh export v1.7.N [ios] [mac]` — `xcodebuild -exportArchive` по `Tools/ExportOptions-AppStore.plist`
   (app-store-connect, автоматическая подпись, символы для отчётов о сбоях, версия и сборка — тега) →
   `"DerivedData/Release/v1.7.N/export-ios/Waiting Paws.ipa"` и
   `"DerivedData/Release/v1.7.N/export-mac/Waiting Paws.pkg"` (с пробелом в имени). Потом скрипт распаковывает их и
   проверяет: подпись Apple Distribution (у `.pkg` — 3rd Party Mac Developer Installer), профиль App Store (без списка
   устройств), `get-task-allow` false у приложения и виджета, у Mac — `Contents/embedded.provisionprofile`,
   `com.apple.application-identifier`, `com.apple.developer.team-identifier` и песочница; версия, сборка и коммит —
   тега. Хоть один FAIL — ошибка, такой файл не загружают.
3. Проверка и загрузка — отдельно и руками. В Transporter: перетащить `.ipa` и `.pkg`, у каждого сначала «Verify»,
   затем «Deliver». Или altool: `xcrun altool --validate-app "<файл>" --api-key <KEY_ID> --api-issuer <ISSUER_ID>`,
   затем `xcrun altool --upload-package "<файл>" --api-key <KEY_ID> --api-issuer <ISSUER_ID>` (платформу altool берёт
   из файла) с ключом App Store Connect API (Users and Access → Integrations, роль App Manager) в
   `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` — не в репозитории. Organizer (Distribute App → App Store
   Connect) тоже загрузит, но свой экспорт, а не проверенный файл.
4. App Store Connect обрабатывает сборку обычно от минут до часа, ошибки приходят письмом (ITMS-…). Обработанная
   сборка появляется в TestFlight, её можно поставить себе до ревью. Вопроса о шифровании у сборки нет: у обеих
   платформ `ITSAppUsesNonExemptEncryption` = NO. Это верно, пока в приложении только стандартные алгоритмы
   (TLS, DTLS/SRTP, CryptoKit) и оно не распространяется во Франции; если что-то из этого изменится, ответ
   пересматривают.
5. В версиях iOS и macOS выбрать эти сборки и отправить на ревью.

* Номер сборки (`N` тега, `CFBundleVersion`) должен быть больше, чем у всех уже загруженных сборок этой платформы,
  даже отклонённых или не прошедших обработку. Загрузить тот же код ещё раз — новый тег на тот же коммит (выше).
* `CODE_SIGN_IDENTITY: "Apple Development"` у Mac в `project.yml` — подпись сборок и архивов: без неё Mac-сборка была
  бы ad hoc и теряла разрешения локальной сети при каждой пересборке (у iPhone xcodegen ставит такую же сам). На App
  Store она не влияет: экспорт переподписывает приложение Apple Distribution с профилем App Store — это и проверяет
  `export`.

### С GitHub

Mac-приложение для GitHub — цель `WaitingPaws-macOS-Direct`: те же исходники, что у App Store-версии, плюс
обновления через Sparkle (`#if WP_DIRECT`, `App/Sources/Mac/Updates/AppUpdater.swift`). В App Store-сборке Sparkle
нет: App Store не принимает приложения со своим обновлятором.

Один раз, владелец (всё хранится в связке ключей «Вход»):

* Сертификат Developer ID Application команды `849CANCD26`. Его может выпустить только Account Holder, и Xcode 27
  ему отказывает (показывает роль Admin), поэтому выпускают на developer.apple.com → Certificates → Developer ID
  Application (G2 Sub-CA) по CSR этого Mac. Резервная копия — `.p12` с паролем. Сертификат действует ~13 месяцев:
  новый выпускают до истечения старого, отзывать старый нельзя (сломает выпущенные сборки).
* Профиль нотаризации `WaitingPaws`: `xcrun notarytool store-credentials WaitingPaws --key
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>` (ключ App Store
  Connect API; Apple ID с паролем приложения отвечал 401). Профиль лежит в защищённой связке ключей, которую macOS
  прячет, пока экран заблокирован («No Keychain password item found»); тогда `WP_NOTARY_KEY_ID=<KEY_ID>
  WP_NOTARY_ISSUER=<ISSUER_ID> Tools/release.sh …` нотаризует тем же ключом напрямую.
* Ключ EdDSA обновлений: `generate_keys --account waitingpaws` из Sparkle (`…/SourcePackages/artifacts/sparkle/
  Sparkle/bin/`). Открытая половина — `WP_UPDATE_PUBLIC_KEY` в `project.yml`.

Каждый выпуск (после `release.sh tag`):

1. `git push origin vX.Y.N` — GitHub Actions собирает Windows и создаёт черновик выпуска со своими файлами.
2. `Tools/release.sh direct vX.Y.N` — архив Direct-цели из чистой копии тега, экспорт с Developer ID
   (`Tools/ExportOptions-DeveloperID.plist`), проверки (подпись, команда, версия, лента, ключ, песочница, hardened
   runtime у Sparkle), нотаризация, staple, Gatekeeper, затем `generate_appcast`. Описание версии для appcast и
   поповера «Обновление» — `Tools/release-notes/X.Y.N.md` (строки `- …`, первые четыре видны в поповере).
   Все zip и растущий `appcast.xml` лежат в `DerivedData/Updates/` (оттуда же дельты); для выпуска —
   `DerivedData/Release/vX.Y.N/github/`.
3. `gh release upload vX.Y.N DerivedData/Release/vX.Y.N/github/* --clobber` — только когда черновик Actions уже
   есть: если у выпуска уже есть файлы, Actions свои не прикрепляет.
4. Опубликовать как Latest. Mac-приложения читают `releases/latest/download/appcast.xml`, поэтому `appcast.xml`
   нужен в каждом выпуске, который становится Latest (и в выпуске только для Windows — тот же файл).
5. `Tools/release.sh publish-nightly refresh` — в ленту тестовых сборок попадает и этот выпуск (без этого
   тестировщики увидят его только со следующей тестовой сборкой).

Тестовые сборки (переключатель «Тестовые сборки» в «О приложении») читают `releases/download/nightly/appcast.xml` —
пререлиз `nightly`, тег которого переезжает на каждую новую сборку (локально такой тег обновляет
`git fetch --tags --force`). На каждый сдвиг тега GitHub Actions собирают Windows того же коммита и кладут его файлы
в тот же пререлиз (см. «Windows» ниже).

* `Tools/release.sh nightly [<ref>]` — сборка `origin/main` (или `<ref>`) тем же путём, что выпуск: Developer ID,
  нотаризация, проверки. Версия `X.Y.(N+1)-nightly.ММДД` (X.Y и N — последнего тега), номер сборки
  `N.ГГММДД.ЧЧММ`: для Sparkle новее выпуска N и старше следующего. Описание — до четырёх заголовков коммитов после
  последнего тега. Zip и лента — в `DerivedData/Updates-nightly/`, для выпуска — `DerivedData/Release/nightly/latest/github/`.
* `Tools/release.sh publish-nightly` — пререлиз `nightly` переезжает на этот коммит (`git push --force` тега), его
  файлы заменяются. В ленту добавляется последний опубликованный выпуск: тестировщик получает его, когда тот новее.
* После выключения тестовых сборок приложение остаётся на тестовой, пока не выйдет следующий выпуск: Sparkle не
  понижает версию.

Windows (установщик с GitHub) обновляется через electron-updater (`Desktop/src/main/updater.ts`) с тем же интерфейсом:
«Обновление» в заголовке окна, «О приложении» → «Обновления» (режим, тестовые сборки, «Проверить сейчас»).

* Лента — `latest.yml` выпуска Latest (`releases/latest/download/latest.yml`); его, установщик и `.blockmap` кладут
  в выпуск Actions по тегу `vX.Y.N`. Загрузка идёт из папки самого выпуска (`releases/download/vX.Y.N/`): в пути
  есть версия, поэтому приложение находит blockmap прошлой версии в её выпуске и качает только изменившиеся блоки.
  Описание — тот же `Tools/release-notes/X.Y.N.md` (Actions кладут его в `latest.yml`).
* С «Тестовыми сборками» приложение читает ещё `releases/download/nightly/latest.yml` и берёт более новую из двух
  версий. Тестовая сборка Windows — `X.Y.(N+1)-nightly.ГГММДДЧЧММ` (время коммита, UTC): semver не допускает
  ведущих нулей, поэтому не `ММДД`, как на Mac.
* Портативный zip и сборки для разработки (`0.0.0`) сами не обновляются. Установщик ставит приложение для всех
  пользователей, поэтому каждое обновление Windows подтверждает окном UAC.
* Проверка без GitHub: `--demo-update [found]` (ждёт 1.7.21: загружена или только найдена),
  `--eval="__wpUI.set({showUpdatePopover:true})"` открывает поповер; в веб-версии — `?demo-update[=found]`.

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

Журнал приложения (stdout/stderr, go2rtc) — `Library/Caches/Logs`, последние 20 запусков, пароли в адресах
(`rtsp://user:pass@…`) маскируются. На Mac: Настройки → Диагностика → «Показать в Finder» (папка
`~/Library/Containers/su.comrade.waitingpaws/Data/Library/Caches/Logs`), с iPhone — `xcrun devicectl device copy from
--device <UDID> --domain-type appDataContainer --domain-identifier su.comrade.waitingpaws --source Library/Caches/Logs
--destination /tmp/wp-iphone-logs`. Первая строка — какая сборка писала: `=== Waiting Paws launch 2026-11-07 13:05:01
+01:00; app 1.7.16 (c041ec9), build 17, built 2026-11-07 12:58; Version 26.1 (Build 25B78); Mac16,1 ===` (сборка из
Xcode — `app dev`, их различает время сборки). Время go2rtc и на iPhone местное.

Подключение к камере Xiaomi по шагам (время от `[player] … mode mse` до `playing` — это ожидание картинки):

* `xiaomi: keys for 192.168.1.20 from Mi Cloud in 640 ms` — ключи сессии из облака, перед каждым подключением;
* `cs2: connected to 192.168.1.20:13780 over UDP in 840 ms (search 120 ms, punch 30 ms)` — камера ответила на поиск
  и пробивку (`search 2011 ms (3 sent)` — на первые пакеты камера не ответила; `…, 2 failed: … no route to host` —
  они даже не ушли с устройства); `cs2: no session with … after 5003 ms: cs2: no answer to the LAN search: … i/o
  timeout (5 sent)` — не ответила совсем;
* `cs2: first video from … 2300 ms after connecting` — первый кадр; `cs2: no video from … 5 s after connecting
  (commands acknowledged 2 of 2)` — сессию камера приняла, а видео не шлёт (обычно она ещё обслуживает другую сессию:
  камера держит одну); `cs2: … acknowledged no try of command 4097 in 5 s` — не отвечает на команды;
* `cs2: closed the session to … after 12.3 s, the camera was told` — закрыли мы (камере отправлено закрытие PPPP);
  `cs2: the session to … ended after …: …` — сессия кончилась сама: таймаут чтения или
  `the camera closed the session` (через полсекунды после подключения — камера ещё держит чужую или брошенную
  сессию: другое устройство, Mi Home, приложение, убитое без выхода); `[app] quitting: N camera session(s) closed` —
  выход из приложения, после него новых сессий нет. Брошенную UDP-сессию камера держит ~15 с; по TCP её нет: когда
  процесс умирает, система сама рвёт соединение;
* `[player] … retry in 1 s` — плеер после неудачной первой попытки пробует снова через 1, 2, 3, 4 и 5 с, дальше как
  в video-rtc.js (не чаще раза в 15 с); картинка начинает счёт заново. На экране отказ камеры — «Камера не отвечает:
  занята другим подключением».

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
* `12:03:30 cs2: connected to 192.168.1.20:13780 over UDP in 840 ms (…)` — как камера подключилась;
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
`--demo-phase away|break|finish` (состояния HUD; `leaving` — шаг «к двери» старых iPhone),
`--demo-exits-done 3` (три выхода уже прошли), `--demo-break-left 70` / `--demo-break-over 25` (сколько осталось
от перерыва / насколько он затянулся), `--demo-edit-plan` (Mac: редактор расписания идущей тренировки),
`--demo-plan-pill 4` (Mac: поле длительности выхода 4 на таймлайне),
`--demo-finish-after 12` (завершить через
12 с, проверяет запись и сохранение в Фото), `--demo-clip 10` (записать 10 с без тренировки),
`--demo-camera-steps 12:main:camC,24:main:camB,36:second:camA,48:remove,60:restream:camA=rtsp://…` (через столько
секунд после запуска выбрать основную камеру, вторую — она выходит на экран, — убрать вторую или заново
зарегистрировать поток под тем же именем, как при смене качества; всё кодом настоящего выбора камеры: запись должна
идти с той, что на экране. Не с `--ui-preview`: там выбор камеры настроек не пишет. Потоки — из тестового go2rtc,
см. выше; запись потом разбирают `ffprobe -show_frames`: размер кадра меняется на каждой смене),
`--demo-screen plan|plan-twice|camera|history|history-last|session-plan` (открыть лист расписания,
открыть-закрыть-открыть его, выбор камеры, историю, сразу последнюю запись в ней или расписание идущей тренировки),
`--demo-parse -demoPlanText <текст>` (сразу разобрать
этот текст и показать редактор), `--demo-plan-edit` (редактор сразу в режиме «Править»),
`--demo-duration-editor` (открыть выбор перерыва после первого выхода), `--perf` (строка нагрузки),
`--demo-screen settings-training` (настройки iPhone, сразу на «Тренировке»: вибрация и уведомления).
Связка: `--demo-hosts` (на iPhone рядом два Mac и ПК, ничего не слушает), `--demo-screen settings-sync` (настройки
iPhone, сразу на «Синхронизации»), на Mac — `--demo-iphone` (подключённый и разрешённые iPhone), `--demo-pairing`
(запрос «Подключить?»), `--demo-settings-pane iPhone` (настройки сразу на панели iPhone). На iPhone без сети:
`--demo-mac-session` (связан с Mac, на котором идёт демонстрационная тренировка; Mac живёт в памяти приложения),
`--demo-mac-lag 2.5` (команды доходят до него и состояния возвращаются через 2,5 с — плохой Wi-Fi: нажатия должны
показываться сразу), `--demo-remote-steps` (через 3 с после начала нажать «Вышли»), `--demo-remote-finish` (затем
«Вернулись», запись и «Завершить»).
Камера: `--demo-camera-modes` (настройки C302 в памяти; камера считается поворотной, шаги только подсвечивают стрелки),
`--demo-pan-tilt` (вместе с ним: режим поворота сразу включён), `--demo-camera-only` («Только камера»),
`--demo-panel-sweep` (Mac: панель «Пульта» проходит ширины от 340 до 720, складывается и открывается. В журнал
пишется `[toolbar] camera group ends N pt before the panel's edge`, при наложении — `RUNS OVER THE EDGE`. Сборку
для этого делайте без подписи, `CODE_SIGNING_ALLOWED=NO`: подписанная работает в контейнере приложения и
записала бы ширину панели в ваши настройки), `--demo-window-cycle dock,zoom,dockzoom,full,close` (Mac: окно уходит в
Dock и обратно, увеличивается и обратно, в полный экран и обратно, закрывается; после каждого шага в журнал пишется
`[cycle] after …` — сколько занимают кнопки и где кончается группа камеры по AppKit и по пробе, при наложении —
`RUNS OVER THE EDGE`. После `[cycle] closed` откройте приложение снова, как из Dock: `open <путь к .app>`. Размер
окна: `-"NSWindow Frame main" "279 132 1393 802 0 0 1728 1084 "`). История на Mac:
`--history-no-inspector` (инспектор закрыт), `--history-toggle-inspector 5` (открыть/закрыть его через 5 с — снять,
как поле поиска переезжает), остальные флаги — в `MacHistoryDebug.swift`.

## Планы

* Другие платформы камер — любой источник, который понимает go2rtc, уже можно выбрать как поток;
  отдельный мастер пока есть только для Xiaomi. Чтобы добавить модули go2rtc во встроенную сборку,
  допишите их `Init()` в `GoMobile/mobile/mobile.go` и пересоберите фреймворк.
* Push-уведомления/виджет для таймера, Live Activity на iOS.
