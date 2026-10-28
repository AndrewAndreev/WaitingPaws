import SwiftUI
import WaitingPawsCore

/// First launch: the welcome screen → «Войти в Xiaomi» sheet → camera, or one of «Другие способы» (a computer with
/// Waiting Paws nearby, own go2rtc server, no camera). Also shown as a sheet («Подключить камеру…») after starting
/// without a camera: then `onClose` is set.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    var onClose: (() -> Void)? = nil
    @State private var path: [Step] = []
    @State private var sheet: Sheet?
    /// Computers closed with ✕ on the «рядом» card (until the next launch).
    @State private var dismissedHosts: Set<String> = []

    enum Step: Hashable {
        case server
        case camera(accountID: String?)
    }

    enum Sheet: String, Identifiable {
        case signIn, otherWays
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(addingCamera: onClose != nil,
                        onSignIn: { sheet = .signIn },
                        onOtherWays: { sheet = .otherWays },
                        onContinueWithoutCamera: onClose == nil ? continueWithoutCamera : nil)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .server:
                        ServerSetupView(onDone: { path.removeAll() })
                    case .camera(let accountID):
                        CameraPickerView(signedInAccount: accountID,
                                         onContinueWithoutCamera: onClose == nil ? continueWithoutCamera : nil) { _ in
                            // settings.isConfigured flips → RootView shows the main screen (or the sheet closes)
                            onClose?()
                        }
                    }
                }
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: onClose) { Image(systemName: "xmark") }
                                .accessibilityLabel("Закрыть")
                        }
                    }
                }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .signIn:
                    XiaomiSignInSheet { accountID in path.append(.camera(accountID: accountID)) }
                case .otherWays:
                    otherWays
                }
            }
            .environment(model)
        }
        #if DEBUG
        // `--demo-onboarding signin|code|captcha|other`: opens that sheet; `cameras` (with `--demo-cameras`): the
        // camera picker right after a sign-in (UI checks).
        .onAppear {
            guard let demo = SignInDemo.stage, onClose == nil else { return }
            if demo == "cameras" {
                path = [.camera(accountID: SetupDemo.accountID)]
            } else {
                sheet = demo == "other" ? .otherWays : .signIn
            }
        }
        #endif
        #if os(iOS)
        // A computer on the same network already has the camera signed in: offer it over the welcome screen (L4),
        // and rejoin the one this iPhone syncs with without asking.
        .overlay {
            if !nearbyHosts.isEmpty || model.syncClient.isBusy {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { if !model.syncClient.isBusy { dismissNearby() } }
                    NearbyComputerCard(hosts: nearbyHosts, onDismiss: dismissNearby, onSignIn: {
                        dismissNearby()
                        sheet = .signIn
                    })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nearbyHosts.map(\.id))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.syncClient.isBusy)
        // Only the computer this iPhone syncs with, not any joined before: «Отключить синхронизацию» (which leads
        // here on an iPhone without its own camera) must stick.
        .onChange(of: model.syncClient.preferredHost, initial: true) { _, _ in
            if onClose == nil { model.syncClient.autoConnectIfPossible() }
        }
        #endif
    }

    #if os(iOS)
    /// What the «рядом» card offers: only on the welcome screen of the first launch, with no sheet over it.
    private var nearbyHosts: [SyncClient.DiscoveredHost] {
        guard onClose == nil, path.isEmpty, sheet == nil, model.session == nil else { return [] }
        return model.syncClient.compatibleHosts.filter { !dismissedHosts.contains($0.id) }
    }

    private func dismissNearby() {
        dismissedHosts.formUnion(model.syncClient.compatibleHosts.map(\.id))
    }

    private var otherWays: some View {
        OtherWaysSheet(
            onJoin: { host in
                sheet = nil
                dismissedHosts.remove(host.id)
                model.syncClient.connect(to: host)
            },
            onStream: {
                sheet = nil
                path.append(.camera(accountID: nil))
            },
            onServer: {
                sheet = nil
                path.append(.server)
            },
            onContinueWithoutCamera: onClose == nil ? continueWithoutCamera : nil)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #else
    private var otherWays: some View { EmptyView() }
    #endif

    private func continueWithoutCamera() {
        sheet = nil
        model.settings.withoutCamera = true
    }
}

/// «Свой сервер go2rtc»: where the user's go2rtc is. «Готово» switches the app to it and goes back to the welcome
/// screen, where «Войти в Xiaomi» or a stream of that server picks the camera.
struct ServerSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text("Свой сервер go2rtc")
                        .font(.system(size: 26, weight: .bold))
                    Text("Укажите адрес сервера go2rtc, через который идёт видео.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                SignInFieldRow(label: String(localized: "Адрес")) {
                    TextField("Адрес", text: $urlText, prompt: Text(verbatim: "http://192.168.1.10:1984"))
                        .plainInput()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                }
                SignInFieldRow(label: String(localized: "Логин")) {
                    TextField("Логин", text: $username, prompt: Text("Если нужен"))
                        .plainInput()
                }
                SignInFieldRow(label: String(localized: "Пароль")) {
                    SecureField("Пароль", text: $password, prompt: Text("Если нужен"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    statusView
                    Text("go2rtc должен быть собран с поддержкой xiaomi (версия 1.9.11 и новее). Если камера уже добавлена в go2rtc, вход в Xiaomi не нужен.")
                }
                .padding(.top, 4)
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Label(status == .checking ? "Проверяем…" : "Проверить подключение",
                              systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if status == .checking { ProgressView() }
                    }
                }
                .disabled(status == .checking || Go2RTCServer.parse(urlText) == nil)
            }
            if EmbeddedGo2RTC.isAvailable, model.settings.connectionMode == .external {
                Section {
                    Button("Вернуться к встроенному go2rtc") {
                        model.settings.connectionMode = .embedded
                        model.startEmbeddedIfNeeded()
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .safeAreaInset(edge: .bottom) {
            WideGlassButton(title: String(localized: "Готово")) {
                save()
                onDone()
            }
            .disabled(!isOK)
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
        }
        .navigationTitle("")
        .onAppear {
            urlText = model.settings.serverURLString
            username = model.settings.serverUsername
            password = model.settings.serverPassword
        }
    }

    private var isOK: Bool {
        if case .ok = status { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle, .checking:
            EmptyView()
        case .ok(let version):
            Label(version.isEmpty ? "Сервер отвечает" : "go2rtc \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.56))
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.danger)
        }
    }

    private func save() {
        model.settings.serverURLString = urlText
        model.settings.serverUsername = username
        model.settings.serverPassword = password
        model.settings.connectionMode = .external
    }

    private func check() async {
        guard let url = Go2RTCServer.parse(urlText) else { return }
        status = .checking
        let client = Go2RTCClient(server: Go2RTCServer(baseURL: url, username: username, password: password))
        do {
            let version = try await client.version()
            status = .ok(version)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
