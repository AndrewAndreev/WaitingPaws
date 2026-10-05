import SwiftUI
import WaitingPawsCore

/// First launch: go2rtc server → Xiaomi account → camera (or on without a camera). Also shown as a sheet
/// («Подключить камеру…») after starting without one: then `onClose` is set.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    var onClose: (() -> Void)? = nil
    @State private var path: [Step] = []

    enum Step: Hashable {
        case server
        case xiaomi
        case camera(accountID: String?)
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .server:
                        ServerSetupView(onContinue: { path.append(.xiaomi) })
                    case .xiaomi:
                        xiaomiStep
                    case .camera(let accountID):
                        CameraPickerView(accountID: accountID, region: model.settings.xiaomiRegion,
                                         onContinueWithoutCamera: onClose == nil ? continueWithoutCamera : nil) { _ in
                            // settings.isConfigured flips → RootView shows the main screen (or the sheet closes)
                            onClose?()
                        }
                    }
                }
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) { Button("Закрыть", action: onClose) }
                    }
                }
        }
        .background(Color(white: 0.04))
        #if os(iOS)
        // A Mac on the same network already has the camera signed in: offer it before the Xiaomi login,
        // and rejoin a Mac this iPhone was linked to before without asking.
        .safeAreaInset(edge: .bottom) {
            if path.isEmpty, onClose == nil {
                MacLinkCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: model.syncClient.preferredHost, initial: true) { _, host in
            if onClose == nil, let host, model.syncClient.status == .idle, model.syncClient.isPaired(host.device) {
                model.syncClient.connect(to: host)
            }
        }
        #endif
    }

    /// Embedded mode starts straight at the Xiaomi login; external mode asks for the server first.
    @ViewBuilder
    private var root: some View {
        if model.settings.connectionMode == .embedded {
            xiaomiStep
        } else {
            ServerSetupView(onContinue: { path.append(.xiaomi) })
        }
    }

    private var xiaomiStep: some View {
        XiaomiLoginView(
            showsHero: model.settings.connectionMode == .embedded && onClose == nil,
            onDone: { accountID in path.append(.camera(accountID: accountID)) },
            onSkip: { path.append(.camera(accountID: nil)) },
            onUseExternalServer: {
                model.settings.connectionMode = .external
                path.append(.server)
            },
            onContinueWithoutCamera: onClose == nil ? continueWithoutCamera : nil)
    }

    private func continueWithoutCamera() {
        model.settings.withoutCamera = true
    }
}

/// Step 1: where is go2rtc?
struct ServerSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onContinue: () -> Void

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "pawprint.fill").foregroundStyle(Theme.accent)
                        Text("Waiting Paws")
                    }
                    .font(Theme.display(34, weight: .bold))
                    Text("Укажите адрес сервера go2rtc, через который идёт видео.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Сервер go2rtc").font(.headline)
                        TextField("http://192.168.1.10:1984", text: $urlText)
                            .plainInput()
                            #if os(iOS)
                            .keyboardType(.URL)
                            #endif
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Логин", text: $username)
                                .plainInput()
                                .textFieldStyle(.roundedBorder)
                            SecureField("Пароль", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        statusView
                        BigButton(title: status == .checking ? String(localized: "Проверяем…") : String(localized: "Проверить подключение"),
                                  systemImage: "antenna.radiowaves.left.and.right", style: .secondary, height: 48) {
                            Task { await check() }
                        }
                        .disabled(status == .checking || Go2RTCServer.parse(urlText) == nil)
                    }
                }

                BigButton(title: String(localized: "Далее: аккаунт Xiaomi"), systemImage: "arrow.right") {
                    save()
                    onContinue()
                }
                .disabled(!isOK)

                Text("go2rtc должен быть собран с поддержкой xiaomi (версия 1.9.11 и новее). Если камера уже добавлена в go2rtc, шаг с Xiaomi можно пропустить.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if EmbeddedGo2RTC.isAvailable {
                    Button("Вернуться к встроенному go2rtc") {
                        model.settings.connectionMode = .embedded
                        model.startEmbeddedIfNeeded()
                        dismiss()
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
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
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let version):
            Label(version.isEmpty ? "Сервер отвечает" : "go2rtc \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.danger)
                .font(.footnote)
        }
    }

    private func save() {
        model.settings.serverURLString = urlText
        model.settings.serverUsername = username
        model.settings.serverPassword = password
    }

    private func check() async {
        guard let url = Go2RTCServer.parse(urlText) else { return }
        status = .checking
        let client = Go2RTCClient(server: Go2RTCServer(baseURL: url, username: username, password: password))
        do {
            let version = try await client.version()
            status = .ok(version)
            save()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
