import SwiftUI
import WaitingPawsCore

/// Step 2: authorise the Mi Home account on the go2rtc server.
/// The password goes straight to go2rtc (`POST /api/xiaomi`); the app never stores it.
struct XiaomiLoginView: View {
    @Environment(AppModel.self) private var model
    /// Show the app intro and the embedded-server status (first launch in embedded mode).
    var showsHero = false
    var onDone: (String) -> Void
    var onSkip: (() -> Void)? = nil
    var onUseExternalServer: (() -> Void)? = nil

    enum Stage: Equatable {
        case credentials
        case captcha(Data)
        case verify(phone: String?, email: String?)
    }

    @State private var existingAccounts: [String] = []
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var stage: Stage = .credentials
    @State private var region: XiaomiRegion = .ru
    @State private var busy = false
    @State private var error: String?
    @State private var accountsBeforeLogin: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsHero {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "pawprint.fill").foregroundStyle(Theme.accent)
                            Text("Waiting Paws")
                        }
                        .font(Theme.display(34, weight: .bold))
                        Text("Тренировки коротких выходов с наблюдением за собакой через камеру Mi Home. Войдите в аккаунт Xiaomi, чтобы выбрать камеру.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    embeddedStatus
                } else {
                    Text("Аккаунт Xiaomi")
                        .font(Theme.display(30, weight: .bold))
                    Text("Вход выполняется на сервере go2rtc, приложение пароль не сохраняет. После входа сервер получит список камер Mi Home.")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .rounded))
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Регион аккаунта").font(.headline)
                        Picker("Регион", selection: $region) {
                            ForEach(XiaomiRegion.allCases) { region in
                                Text(region.title).tag(region)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                if !existingAccounts.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Уже авторизованы на сервере").font(.headline)
                            ForEach(existingAccounts, id: \.self) { account in
                                Button {
                                    finish(accountID: account)
                                } label: {
                                    HStack {
                                        Label("ID \(account)", systemImage: "person.crop.circle")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        switch stage {
                        case .credentials:
                            Text(existingAccounts.isEmpty ? "Войти в Mi Home" : "Добавить другой аккаунт").font(.headline)
                            TextField("Телефон, e-mail или Mi ID", text: $username)
                                .plainInput()
                                .textFieldStyle(.roundedBorder)
                            SecureField("Пароль", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await submit() } }
                        case .captcha(let image):
                            Text("Введите символы с картинки").font(.headline)
                            captchaImage(image)
                            TextField("Капча", text: $code)
                                .plainInput()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await submit() } }
                        case .verify(let phone, let email):
                            Text("Код подтверждения").font(.headline)
                            Text("Xiaomi отправил код на \(phone ?? email ?? "ваш контакт"). Введите его ниже.")
                                .font(.footnote).foregroundStyle(.secondary)
                            TextField("Код", text: $code)
                                .plainInput()
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await submit() } }
                        }

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.danger)
                        }

                        BigButton(title: busy ? "Подождите…" : submitTitle, systemImage: "arrow.right.circle", height: 52) {
                            Task { await submit() }
                        }
                        .disabled(busy || !canSubmit || !isServerReady)

                        if stage != .credentials {
                            Button("Начать заново") { stage = .credentials; code = ""; error = nil }
                                .font(.footnote)
                        }
                    }
                }

                if let onSkip {
                    Button("Пропустить — выбрать существующий поток go2rtc", action: onSkip)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                if let onUseExternalServer {
                    Button("У меня свой сервер go2rtc", action: onUseExternalServer)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(showsHero ? "" : "Xiaomi")
        .task {
            region = model.settings.xiaomiRegion
            await loadAccounts()
        }
        .onChange(of: model.embedded.status.isRunning) { _, running in
            if running { Task { await loadAccounts() } }
        }
    }

    @ViewBuilder
    private var embeddedStatus: some View {
        switch model.embedded.status {
        case .idle, .starting:
            Label("Запускаем встроенный go2rtc…", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.secondary)
        case .running(let version):
            Label("Встроенный go2rtc \(version) работает", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(Theme.accent)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.footnote).foregroundStyle(Theme.danger)
                Button("Попробовать снова") { Task { await model.embedded.start() } }
                    .font(.footnote)
            }
        case .unavailable:
            Label("Сборка без встроенного go2rtc: выполните GoMobile/build.sh или укажите свой сервер", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Theme.warning)
        }
    }

    private var isServerReady: Bool {
        model.settings.connectionMode == .external || model.embedded.status.isRunning
    }

    private var submitTitle: String {
        switch stage {
        case .credentials: return "Войти"
        case .captcha: return "Отправить капчу"
        case .verify: return "Подтвердить"
        }
    }

    private var canSubmit: Bool {
        switch stage {
        case .credentials: return !username.isEmpty && !password.isEmpty
        default: return !code.isEmpty
        }
    }

    private func captchaImage(_ data: Data) -> some View {
        Group {
            #if os(iOS)
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            #else
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            }
            #endif
        }
        .frame(height: 80)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadAccounts() async {
        await model.waitForServer()
        guard let client = model.client else { return }
        existingAccounts = (try? await client.xiaomiAccounts()) ?? []
    }

    private func submit() async {
        guard let client = model.client else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let step: XiaomiLoginStep
            switch stage {
            case .credentials:
                accountsBeforeLogin = Set((try? await client.xiaomiAccounts()) ?? [])
                step = try await client.xiaomiLogin(username: username, password: password)
            case .captcha:
                step = try await client.xiaomiSubmitCaptcha(code)
            case .verify:
                step = try await client.xiaomiSubmitVerify(code)
            }
            code = ""
            switch step {
            case .success:
                password = ""
                let accounts = (try? await client.xiaomiAccounts()) ?? []
                existingAccounts = accounts
                let fresh = Set(accounts).subtracting(accountsBeforeLogin)
                if let id = fresh.first ?? (accounts.count == 1 ? accounts.first : nil) {
                    finish(accountID: id)
                } else {
                    stage = .credentials
                    error = accounts.isEmpty ? "Вход прошёл, но сервер не вернул аккаунт" : "Выберите аккаунт из списка выше"
                }
            case .captcha(let image):
                stage = .captcha(image)
            case .verify(let phone, let email):
                stage = .verify(phone: phone, email: email)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(accountID: String) {
        model.settings.xiaomiAccountID = accountID
        model.settings.xiaomiRegion = region
        onDone(accountID)
    }
}
