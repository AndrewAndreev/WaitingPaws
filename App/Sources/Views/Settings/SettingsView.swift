import SwiftUI
import WaitingPawsCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var checkStatus = ""
    @State private var showXiaomi = false
    @State private var showCameraPicker = false
    @State private var confirmSignOut = false
    @State private var signingOut = false
    /// «Свой сервер go2rtc» picked while there's no address yet: the mode switches with «Подключить». Switched at once,
    /// the app would be left without a camera and go back to the first-launch setup.
    @State private var choosingServer = false
    /// What the address field shows while it isn't an address (see `address`).
    @State private var addressDraft: String?
    #if os(iOS)
    /// «Забыть» tapped for this computer (confirmation shown).
    @State private var forgetHost: SyncClient.PairedHost?
    #endif

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Режим", selection: modeSelection) {
                        ForEach(ConnectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .onChange(of: settings.connectionMode) { _, _ in
                        model.startEmbeddedIfNeeded()
                        checkStatus = ""
                    }
                    if settings.connectionMode == .embedded && !choosingServer {
                        LabeledContent("Состояние", value: embeddedStatusText)
                    } else {
                        TextField("Адрес", text: address, prompt: Text("http://192.168.1.10:1984"))
                            .plainInput()
                        TextField("Логин", text: $settings.serverUsername)
                            .plainInput()
                        SecureField("Пароль", text: $settings.serverPassword)
                        HStack {
                            if choosingServer {
                                Button("Подключить") {
                                    choosingServer = false
                                    settings.connectionMode = .external
                                }
                                .disabled(Go2RTCServer.parse(address.wrappedValue) == nil)
                            } else {
                                Button("Проверить") { Task { await check() } }
                            }
                            Spacer()
                            Text(checkStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Подключение")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.connectionMode == .embedded && !choosingServer
                             ? "go2rtc работает внутри приложения, камера должна быть в той же Wi-Fi сети. Видео и запись идут, пока приложение открыто."
                             : "Отдельный сервер go2rtc в сети: подходит, если нужен доступ не из дома или постоянная запись.")
                        if isBusy { Text("Во время тренировки или записи сервер не меняется.") }
                    }
                }
                .disabled(isBusy)

                Section {
                    LabeledContent("Поток", value: settings.cameraDisplayName.isEmpty ? "—" : settings.cameraDisplayName)
                    #if WP_NO_XIAOMI // a build without Xiaomi (`NoXiaomiText`): no account, no sign-in
                    Button("Выбрать камеру…") { showCameraPicker = true }
                    #else
                    LabeledContent("Аккаунт Xiaomi", value: settings.xiaomiAccountID.isEmpty ? "—" : "ID \(settings.xiaomiAccountID) · \(settings.xiaomiRegion.rawValue)")
                    Button("Выбрать камеру…") { showCameraPicker = true }
                    if settings.xiaomiAccountID.isEmpty {
                        Button("Войти в аккаунт Xiaomi…") { showXiaomi = true }
                    } else {
                        Button("Войти в другой аккаунт Xiaomi…") { showXiaomi = true }
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            HStack {
                                Text("Выйти из аккаунта Xiaomi")
                                if signingOut { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(signingOut)
                    }
                    #endif
                } header: {
                    Text("Камера")
                } footer: {
                    #if !WP_NO_XIAOMI
                    if !settings.xiaomiAccountID.isEmpty {
                        Text("После выхода ключ доступа Xiaomi удаляется с устройства, а камеры этого аккаунта — из приложения.")
                    }
                    #endif
                }

                Section {
                    Picker("Режим", selection: $settings.playerMode) {
                        ForEach(settings.availablePlayerModes) { mode in Text(mode.title).tag(mode) }
                    }
                    Toggle("Звук с камеры в приложении", isOn: $settings.audioEnabled)
                } header: {
                    Text("Плеер")
                } footer: {
                    Text("Звук только в плеере; видео всегда записывается со звуком камеры.")
                }

                Section {
                    Toggle("Включать запись вместе с тренировкой", isOn: $settings.autoRecord)
                    Toggle("Сохранять видео в Фото", isOn: $settings.saveToPhotos)
                    #if os(iOS)
                    Toggle("Вибрация", isOn: $settings.haptics)
                    TrainingAlertsToggle(isOn: $settings.notifications)
                    #endif
                } header: {
                    Text("Тренировка")
                } footer: {
                    #if os(iOS)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Короткая вибрация, когда выходит время: план выхода, перерыв, отсчёт условия или тишина. Это сигнал таймера, а не разрешение входить.")
                        Text("Когда приложение свёрнуто или экран заблокирован, о том же скажет уведомление — без звука, чтобы не услышала собака.")
                    }
                    #endif
                }

                #if os(iOS)
                macSection
                #endif

                #if os(macOS)
                Section {
                    Toggle("Разрешить подключение с iPhone", isOn: $settings.shareWithIPhone)
                        .onChange(of: settings.shareWithIPhone) { _, on in
                            if on { model.syncHost.start() } else { model.syncHost.stop() }
                        }
                    ForEach(model.syncHost.pairedDevices) { device in
                        LabeledContent(device.name) {
                            Button("Забыть") { model.syncHost.forget(device) }
                        }
                    }
                } header: {
                    Text("iPhone")
                } footer: {
                    Text(settings.shareWithIPhone && !model.embedded.lanEnabled && settings.connectionMode == .embedded
                         ? "iPhone в той же сети найдёт этот Mac, покажет его камеру и сможет вести тренировку. Видео для iPhone станет доступно после перезапуска приложения."
                         : "iPhone в той же сети найдёт этот Mac, покажет его камеру и сможет вести тренировку. Запись и лог остаются на Mac. Первое подключение каждого iPhone нужно разрешить здесь.")
                }
                #endif

                Section("Диагностика") {
                    Toggle("Показывать нагрузку", isOn: $settings.showPerformance)
                        .onChange(of: settings.showPerformance) { _, on in
                            if on { model.performance.start() } else { model.performance.stop() }
                        }
                    Text("Над камерой: на сколько секунд картинка отстаёт от камеры (сеть и буфер плеера), CPU, память и подвисания интерфейса.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    #if os(macOS)
                    Button("Показать в Finder") { Finder.reveal(model.store.rootDirectory) }
                    #else
                    Text("Видео и логи доступны в приложении «Файлы» → На iPhone → Waiting Paws.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                } header: {
                    Text("Файлы")
                }

                Section {
                    LabeledContent("Версия", value: AppInfo.version)
                    NavigationLink("Политика конфиденциальности") { PrivacyPolicyView() }
                    NavigationLink("Лицензии открытого ПО") { LicensesView() }
                } header: {
                    Text("О приложении")
                }
            }
            .formStyle(.grouped)
            #if DEBUG && os(iOS)
            // `--demo-screen settings-sync`: opens scrolled to «Синхронизация» (UI checks without scrolling).
            .onAppear {
                guard CommandLine.arguments.contains("settings-sync") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("sync", anchor: .top) }
            }
            #endif
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            #if !WP_NO_XIAOMI
            .sheet(isPresented: $showXiaomi) {
                XiaomiSignInSheet { _ in
                    showXiaomi = false
                    showCameraPicker = true
                }
                .environment(model)
                .sheetFrame(width: 520, height: 620)
            }
            .confirmationDialog("Выйти из аккаунта Xiaomi?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    let account = settings.xiaomiAccountID
                    signingOut = true
                    Task {
                        await model.signOutOfXiaomi(accountID: account)
                        signingOut = false
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Камеры этого аккаунта перестанут показываться. Войти снова можно в любой момент.")
            }
            #endif
            .sheet(isPresented: $showCameraPicker) {
                NavigationStack {
                    CameraPickerView(showsClose: true) { _ in
                        showCameraPicker = false
                    }
                }
                .environment(model)
                .sheetFrame(width: 520, height: 560)
            }
            #if os(iOS)
            .confirmationDialog(forgetHost.map { String(localized: "Забыть «\($0.device.name)»?") } ?? "",
                                isPresented: Binding(get: { forgetHost != nil }, set: { if !$0 { forgetHost = nil } }),
                                titleVisibility: .visible, presenting: forgetHost) { host in
                Button("Забыть", role: .destructive) { model.syncClient.forget(host.id) }
                Button("Отмена", role: .cancel) {}
            } message: { host in
                Text(forgetMessage(host))
            }
            #endif
        }
    }

    /// A training or a recording runs here: switching the server would cut the camera (and the recording) off. One on
    /// a linked Mac doesn't use this iPhone's server.
    private var isBusy: Bool {
        (model.session != nil && !model.isMirroringSession) || (model.isRecordingNow && !model.isLinkedToMac)
    }

    /// The server's address. With «Свой сервер» on, text that isn't an address (a cleared field, one being retyped)
    /// stays in the field only: saved, it would leave the app without a server and send it back to the first-launch setup.
    private var address: Binding<String> {
        Binding(get: { addressDraft ?? model.settings.serverURLString },
                set: { text in
                    let usable = model.settings.connectionMode == .embedded || Go2RTCServer.parse(text) != nil
                    addressDraft = usable ? nil : text
                    if usable { model.settings.serverURLString = text }
                })
    }

    /// «Свой сервер go2rtc» without a usable address only opens the server's fields (see `choosingServer`).
    private var modeSelection: Binding<ConnectionMode> {
        Binding(get: { choosingServer ? .external : model.settings.connectionMode },
                set: { mode in
                    choosingServer = mode == .external && model.settings.connectionMode == .embedded
                        && Go2RTCServer.parse(model.settings.serverURLString) == nil
                    if !choosingServer { model.settings.connectionMode = mode }
                })
    }

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle: return String(localized: "не запущен")
        case .starting: return String(localized: "запускается…")
        case .running(let version): return String(localized: "работает, go2rtc \(version)")
        case .failed(let message): return String(localized: "ошибка: \(message)")
        case .unavailable: return String(localized: "фреймворк не собран")
        }
    }

    #if os(iOS)
    /// The way to a computer that is always there (the «Рядом Mac» card on the main screen can be closed or pushed
    /// out): which one to sync with, this iPhone's name for them, and the ones joined before (to forget).
    @ViewBuilder
    private var macSection: some View {
        @Bindable var settings = model.settings
        let client = model.syncClient
        Section {
            LabeledContent("Имя этого \(SyncIdentity.platform.title)") {
                TextField(SyncIdentity.systemName, text: $settings.deviceName)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
            .id("sync")
            switch client.status {
            case .connected(let host):
                hostLabel(host, detail: String(localized: "Синхронизировано"))
                Button("Отключить синхронизацию", role: .destructive) { client.disconnect() }
            case .connecting(let host), .waitingApproval(let host):
                hostLabel(host, detail: String(localized: "Подключаемся…"))
            case .idle, .failed:
                if case .failed(let message) = client.status {
                    Text(message).foregroundStyle(.orange)
                }
                if client.hosts.isEmpty {
                    Text("В этой сети нет Mac с открытым Waiting Paws").foregroundStyle(.secondary)
                }
            }
            ForEach(client.hosts.filter { $0.id != client.host?.id }) { host in
                Button {
                    client.connect(to: host)
                } label: {
                    hostLabel(host.device, detail: HostText.detail(host, paired: client.isPaired(host.device)))
                }
                .tint(.primary)
                .disabled(model.session != nil || !host.isCompatible || client.isBusy)
            }
        } header: {
            Text("Синхронизация")
        } footer: {
            Text("Камера, запись и лог остаются на Mac, а iPhone ведёт тренировку из-за двери. К последнему Mac, с которым работал, iPhone подключается сам. Имя выше видно на Mac при подключении.")
        }
        if !client.pairedHosts.isEmpty {
            Section {
                ForEach(client.pairedHosts.sorted { $0.lastConnected > $1.lastConnected }) { paired in
                    LabeledContent {
                        Button("Забыть", role: .destructive) { forgetHost = paired }
                            .buttonStyle(.borderless)
                    } label: {
                        hostLabel(paired.device, detail: pairedDetail(paired))
                    }
                }
            } header: {
                Text("Подключались раньше")
            } footer: {
                Text("После «Забыть» для синхронизации с этим компьютером снова понадобится «Разрешить» на нём.")
            }
        }
    }

    private func hostLabel(_ host: SyncDevice, detail: String) -> some View {
        Label {
            Text(host.name)
            if !detail.isEmpty { Text(detail) }
        } icon: {
            Image(systemName: host.symbolName)
        }
    }

    /// «Забыть «…»?»: the computer will have to allow this iPhone again; a sync with it running now stops.
    private func forgetMessage(_ host: SyncClient.PairedHost) -> String {
        let again = String(localized: "Чтобы снова синхронизироваться, на \(host.device.kindTitle) понадобится «Разрешить».")
        let client = model.syncClient
        // `forget` also gives up a link being restored.
        let linked = (client.isConnected && client.host?.id == host.id) || client.reconnecting?.id == host.id
        return linked ? String(localized: "Синхронизация отключится.") + " " + again : again
    }

    private func pairedDetail(_ paired: SyncClient.PairedHost) -> String {
        var parts: [String] = []
        if let model = paired.device.distinctModel { parts.append(model) }
        if model.syncClient.host?.id == paired.id, model.syncClient.isConnected {
            parts.append(String(localized: "подключён сейчас"))
        } else if model.syncClient.isNearby(paired.id) {
            parts.append(String(localized: "рядом"))
        } else {
            parts.append(String(localized: "последний раз \(paired.lastConnected.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }
    #endif

    private func check() async {
        guard let client = model.client else {
            checkStatus = String(localized: "Некорректный адрес")
            return
        }
        checkStatus = "…"
        do {
            let version = try await client.version()
            checkStatus = version.isEmpty ? String(localized: "Сервер отвечает") : "go2rtc \(version)"
        } catch {
            checkStatus = error.localizedDescription
        }
    }
}
