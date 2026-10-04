import SwiftUI
import WaitingPawsCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var checkStatus = ""
    @State private var showXiaomi = false
    @State private var showCameraPicker = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Режим", selection: $settings.connectionMode) {
                        ForEach(ConnectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .onChange(of: settings.connectionMode) { _, _ in
                        model.startEmbeddedIfNeeded()
                        checkStatus = ""
                    }
                    if settings.connectionMode == .embedded {
                        LabeledContent("Состояние", value: embeddedStatusText)
                        LabeledContent("Конфиг", value: EmbeddedGo2RTC.configURL.path)
                            .font(.footnote)
                    } else {
                        TextField("Адрес", text: $settings.serverURLString, prompt: Text("http://192.168.1.10:1984"))
                            .plainInput()
                        TextField("Логин", text: $settings.serverUsername)
                            .plainInput()
                        SecureField("Пароль", text: $settings.serverPassword)
                        HStack {
                            Button("Проверить") { Task { await check() } }
                            Spacer()
                            Text(checkStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Подключение")
                } footer: {
                    Text(settings.connectionMode == .embedded
                         ? "go2rtc работает внутри приложения, камера должна быть в той же Wi-Fi сети. Видео и запись идут, пока приложение открыто."
                         : "Отдельный сервер go2rtc в сети: подходит, если нужен доступ не из дома или постоянная запись.")
                }

                Section("Камера") {
                    LabeledContent("Поток", value: settings.cameraDisplayName.isEmpty ? "—" : settings.cameraDisplayName)
                    LabeledContent("Аккаунт Xiaomi", value: settings.xiaomiAccountID.isEmpty ? "—" : "ID \(settings.xiaomiAccountID) · \(settings.xiaomiRegion.rawValue)")
                    Button("Выбрать камеру…") { showCameraPicker = true }
                    Button("Войти в другой аккаунт Xiaomi…") { showXiaomi = true }
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

                Section("Тренировка") {
                    Toggle("Включать запись вместе с тренировкой", isOn: $settings.autoRecord)
                    Toggle("Завершать автоматически после перерыва за последним выходом", isOn: $settings.autoFinishAfterLastBreak)
                    Toggle("Сохранять видео в Фото", isOn: $settings.saveToPhotos)
                }

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
                    Text("CPU приложения и главного потока, память и максимальная задержка UI за секунду. Видео в WebKit считается отдельно и сюда не входит.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Папка", value: model.store.rootDirectory.path)
                        .font(.footnote)
                    #if os(macOS)
                    Button("Показать в Finder") { Finder.reveal(model.store.rootDirectory) }
                    #else
                    Text("Видео и логи доступны в приложении «Файлы» → На iPhone → Waiting Paws.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                } header: {
                    Text("Файлы")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showXiaomi) {
                NavigationStack {
                    XiaomiLoginView(onDone: { _ in
                        showXiaomi = false
                        showCameraPicker = true
                    })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showXiaomi = false } }
                    }
                }
                .environment(model)
                .sheetFrame(width: 520, height: 620)
            }
            .sheet(isPresented: $showCameraPicker) {
                NavigationStack {
                    CameraPickerView(accountID: settings.xiaomiAccountID.isEmpty ? nil : settings.xiaomiAccountID,
                                     region: settings.xiaomiRegion) { _ in
                        showCameraPicker = false
                    }
                }
                .environment(model)
                .sheetFrame(width: 520, height: 560)
            }
        }
    }

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle: return "не запущен"
        case .starting: return "запускается…"
        case .running(let version): return "работает, go2rtc \(version)"
        case .failed(let message): return "ошибка: \(message)"
        case .unavailable: return "фреймворк не собран"
        }
    }

    private func check() async {
        guard let client = model.client else {
            checkStatus = "Некорректный адрес"
            return
        }
        checkStatus = "…"
        do {
            let version = try await client.version()
            checkStatus = version.isEmpty ? "Сервер отвечает" : "go2rtc \(version)"
        } catch {
            checkStatus = error.localizedDescription
        }
    }
}
