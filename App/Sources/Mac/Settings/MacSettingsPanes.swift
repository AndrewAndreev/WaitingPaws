#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// The grouped form on the right of Settings.
struct MacSettingsDetail: View {
    let pane: MacSettingsPane
    @Binding var sheet: MacSettingsSheet?

    var body: some View {
        Form {
            switch pane {
            case .camera: SettingsCameraPane(sheet: $sheet)
            case .connection: SettingsConnectionPane()
            case .training: SettingsTrainingPane()
            case .files: SettingsFilesPane()
            case .iPhone: SettingsIPhonePane()
            case .diagnostics: SettingsDiagnosticsPane()
            case .about: SettingsAboutPane()
            }
        }
        .formStyle(.grouped)
    }
}

/// The camera Settings describe: the saved one, or (DEBUG `--demo-cameras`, nothing saved) the demo camera.
struct SettingsCamera {
    var isConfigured: Bool
    var name: String
    var streamName: String
    var accountID: String
    var region: XiaomiRegion
    var isXiaomi: Bool
    var isDemo = false

    /// `source`: the stream's source once read from go2rtc — it settles whether this is a Mi Home camera.
    /// Without it the quality go2rtc reported decides; the saved account only while go2rtc is not running
    /// (it stays saved after switching to an RTSP stream).
    @MainActor
    init(_ model: AppModel, source: String? = nil) {
        let settings = model.settings
        #if DEBUG
        if SetupDemo.isOn && !settings.isConfigured {
            isDemo = true
            region = .ru
            if SetupDemo.hasXiaomi {
                isConfigured = true
                name = SetupDemo.cameraName
                streamName = SetupDemo.cameraStream
                accountID = SetupDemo.accountID
                isXiaomi = true
            } else {
                isConfigured = SetupDemo.hasStreams
                name = isConfigured ? SetupDemo.rtspStream : ""
                streamName = isConfigured ? SetupDemo.rtspStream : ""
                accountID = ""
                isXiaomi = false
            }
            return
        }
        #endif
        isConfigured = settings.isConfigured
        name = settings.cameraDisplayName
        streamName = settings.streamName
        accountID = settings.xiaomiAccountID
        region = settings.xiaomiRegion
        if let source {
            isXiaomi = source.hasPrefix("xiaomi://")
        } else if model.setupServerReady {
            isXiaomi = model.xiaomiQuality != nil
        } else {
            isXiaomi = !settings.xiaomiAccountID.isEmpty
        }
    }
}

/// System Settings pane header: big icon, name, one line about the pane.
private struct SettingsPaneHeader: View {
    let pane: MacSettingsPane
    let text: String

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SetupIconTile(symbol: pane.symbol, color: pane.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Камера

private struct SettingsCameraPane: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: MacSettingsSheet?
    @State private var reloadToken = 0
    @State private var switchingQuality = false
    /// The stream's source as written in the go2rtc config.
    @State private var source: String?
    /// Xiaomi accounts signed in on go2rtc; `nil` while unknown (go2rtc not running, no xiaomi module).
    @State private var accounts: [String]?
    @State private var demoQuality: AppModel.XiaomiQuality = .auto
    /// «Выйти…» asked for this account (confirmation shown).
    @State private var signOutAccount: String?
    @State private var signingOut: String?

    var body: some View {
        @Bindable var settings = model.settings
        let camera = SettingsCamera(model, source: source)

        Section {
            VStack(spacing: 10) {
                SettingsCameraCard(camera: camera, reloadToken: $reloadToken) { sheet = .picker(accountID: nil) }
                    .frame(width: 400)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                VStack(spacing: 2) {
                    Text(camera.isConfigured ? camera.name : String(localized: "Камера не выбрана"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(detailLine(camera))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cameraModel(camera).map { String(localized: "Модель Mi Home: \($0)") } ?? "")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .task(id: settings.streamName) { await load(camera) }
        // Again after a sign-in or a camera change in a sheet.
        .task(id: "\(model.setupServerReady)|\(sheet == nil)") { await loadAccounts() }

        if accounts?.isEmpty == true {
            // No Xiaomi account on go2rtc: the way to Mi Home cameras, right under the picture.
            Section {
                SetupMiHomeSignInCard(style: .formRow) { sheet = .signIn }
            }
        }

        Section {
            LabeledContent {
                Picker("Качество", selection: quality(camera)) {
                    ForEach(AppModel.XiaomiQuality.allCases) { Text(model.qualityTitle($0, source: source)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!qualityAvailable(camera) || switchingQuality)
            } label: {
                Text("Качество")
                if !camera.isConfigured {
                    Text("Сначала выберите камеру.")
                } else if !qualityAvailable(camera) {
                    Text("Меняется только у камер Mi Home.")
                } else {
                    Text("На экране и в записи.")
                }
            }
            LabeledContent("Сейчас") {
                HStack(spacing: 6) {
                    if switchingQuality { ProgressView().controlSize(.mini) }
                    Text(currentSize(camera)).monospacedDigit()
                }
            }
            Picker("Плеер", selection: $settings.playerMode) {
                ForEach(settings.availablePlayerModes) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $settings.audioEnabled) {
                Text("Звук с камеры в приложении")
                Text("Только для плеера: запись всегда со звуком.")
            }
        } header: {
            Text("Изображение и звук")
        } footer: {
            if settings.connectionMode == .embedded {
                Text("WebRTC (минимальная задержка) доступен только со своим сервером go2rtc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        SettingsCameraModesSection(camera: camera)

        Section {
            LabeledContent("Поток go2rtc") {
                Text(camera.isConfigured ? camera.streamName : "—")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let source, !source.hasPrefix("xiaomi://") {
                LabeledContent("Источник") {
                    Text(SettingsText.redacted(source))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if camera.isXiaomi {
                LabeledContent("Аккаунт Xiaomi",
                               value: camera.accountID.isEmpty ? "—" : "ID \(camera.accountID) · \(SetupText.regionTitle(camera.region))")
            }
        } header: {
            Text("Источник")
        } footer: {
            HStack(spacing: 8) {
                Spacer()
                // With no account the card above already offers the sign-in.
                if accounts?.isEmpty != true {
                    Button(accounts == nil ? "Войти в Xiaomi…" : "Войти в другой аккаунт Xiaomi…") { sheet = .signIn }
                }
                Button("Выбрать камеру…") { sheet = .picker(accountID: nil) }
            }
        }

        if let accounts, !accounts.isEmpty {
            Section {
                ForEach(accounts, id: \.self) { account in
                    LabeledContent {
                        if signingOut == account {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Выйти…") { signOutAccount = account }
                                .disabled(signingOut != nil)
                        }
                    } label: {
                        Label("ID \(account)", systemImage: "person.crop.circle")
                    }
                }
            } header: {
                Text("Аккаунты Xiaomi")
            } footer: {
                Text("После выхода ключ доступа Xiaomi удаляется с этого Mac, а камеры аккаунта — из приложения.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .alert("Выйти из аккаунта Xiaomi?", isPresented: Binding(get: { signOutAccount != nil },
                                                                   set: { if !$0 { signOutAccount = nil } })) {
                Button("Выйти", role: .destructive) {
                    guard let account = signOutAccount else { return }
                    signingOut = account
                    Task {
                        await model.signOutOfXiaomi(accountID: account)
                        signingOut = nil
                        await loadAccounts()
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Камеры этого аккаунта перестанут показываться. Войти снова можно в любой момент.")
            }
        }
    }

    private func qualityAvailable(_ camera: SettingsCamera) -> Bool {
        camera.isDemo ? camera.isXiaomi : model.xiaomiQuality != nil
    }

    /// "Камера Xiaomi · аккаунт 6218440137" (the Mi Home model id stays in the tooltip) or "RTSP · 192.168.1.20".
    private func detailLine(_ camera: SettingsCamera) -> String {
        guard camera.isConfigured else { return String(localized: "Выберите камеру Mi Home или поток go2rtc.") }
        if camera.isXiaomi {
            return [SetupText.cameraKind(model: cameraModel(camera)),
                    camera.accountID.isEmpty ? nil : String(localized: "аккаунт \(camera.accountID)")].compactMap { $0 }.joined(separator: " · ")
        }
        if let source, let badge = SetupText.sourceBadge(source) {
            let host = URLComponents(string: source)?.host
            return [badge, host].compactMap { $0 }.joined(separator: " · ")
        }
        return String(localized: "Поток go2rtc")
    }

    private func cameraModel(_ camera: SettingsCamera) -> String? {
        source.flatMap { SetupCameraCatalog.query("model", in: $0) }
    }

    private func currentSize(_ camera: SettingsCamera) -> String {
        #if DEBUG
        if camera.isDemo, camera.isConfigured, case .loaded(_, let size) = SetupDemo.still(for: camera.streamName) {
            return SetupText.pixels(size)
        }
        #endif
        guard let size = model.videoSize else { return camera.isConfigured ? "—" : String(localized: "нет камеры") }
        return SetupText.pixels(size)
    }

    private func quality(_ camera: SettingsCamera) -> Binding<AppModel.XiaomiQuality> {
        Binding {
            camera.isDemo ? demoQuality : (model.xiaomiQuality ?? .auto)
        } set: { new in
            if camera.isDemo {
                demoQuality = new
                return
            }
            guard new != model.xiaomiQuality, !switchingQuality else { return }
            switchingQuality = true
            Task {
                await model.setXiaomiQuality(new)
                switchingQuality = false
            }
        }
    }

    private func loadAccounts() async {
        #if DEBUG
        if SetupDemo.isOn {
            accounts = SetupDemo.accounts.map(\.id)
            return
        }
        #endif
        guard model.setupServerReady, let client = model.client else {
            accounts = nil
            return
        }
        // A server without the xiaomi module answers 404: unknown, no sign-in card then.
        accounts = try? await client.xiaomiAccounts()
    }

    private func load(_ camera: SettingsCamera) async {
        source = nil
        #if DEBUG
        if camera.isDemo {
            source = SetupDemo.streams.first { $0.name == camera.streamName }?.sources.first
            return
        }
        #endif
        guard camera.isConfigured, model.setupServerReady, let client = model.client else { return }
        await model.refreshXiaomiQuality()
        // Again on every visit: the modes may have been changed in Mi Home meanwhile.
        await model.refreshCameraModes()
        let name = model.settings.streamName
        var sources = (try? await client.configuredSources(stream: name)) ?? []
        if sources.isEmpty {
            sources = (try? await client.streams())?.first { $0.name == name }?.sources ?? []
        }
        source = sources.first
    }
}

/// Night mode, image flip, status light… as the camera's MIoT spec declares them (Mi Home cameras only).
private struct SettingsCameraModesSection: View {
    @Environment(AppModel.self) private var model
    let camera: SettingsCamera

    var body: some View {
        let modes = model.cameraModes
        if modes.hasOptions {
            Section {
                ForEach(modes.pictureOptions) { CameraModeFormRow(option: $0) }
                ForEach(modes.behaviourOptions) { CameraModeFormRow(option: $0) }
            } header: {
                HStack(spacing: 6) {
                    Text("Режим камеры")
                    if modes.state == .loading || !modes.pending.isEmpty { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Group {
                    if let error = modes.changeError {
                        Text(error).foregroundStyle(.red)
                    } else if case .unavailable(let reason) = modes.state {
                        Text(reason).foregroundStyle(.orange)
                    } else {
                        Text("Настройки хранятся в самой камере и меняются через облако Xiaomi, как в Mi Home.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
        } else if camera.isXiaomi, modes.state == .loading {
            Section("Режим камеры") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Читаю настройки камеры…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The live picture on top of the Camera pane (the same go2rtc player as the training window, muted).
private struct SettingsCameraCard: View {
    @Environment(AppModel.self) private var model
    let camera: SettingsCamera
    @Binding var reloadToken: Int
    var choose: () -> Void
    @State private var liveSize: CGSize?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            picture
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let chip = chipText {
                HStack(spacing: 6) {
                    if liveSize == nil && !camera.isDemo {
                        ProgressView().controlSize(.mini)
                    } else {
                        StatusDot(size: 6)
                    }
                    Text(chip)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .glassEffect(.regular, in: .capsule)
                .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isPlaying {
                Button {
                    liveSize = nil
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 24)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Переподключить камеру")
                .padding(8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .onChange(of: camera.streamName) { liveSize = nil }
    }

    private var isPlaying: Bool {
        camera.isConfigured && !camera.isDemo && model.setupServerReady && model.settings.server != nil
    }

    private var chipText: String? {
        if camera.isDemo {
            guard case .loaded(_, let size) = demoStill else { return nil }
            return String(localized: "В эфире · \(SetupText.pixels(size))")
        }
        guard isPlaying else { return nil }
        return liveSize.map { String(localized: "В эфире · \(SetupText.pixels($0))") } ?? String(localized: "Подключение…")
    }

    @ViewBuilder
    private var picture: some View {
        if camera.isDemo, let image = demoImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if isPlaying, let server = model.settings.server {
            CameraStreamView(server: server, stream: camera.streamName, mode: model.settings.playerMode,
                             audioEnabled: false, fill: true, reloadToken: reloadToken + model.playerGeneration) { size in
                liveSize = size
                model.videoSize = size
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "video.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text(placeholderText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                if !camera.isConfigured {
                    Button("Выбрать камеру…", action: choose)
                        .buttonStyle(.borderedProminent)
                        .tint(MacPalette.pinkDeep)
                }
            }
        }
    }

    private var placeholderText: String {
        guard camera.isConfigured else { return String(localized: "Здесь будет картинка с камеры") }
        switch SetupServerState.of(model) {
        case .starting: return String(localized: "Запускаем go2rtc…")
        case .failed, .stopped, .unavailable: return String(localized: "go2rtc не запущен")
        default: return String(localized: "Нет картинки")
        }
    }

    private var demoImage: NSImage? {
        guard case .loaded(let image, _) = demoStill else { return nil }
        return image
    }

    private var demoStill: SetupStillStore.State? {
        #if DEBUG
        guard camera.isDemo, camera.isConfigured else { return nil }
        return SetupDemo.still(for: camera.streamName)
        #else
        return nil
        #endif
    }
}

// MARK: - Подключение

private struct SettingsConnectionPane: View {
    @Environment(AppModel.self) private var model
    @State private var check: SetupServerSheet.Check = .idle

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPaneHeader(pane: .connection, text: String(localized: "Где работает go2rtc — сервер, который забирает видео с камеры Xiaomi."))
        Section {
            Picker("Режим", selection: $settings.connectionMode) {
                ForEach(ConnectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: settings.connectionMode) {
                model.startEmbeddedIfNeeded()
                check = .idle
            }
            if settings.connectionMode == .embedded {
                LabeledContent("Состояние") {
                    SetupServerStatusLabel()
                }
                LabeledContent("Адрес", value: "127.0.0.1:\(EmbeddedGo2RTC.apiPort)")
                LabeledContent {
                    Button("Показать в Finder") { Finder.reveal(EmbeddedGo2RTC.configURL) }
                } label: {
                    Text("Файл go2rtc.yaml")
                    Text("Потоки и вход в Xiaomi. Не пересылайте его: в нём токены.")
                }
            }
        } footer: {
            Text(settings.connectionMode == .embedded
                 ? "go2rtc работает внутри приложения, камера должна быть в той же Wi‑Fi сети. Видео и запись идут, пока приложение открыто."
                 : "Отдельный сервер go2rtc в сети: подходит, если нужна постоянная запись или доступ не из дома.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section {
            TextField("Адрес", text: $settings.serverURLString, prompt: Text("http://192.168.1.10:1984"))
                .plainInput()
            TextField("Логин", text: $settings.serverUsername, prompt: Text("Необязательно"))
                .plainInput()
            SecureField("Пароль", text: $settings.serverPassword, prompt: Text("Необязательно"))
            HStack(spacing: 8) {
                result
                Spacer(minLength: 8)
                Button("Проверить") { Task { await runCheck() } }
                    .disabled(check == .checking || Go2RTCServer.parse(settings.serverURLString) == nil)
            }
        } header: {
            Text("Свой сервер")
        }
        .disabled(settings.connectionMode == .embedded)
        .onChange(of: settings.serverURLString) { check = .idle }
    }

    @ViewBuilder
    private var result: some View {
        switch check {
        case .idle:
            Text("Нужна версия 1.9.11 или новее с модулем xiaomi.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let version):
            Label(version.isEmpty ? "Сервер отвечает" : "go2rtc \(version) отвечает", systemImage: "checkmark.circle.fill")
                .foregroundStyle(MacPalette.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(MacPalette.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private func runCheck() async {
        guard let server = model.settings.server, model.settings.connectionMode == .external else {
            check = .failed(String(localized: "Некорректный адрес"))
            return
        }
        check = .checking
        do {
            check = .ok(try await Go2RTCClient(server: server).version())
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Тренировка

private struct SettingsTrainingPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPaneHeader(pane: .training, text: String(localized: "Что происходит в начале и в конце тренировки."))
        Section {
            Toggle(isOn: $settings.autoRecord) {
                Text("Включать запись вместе с тренировкой")
                Text("Видео с камеры пишется от начала тренировки до конца.")
            }
            Toggle(isOn: $settings.autoFinishAfterLastBreak) {
                Text("Завершать автоматически")
                Text("После перерыва за последним выходом: запись и лог сохраняются сами.")
            }
        }
    }
}

// MARK: - Запись и файлы

private struct SettingsFilesPane: View {
    @Environment(AppModel.self) private var model
    @State private var usage: String?

    var body: some View {
        @Bindable var settings = model.settings
        let folder = model.store.rootDirectory
        SettingsPaneHeader(pane: .files, text: String(localized: "Видео и логи тренировок хранятся на этом Mac."))
        Section {
            LabeledContent {
                Button("Показать в Finder") { Finder.reveal(folder) }
            } label: {
                Label {
                    Text(folder.lastPathComponent)
                    Text(SettingsText.displayPath(folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color(red: 0.32, green: 0.64, blue: 0.98))
                }
            }
            LabeledContent("Занято", value: usage ?? String(localized: "Считаем…"))
        }
        .task(id: model.history.count) { usage = await SettingsText.usage(of: model.store) }
        Section {
            Toggle(isOn: $settings.saveToPhotos) {
                Text("Сохранять видео в Фото")
                Text("Копия каждой записи попадает в медиатеку «Фото».")
            }
        }
    }
}

// MARK: - iPhone

private struct SettingsIPhonePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let host = model.syncHost
        SettingsPaneHeader(pane: .iPhone, text: String(localized: "iPhone в той же сети показывает камеру этого Mac и ведёт тренировку."))
        Section {
            Toggle(isOn: $settings.shareWithIPhone) {
                Text("Разрешить подключение с iPhone")
                Text("Mac виден приложению Waiting Paws на iPhone в той же Wi‑Fi сети.")
            }
            .onChange(of: settings.shareWithIPhone) { _, on in
                guard !AppModel.isUIPreview else { return }
                if on { host.start() } else { host.stop() }
            }
        } footer: {
            if settings.shareWithIPhone && !model.embedded.lanEnabled && settings.connectionMode == .embedded {
                Label("Видео для iPhone станет доступно после перезапуска Waiting Paws.", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            if host.pairedDevices.isEmpty {
                Text("Пока ни один iPhone не подключался.")
                    .foregroundStyle(.secondary)
            }
            ForEach(host.pairedDevices) { device in
                let online = host.connectedDevices.contains(device.name)
                LabeledContent {
                    Button("Забыть") { host.forget(device) }
                } label: {
                    Label {
                        Text(device.name)
                        Text(online ? "Подключён сейчас" : "Подключение разрешено")
                    } icon: {
                        Image(systemName: "iphone")
                            .foregroundStyle(online ? MacPalette.green : .secondary)
                    }
                }
            }
        } header: {
            Text("Разрешённые iPhone")
        } footer: {
            Text("Первое подключение каждого iPhone нужно разрешить на этом Mac. Запись и лог остаются на Mac. После «Забыть» iPhone снова попросит разрешения.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Диагностика

private struct SettingsDiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPaneHeader(pane: .diagnostics, text: String(localized: "Нагрузка на процессор и память — если видео подтормаживает."))
        Section {
            Toggle(isOn: $settings.showPerformance) {
                Text("Показывать нагрузку")
                Text("CPU приложения, память и задержки интерфейса. Видео в WebKit считается отдельно.")
            }
            .onChange(of: settings.showPerformance) { _, on in
                if on { model.performance.start() } else { model.performance.stop() }
            }
            if model.performance.isRunning {
                LabeledContent("Сейчас", value: SettingsText.performance(model.performance.sample))
                    .monospacedDigit()
            }
        }
        Section {
            LabeledContent {
                Button("Показать в Finder") {
                    Finder.reveal(AppModel.logsDirectory)
                }
            } label: {
                Text("Журнал приложения")
                Text("Пригодится, если камера не подключается или запись оборвалась.")
            }
        }
    }
}

// MARK: - О приложении

private struct SettingsAboutPane: View {
    @State private var showPrivacy = false
    @State private var showLicenses = false

    var body: some View {
        SettingsPaneHeader(pane: .about, text: String(localized: "Версия, политика конфиденциальности и лицензии."))
        Section {
            LabeledContent("Версия", value: AppInfo.version)
            LabeledContent("Политика конфиденциальности") {
                Button("Открыть…") { showPrivacy = true }
            }
            LabeledContent("Лицензии открытого ПО") {
                Button("Открыть…") { showLicenses = true }
            }
        } footer: {
            Text("Waiting Paws ничего не собирает и не отправляет разработчику: настройки, логи и видео остаются на ваших устройствах.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showPrivacy) { AboutSheet { PrivacyPolicyView() } }
        .sheet(isPresented: $showLicenses) { AboutSheet { LicensesView() } }
    }
}

/// The privacy policy or the licenses over Settings, with «Готово».
private struct AboutSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - Text helpers

enum SettingsText {
    /// The real path with "~" for the user's home (in the sandbox `NSHomeDirectory()` is the container).
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A source URL without its password ("rtsp://admin:secret@…" → "rtsp://admin@…").
    static func redacted(_ source: String) -> String {
        guard var components = URLComponents(string: source), components.password != nil else { return source }
        components.password = nil
        return components.string ?? source
    }

    /// "3,9 ГБ · 13 видео · 11 логов" / "3.9 GB · 13 videos · 11 logs".
    static func usage(of store: SessionStore) async -> String {
        let root = store.rootDirectory
        let recordings = store.recordingsDirectory
        let sessions = store.sessionsDirectory
        return await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let bytes = folderSize(root)
            let videos = ((try? manager.contentsOfDirectory(atPath: recordings.path)) ?? []).filter { $0.hasSuffix(".mp4") }.count
            let logs = ((try? manager.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { $0.hasSuffix(".json") }.count
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            guard videos > 0 || logs > 0 else { return bytes > 0 ? String(localized: "\(size) · тренировок пока нет") : String(localized: "Пока пусто") }
            var parts = [size]
            if videos > 0 { parts.append(pluralText(videos, ru: ("видео", "видео", "видео"), en: ("video", "videos"))) }
            if logs > 0 { parts.append(pluralText(logs, ru: ("лог", "лога", "логов"), en: ("log", "logs"))) }
            return parts.joined(separator: " · ")
        }.value
    }

    private static func folderSize(_ root: URL) -> Int64 {
        var bytes: Int64 = 0
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return bytes
    }

    /// "CPU 14 % · главный поток 3 % · 212 МБ · UI +18 мс · 41 поток".
    static func performance(_ sample: PerformanceMonitor.Sample) -> String {
        [
            String(localized: "CPU \(Int(sample.cpuTotal.rounded())) %"),
            String(localized: "главный поток \(Int(sample.cpuMain.rounded())) %"),
            String(localized: "\(Int(sample.memoryMB.rounded())) МБ"),
            String(localized: "UI +\(Int(sample.maxHangMs.rounded())) мс"),
            pluralText(sample.threads, ru: ("поток", "потока", "потоков"), en: ("thread", "threads")),
        ].joined(separator: " · ")
    }
}
#endif
