import SwiftUI
import WaitingPawsCore

#if !WP_NO_XIAOMI // a build without Xiaomi has no sign-in (`NoXiaomiText`)
/// «Войти в Xiaomi» on the iPhone (S1 → S3), the counterpart of the Mac sign-in sheet: login, password and region in
/// one group, then the code Xiaomi sends by SMS or e-mail. A captcha appears only when go2rtc's answer carries one
/// (Xiaomi's anti-bot check) — as a small block inside the current step. Everything goes to go2rtc
/// (`POST /api/xiaomi`); the app never stores the password.
struct XiaomiSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// After a successful sign-in (or a tap on an account go2rtc already has): that account's id; `nil` when go2rtc
    /// had several accounts and it is unclear which one this was (the camera picker then lists them all).
    var onSignedIn: (String?) -> Void

    enum Step: Equatable {
        case account
        /// Xiaomi sent a code to this masked phone / e-mail.
        case code(phone: String?, email: String?)
    }

    private enum Field: Hashable { case login, password, captcha }

    /// Xiaomi allows a new code about once a minute.
    private static let resendDelay: TimeInterval = 60

    @State private var step: Step = .account
    @State private var login = ""
    @State private var password = ""
    @State private var region: XiaomiRegion = .ru
    @State private var existingAccounts: [String] = []
    /// The picture Xiaomi wants solved before going on; `nil` almost always.
    @State private var captchaImage: Data?
    @State private var captchaLogin = ""
    @State private var captcha = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @State private var resent = false
    @State private var accountsBefore: Set<String> = []
    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
                }
                switch step {
                case .account: accountSections
                case .code: codeSection
                }
                if let captchaImage { captchaSection(captchaImage) }
            }
            .scrollContentBackground(.hidden)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .account {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Отменить")
                    } else {
                        Button { backToAccount() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Изменить логин")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if step != .account {
                        Text(login)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                WideGlassButton(title: primaryTitle, busy: busy, action: submit)
                    .disabled(!canSubmit)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
        }
        .animation(.default, value: step)
        .animation(.default, value: captchaImage)
        .interactiveDismissDisabled(busy)
        .task {
            region = model.settings.xiaomiRegion
            applyDemo()
            if !SignInDemo.isOn { focus = .login }
            await loadAccounts()
        }
        .onChange(of: model.embedded.status.isRunning) { _, running in
            if running { Task { await loadAccounts() } }
        }
        .onChange(of: login) {
            if captchaImage != nil, step == .account, login != captchaLogin { captchaImage = nil }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            switch step {
            case .account:
                AppIconImage(size: 64, glow: false)
                Text("Вход в аккаунт Xiaomi")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Тот же логин и пароль, что в приложении Mi\u{00A0}Home. Камеры появятся сразу после входа.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .code(let phone, let email):
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.accent, Color(red: 0.36, green: 0.85, blue: 0.56))
                    .frame(height: 64)
                Text("Введите код")
                    .font(.system(size: 26, weight: .bold))
                Text(codeDestination(phone: phone, email: email))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func codeDestination(phone: String?, email: String?) -> String {
        if let phone { return String(localized: "Xiaomi отправил SMS на \(phone)") }
        if let email { return String(localized: "Xiaomi отправил код на \(email)") }
        return String(localized: "Xiaomi отправил код по SMS или на почту")
    }

    // MARK: Step 1: account

    @ViewBuilder
    private var accountSections: some View {
        if !isServerReady {
            Section { serverStatus }
        }
        if !existingAccounts.isEmpty {
            Section {
                ForEach(existingAccounts, id: \.self) { account in
                    Button {
                        finish(accountID: account)
                    } label: {
                        HStack {
                            Label("Mi Home · ID \(account)", systemImage: "person.crop.circle.fill")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Уже вошли на этом iPhone")
            }
        }
        Section {
            SignInFieldRow(label: String(localized: "Логин")) {
                TextField("Логин", text: $login, prompt: Text("E-mail или телефон"))
                    .textContentType(.username)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    #endif
                    .plainInput()
                    .focused($focus, equals: .login)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            SignInFieldRow(label: String(localized: "Пароль")) {
                SecureField("Пароль", text: $password, prompt: Text("Пароль Mi Home"))
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            Picker("Регион", selection: $region) {
                ForEach(SetupText.regions) { Text(SetupText.regionTitle($0)).tag($0) }
            }
            .pickerStyle(.menu)
        } header: {
            if !existingAccounts.isEmpty { Text("Другой аккаунт") }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                passwordNote
                if captchaImage == nil { errorLabel }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch model.embedded.status {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                Button("Попробовать снова") { model.startEmbeddedIfNeeded() }
            }
            .font(.footnote)
        case .unavailable:
            Label("Сборка без встроенного go2rtc: выполните GoMobile/build.sh или укажите свой сервер",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        default:
            HStack(spacing: 10) {
                ProgressView()
                Text("Запускаем встроенный go2rtc…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
    }

    // MARK: Step 2: code

    private var codeSection: some View {
        Section {
            SignInCodeField(code: $code, onComplete: submit)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .disabled(captchaImage != nil)
        } footer: {
            VStack(spacing: 14) {
                Text(resent ? "Новый код отправлен" : "Код из «Сообщений» появится над клавиатурой")
                resendButton
                if captchaImage == nil { errorLabel }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
        }
    }

    /// «Отправить ещё раз»: the login again makes Xiaomi send a fresh code (the password is kept until success).
    private var resendButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(resendAt.timeIntervalSince(context.date).rounded(.up))
            Button(left > 0 ? "Отправить ещё раз через \(left) с" : "Отправить ещё раз", action: resend)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .disabled(left > 0 || busy || password.isEmpty || captchaImage != nil)
        }
    }

    // MARK: Captcha (only when Xiaomi asks)

    private func captchaSection(_ image: Data) -> some View {
        Section {
            HStack(spacing: 12) {
                captchaPicture(image)
                GlassCircleButton(systemImage: "arrow.clockwise", action: newCaptcha)
                    .accessibilityLabel("Другая картинка")
                    .disabled(busy || password.isEmpty)
            }
            .padding(.vertical, 4)
            SignInFieldRow(label: String(localized: "Символы")) {
                TextField("Символы", text: $captcha, prompt: Text("Как на картинке"))
                    .plainInput()
                    .focused($focus, equals: .captcha)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
        } header: {
            Label("Xiaomi просит подтвердить, что вы не робот", systemImage: "checkmark.shield.fill")
                .textCase(nil)
        } footer: {
            errorLabel
        }
        .onAppear { focus = .captcha }
    }

    @ViewBuilder
    private func captchaPicture(_ data: Data) -> some View {
        Group {
            #if os(iOS)
            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            #else
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            #endif
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Shared pieces

    private var passwordNote: some View {
        Label {
            Text(model.settings.connectionMode == .embedded
                 ? "Пароль уходит только встроенному go2rtc на этом iPhone, Waiting Paws его не хранит."
                 : "Пароль уходит только вашему серверу go2rtc, Waiting Paws его не хранит.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isServerReady: Bool {
        if SignInDemo.isOn { return true }
        return model.settings.connectionMode == .external || model.embedded.status.isRunning
    }

    private var primaryTitle: String {
        if busy {
            if captchaImage != nil { return String(localized: "Проверяем…") }
            return step == .account ? String(localized: "Входим…") : String(localized: "Проверяем код…")
        }
        if captchaImage != nil { return String(localized: "Продолжить") }
        return step == .account ? String(localized: "Войти") : String(localized: "Подтвердить")
    }

    private var canSubmit: Bool {
        guard !busy, isServerReady else { return false }
        if captchaImage != nil { return !captcha.trimmingCharacters(in: .whitespaces).isEmpty }
        switch step {
        case .account: return !login.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .code: return code.count >= 4
        }
    }

    // MARK: Flow

    private enum Request {
        case login, captcha, code
    }

    private func submit() {
        guard canSubmit else { return }
        let request: Request = captchaImage != nil ? .captcha : (step == .account ? .login : .code)
        Task { await send(request) }
    }

    private func resend() {
        resent = false
        Task { await send(.login, resending: true) }
    }

    /// «Другая картинка»: the login again gives a fresh captcha.
    private func newCaptcha() {
        Task { await send(.login) }
    }

    private func backToAccount() {
        step = .account
        captchaImage = nil
        captcha = ""
        code = ""
        error = nil
        focus = .password
    }

    private func loadAccounts() async {
        guard !AppModel.isUIPreview else { return }
        await model.waitForServer()
        guard let client = model.client else { return }
        existingAccounts = (try? await client.xiaomiAccounts()) ?? []
    }

    private func send(_ request: Request, resending: Bool = false) async {
        guard !AppModel.isUIPreview, let client = model.client else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let answer: XiaomiLoginStep
            switch request {
            case .login:
                accountsBefore = Set((try? await client.xiaomiAccounts()) ?? [])
                answer = try await client.xiaomiLogin(username: login.trimmingCharacters(in: .whitespaces), password: password)
            case .captcha:
                answer = try await client.xiaomiSubmitCaptcha(captcha.trimmingCharacters(in: .whitespaces))
            case .code:
                answer = try await client.xiaomiSubmitVerify(code)
            }
            captcha = ""
            switch answer {
            case .success:
                await finish(client)
            case .captcha(let image):
                captchaLogin = login
                captchaImage = image
            case .verify(let phone, let email):
                captchaImage = nil
                code = ""
                step = .code(phone: phone, email: email)
                resendAt = Date().addingTimeInterval(Self.resendDelay)
                resent = resending
            }
        } catch {
            if request == .code { code = "" }
            self.error = error.localizedDescription
        }
    }

    private func finish(_ client: Go2RTCClient) async {
        password = ""
        let accounts = (try? await client.xiaomiAccounts()) ?? []
        existingAccounts = accounts
        let fresh = Set(accounts).subtracting(accountsBefore)
        let accountID: String?
        if let id = fresh.first ?? (accounts.count == 1 ? accounts.first : nil) {
            accountID = id
        } else if !accounts.isEmpty {
            // Signed in again to one of the accounts go2rtc already had.
            accountID = nil
        } else {
            backToAccount()
            error = String(localized: "Вход прошёл, но go2rtc не вернул аккаунт. Попробуйте ещё раз.")
            return
        }
        print("[setup] signed in to Xiaomi account \(accountID ?? "(one of the known)")")
        finish(accountID: accountID)
    }

    private func finish(accountID: String?) {
        if let accountID { model.settings.xiaomiAccountID = accountID }
        model.settings.xiaomiRegion = region
        onSignedIn(accountID)
        dismiss()
    }

    /// DEBUG `--demo-onboarding signin|code|captcha`: sample data at that point (nothing is sent).
    private func applyDemo() {
        #if DEBUG
        guard let demo = SignInDemo.stage else { return }
        login = "anna.k@example.com"
        password = "demo-password"
        switch demo {
        case "captcha":
            captchaLogin = login
            captchaImage = SignInDemo.captchaPNG
            captcha = "x7K"
        case "code":
            step = .code(phone: "+7 ••• ••• 45 12", email: nil)
            code = "4819"
            resendAt = Date().addingTimeInterval(42)
        default:
            break
        }
        #endif
    }
}
#endif

/// Settings-style row: a fixed-width label and the field (Wi‑Fi password, Apple Account sign-in).
struct SignInFieldRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 92, alignment: .leading)
            field
        }
    }
}

#if !WP_NO_XIAOMI
/// Six cells for the code Xiaomi sends. They draw one hidden `.oneTimeCode` field: one field per digit makes
/// iOS 26 paste the code from Messages into a single cell. The code goes out as soon as it is complete.
private struct SignInCodeField: View {
    @Binding var code: String
    var length = 6
    var onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let chars = Array(code)
        ZStack {
            TextField("", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .focused($focused)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .accessibilityLabel("Код подтверждения")
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(length))
                    if digits != new { code = digits }
                    if digits.count == length { onComplete() }
                }
            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { index in
                    let filled = index < chars.count
                    let current = focused && index == min(chars.count, length - 1) && chars.count < length
                    Text(filled ? String(chars[index]) : "")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 44, height: 53)
                        .glassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                    tint: current ? Theme.accent.opacity(0.18) : nil)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(current ? Theme.accent : .clear, lineWidth: 2)
                        }
                    if index == length / 2 - 1 {
                        Capsule().fill(.white.opacity(0.25)).frame(width: 8, height: 3)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityHidden(true)
        }
        .onAppear { if !SignInDemo.isOn { focused = true } }
    }
}
#endif

/// DEBUG `--demo-onboarding <stage>` for UI checks of the iPhone setup screens:
/// `signin`, `code`, `captcha` (the sign-in sheet at that point), `other` («Другие способы»).
enum SignInDemo {
    static var stage: String? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-onboarding"), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }

    static var isOn: Bool { stage != nil }

    #if DEBUG
    /// A captcha-like picture for the demo, drawn at runtime.
    @MainActor static var captchaPNG: Data? {
        let renderer = ImageRenderer(content: Text("x7K2")
            .font(.system(size: 40, weight: .heavy, design: .serif))
            .italic()
            .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.45))
            .frame(width: 220, height: 70)
            .background(Color(white: 0.92)))
        renderer.scale = 2
        #if os(iOS)
        return renderer.uiImage?.pngData()
        #else
        return nil
        #endif
    }
    #endif
}
