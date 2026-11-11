#if os(macOS) && !WP_NO_XIAOMI // a build without Xiaomi has no sign-in (`NoXiaomiText`)
import AppKit
import SwiftUI
import WaitingPawsCore

/// «Войти в Xiaomi…» (D4): e-mail or phone, password and region, then the code Xiaomi sends by SMS or e-mail.
/// A captcha appears only when go2rtc's answer carries one (Xiaomi's anti-bot check after failed attempts,
/// for a new device or before sending the SMS) — as a small block inside the current step.
/// Everything goes to go2rtc (`POST /api/xiaomi`); the app never stores the password.
struct SetupXiaomiSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// After a successful sign-in: the new (or the only) account id; `nil` when go2rtc already had
    /// several accounts and it is unclear which one this was (the picker then lists them all).
    var onSignedIn: (String?) -> Void = { _ in }

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
    /// The picture Xiaomi wants solved before going on; `nil` almost always.
    @State private var captchaImage: Data?
    /// The login the captcha belongs to: another login needs a fresh attempt.
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
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                switch step {
                case .account: accountSections
                case .code: codeSections
                }
                if let captchaImage { captchaSection(captchaImage) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(busy)
            buttons
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.default, value: step)
        .animation(.default, value: captchaImage)
        .onAppear {
            region = model.settings.xiaomiRegion
            focus = .login
            applyDemo()
        }
        .onChange(of: login) {
            if captchaImage != nil, step == .account, login != captchaLogin { captchaImage = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            SetupAppIcon(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(step == .account ? "Sign In to Your Xiaomi Account" : "Enter Code")
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch step {
        case .account:
            return String(localized: "After you sign in, go2rtc gets the list of your Mi Home cameras.")
        case .code(let phone, let email):
            if let phone { return String(localized: "Xiaomi sent a code to \(phone).") }
            if let email { return String(localized: "Xiaomi sent a code to \(email).") }
            return String(localized: "Xiaomi sent a code by SMS or email.")
        }
    }

    // MARK: Step 1: account

    @ViewBuilder
    private var accountSections: some View {
        if !model.setupServerReadyOrDemo {
            Section {
                SetupServerStatusLabel()
            }
        }
        Section {
            TextField("Email or Phone", text: $login, prompt: Text("name@example.com or phone number"))
                .textContentType(.username)
                .plainInput()
                .focused($focus, equals: .login)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password, prompt: Text("Mi Home password"))
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(submit)
            Picker("Account Region", selection: $region) {
                ForEach(SetupText.regions) { Text(SetupText.regionTitle($0)).tag($0) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                passwordNote
                if captchaImage == nil { errorLabel }
            }
        }
    }

    // MARK: Step 2: code

    @ViewBuilder
    private var codeSections: some View {
        Section {
            LabeledContent {
                Button("Change…", action: backToAccount)
            } label: {
                Label {
                    Text(login.isEmpty ? String(localized: "Xiaomi Account") : login)
                    Text("Region: \(SetupText.regionTitle(region))")
                } icon: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            passwordNote
        }
        Section {
            HStack {
                Spacer()
                SetupCodeField(code: $code, onComplete: submit)
                Spacer()
            }
            .padding(.vertical, 8)
            .disabled(captchaImage != nil)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(resent ? "A new code has been sent." : "The code arrives within a minute.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    resendButton
                }
                .font(.footnote)
                if captchaImage == nil { errorLabel }
            }
        }
    }

    /// «Отправить ещё раз»: the login again makes Xiaomi send a fresh code (the password is kept until success).
    private var resendButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(resendAt.timeIntervalSince(context.date).rounded(.up))
            Button(left > 0 ? "Resend in \(left) s" : "Resend", action: resend)
                .buttonStyle(.borderless)
                .disabled(left > 0 || busy || password.isEmpty || captchaImage != nil)
                .monospacedDigit()
        }
    }

    // MARK: Captcha (only when Xiaomi asks)

    private func captchaSection(_ image: Data) -> some View {
        Section {
            HStack(spacing: 14) {
                SetupCaptchaImage(data: image)
                Button("New Picture", systemImage: "arrow.clockwise", action: newCaptcha)
                    .buttonStyle(.borderless)
                    .disabled(busy || password.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            LabeledContent("Characters in Picture") {
                TextField("", text: $captcha, prompt: Text("As in the picture"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .plainInput()
                    .focused($focus, equals: .captcha)
                    .onSubmit(submit)
            }
        } header: {
            Label("Xiaomi wants to make sure you’re not a robot", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
        } footer: {
            errorLabel
        }
        .onAppear { focus = .captcha }
    }

    // MARK: Shared pieces

    private var passwordNote: some View {
        Label {
            Text(model.settings.connectionMode == .embedded
                 ? "The password goes only to the built-in go2rtc; Waiting Paws doesn’t store it. go2rtc keeps the sign-in token on this Mac."
                 : "The password goes only to your go2rtc server; Waiting Paws doesn’t store it. The sign-in token stays on the server.")
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
                .foregroundStyle(MacPalette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
                Text(busyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel|verb") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    private var busyText: String {
        if captchaImage != nil { return String(localized: "Checking…") }
        return step == .account ? String(localized: "Signing in…") : String(localized: "Checking the code…")
    }

    private var primaryTitle: String {
        if captchaImage != nil { return String(localized: "Continue") }
        return step == .account ? String(localized: "Sign In") : String(localized: "Confirm")
    }

    private var canSubmit: Bool {
        guard !busy, model.setupServerReadyOrDemo else { return false }
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
        let fresh = Set(accounts).subtracting(accountsBefore)
        let accountID: String?
        if let id = fresh.first ?? (accounts.count == 1 ? accounts.first : nil) {
            accountID = id
        } else if !accounts.isEmpty {
            // Signed in again to one of the accounts go2rtc already had.
            accountID = nil
        } else {
            backToAccount()
            error = String(localized: "Signed in, but go2rtc didn’t return the account. Try again.")
            return
        }
        if let accountID { model.settings.xiaomiAccountID = accountID }
        model.settings.xiaomiRegion = region
        print("[setup] signed in to Xiaomi account \(accountID ?? "(one of the known)")")
        onSignedIn(accountID)
        dismiss()
    }

    /// DEBUG `--demo-welcome-sheet signin|captcha|verify` (or `--demo-settings-sheet …`): sample data at that point.
    private func applyDemo() {
        #if DEBUG
        let demo = SetupDemo.argument(after: "--demo-welcome-sheet") ?? SetupDemo.argument(after: "--demo-settings-sheet")
        guard let demo, ["signin", "captcha", "verify"].contains(demo) else { return }
        login = SetupDemo.login
        password = "demo-password"
        switch demo {
        case "captcha":
            captchaLogin = login
            captchaImage = SetupDemo.captchaPNG
            captcha = "x7K"
        case "verify":
            step = .code(phone: SetupDemo.maskedPhone, email: nil)
            code = "4819"
            resendAt = Date().addingTimeInterval(42)
        default:
            break
        }
        #endif
    }
}
#endif
