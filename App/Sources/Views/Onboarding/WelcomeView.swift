import SwiftUI
import WaitingPawsCore

/// First launch (L1): the icon, one line about the app, three things it does, «Войти в Xiaomi» and «Другие способы».
/// Opened from «Подключить камеру…» in the camera-less mode it only says what a camera adds.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    /// From «Подключить камеру…»: no intro, no «Продолжить без камеры».
    var addingCamera = false
    var onSignIn: () -> Void
    var onOtherWays: () -> Void
    var onContinueWithoutCamera: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                // iPhone SE and zoomed displays: a smaller icon and tighter rows, so the intro fits above the buttons.
                intro(compact: geo.size.height < 560)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            buttons
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
                .frame(maxWidth: 520)
        }
        .background(NightBackground())
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    private func intro(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: compact ? 8 : 20)
            AppIconImage(size: compact ? 68 : addingCamera ? 84 : 100)
            Text(addingCamera ? "Подключить камеру" : "Waiting Paws")
                .font(Theme.display(compact ? 30 : addingCamera ? 32 : 36, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, compact ? 14 : 22)
            Text(addingCamera ? "Камера покажет собаку, пока вы за дверью, и запишет тренировку для тренера."
                              : "Спокойные выходы из дома: по расписанию тренера и с собакой на экране")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 12)
            if !addingCamera {
                VStack(alignment: .leading, spacing: compact ? 14 : 22) {
                    WelcomeFeatureRow(symbol: "list.bullet.clipboard.fill", title: String(localized: "Расписание тренера"),
                                      text: String(localized: "Вставьте сообщение: выходы и перерывы пойдут по таймеру"))
                    WelcomeFeatureRow(symbol: "video.fill", title: String(localized: "Камера Mi Home"),
                                      text: String(localized: "Собака видна, пока вы за дверью"))
                    WelcomeFeatureRow(symbol: "doc.text.fill", title: String(localized: "Лог для тренера"),
                                      text: String(localized: "Выходы, фальстарты и видео одной кнопкой"))
                }
                .padding(.top, compact ? 22 : 40)
                .padding(.horizontal, 8)
            }
            Spacer(minLength: compact ? 8 : 20)
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            serverProblem
            WideGlassButton(title: String(localized: "Войти в Xiaomi"), systemImage: "person.crop.circle.fill", action: onSignIn)
            WideGlassButton(title: String(localized: "Другие способы"), prominent: false, action: onOtherWays)
            if let onContinueWithoutCamera {
                Button("Продолжить без камеры", action: onContinueWithoutCamera)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 6)
            }
        }
    }

    /// Said only when something is wrong: a working go2rtc is not news on the first screen.
    @ViewBuilder
    private var serverProblem: some View {
        if model.settings.connectionMode == .embedded {
            switch model.embedded.status {
            case .failed(let message):
                VStack(spacing: 4) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                    Button("Попробовать снова") { model.startEmbeddedIfNeeded() }
                }
                .font(.footnote)
                .multilineTextAlignment(.center)
            case .unavailable:
                Label("Сборка без встроенного go2rtc: выполните GoMobile/build.sh или укажите свой сервер",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            case .idle, .starting, .running:
                EmptyView()
            }
        }
    }
}

private struct WelcomeFeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
// MARK: - L5 «Другие способы»

/// Everything but the Xiaomi sign-in, in a half sheet over the welcome screen: a computer with Waiting Paws nearby,
/// go2rtc streams (own server only — the iPhone's own go2rtc has none until a camera is added), own server,
/// no camera.
struct OtherWaysSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onJoin: (SyncClient.DiscoveredHost) -> Void
    var onStream: () -> Void
    var onServer: () -> Void
    var onContinueWithoutCamera: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Другие способы").font(.system(size: 20, weight: .bold))
                Spacer()
                GlassCircleButton { dismiss() }
                    .accessibilityLabel("Закрыть")
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 10) {
                    computers
                    if model.settings.connectionMode == .external {
                        OtherWayRow(symbol: "antenna.radiowaves.left.and.right", color: Theme.info,
                                    title: String(localized: "Поток go2rtc"),
                                    subtitle: String(localized: "Камера, которая уже есть на вашем сервере"),
                                    action: onStream)
                    }
                    OtherWayRow(symbol: "server.rack", color: .gray, title: String(localized: "Свой сервер go2rtc"),
                                subtitle: serverSubtitle, action: onServer)
                    if let onContinueWithoutCamera {
                        OtherWayRow(symbol: "timer", color: Theme.warning, title: String(localized: "Без камеры"),
                                    subtitle: String(localized: "Таймер, расписание и лог. Камеру можно добавить позже"),
                                    action: onContinueWithoutCamera)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One row per computer around; with none, a hint that a Mac with the camera signed in can share it.
    @ViewBuilder
    private var computers: some View {
        let client = model.syncClient
        let hosts = client.compatibleHosts
        if hosts.isEmpty {
            OtherWayRow(symbol: "laptopcomputer", color: Color(red: 0.42, green: 0.45, blue: 0.95),
                        title: String(localized: "Камера с Mac"),
                        subtitle: String(localized: "Откройте Waiting Paws на Mac в этой же сети Wi‑Fi — он появится здесь"),
                        action: nil)
        } else {
            ForEach(hosts) { host in
                OtherWayRow(symbol: host.device.symbolName, color: Color(red: 0.42, green: 0.45, blue: 0.95),
                            title: host.device.name, subtitle: HostText.detail(host, paired: client.isPaired(host.device)),
                            badge: String(localized: "Рядом")) { onJoin(host) }
            }
        }
    }

    private var serverSubtitle: String {
        if model.settings.connectionMode == .external, let server = model.settings.server {
            let url = server.baseURL
            let host = url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
            return String(localized: "Сейчас: \(host)")
        }
        return String(localized: "RTSP и ONVIF — через ваш go2rtc")
    }
}

private struct OtherWayRow: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    var badge: String? = nil
    /// nil: a hint, not a button.
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.56))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.36, green: 0.85, blue: 0.56).opacity(0.16), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(action == nil ? 0.75 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(action == nil)
    }
}

// MARK: - L4 «Mac рядом»

/// A computer with Waiting Paws on the same network (L4): its camera is already signed in, so the iPhone can join
/// it instead of signing in to Xiaomi. Several around — a list to pick from. While joining — «Подтвердите на Mac».
struct NearbyComputerCard: View {
    @Environment(AppModel.self) private var model
    let hosts: [SyncClient.DiscoveredHost]
    var onDismiss: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        let client = model.syncClient
        VStack(spacing: 0) {
            switch client.status {
            case .connecting(let host), .waitingApproval(let host):
                joining(host)
            default:
                if hosts.count == 1, let host = hosts.first {
                    offer(host)
                } else {
                    choice
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(maxWidth: 520)
        .glassPanel(in: RoundedRectangle(cornerRadius: 46, style: .continuous))
    }

    private func offer(_ host: SyncClient.DiscoveredHost) -> some View {
        let kind = host.device.kindTitle
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassCircleButton(action: onDismiss).accessibilityLabel("Закрыть")
            }
            ComputerIllustration(host: host)
                .frame(width: 210, height: 132)
                .padding(.top, -14)
            Text(host.info.sessionRunning ? "На «\(host.device.name)» идёт тренировка" : "«\(host.device.name)» рядом")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            Text(text(host))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 8)
            failure.padding(.top, 10)
            WideGlassButton(title: String(localized: "Подключиться к \(kind)")) { model.syncClient.connect(to: host) }
                .padding(.top, 22)
            Button("Нет, войти в Xiaomi на iPhone", action: onSignIn)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 14)
            if !model.syncClient.isPaired(host.device) {
                Text("На \(kind) один раз появится запрос «Разрешить»")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
        }
    }

    private func text(_ host: SyncClient.DiscoveredHost) -> String {
        let kind = host.device.kindTitle
        if host.info.sessionRunning {
            return String(localized: "iPhone покажет камеру и станет пультом для этой тренировки, входить в Xiaomi не нужно.")
        }
        if !host.info.cameraTitle.isEmpty {
            return String(localized: "На нём уже подключена камера «\(host.info.cameraTitle)». iPhone покажет её и тренировку с \(kind), входить в Xiaomi не нужно.")
        }
        return String(localized: "iPhone будет показывать тренировку и камеру с \(kind), когда она там появится.")
    }

    /// Several computers: which one (the likely one first).
    private var choice: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Рядом Waiting Paws на компьютерах")
                    .font(.system(size: 22, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                GlassCircleButton(action: onDismiss).accessibilityLabel("Закрыть")
            }
            Text("На них уже подключена камера: iPhone покажет её и тренировку, входить в Xiaomi не нужно.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            failure.padding(.top, 10)
            VStack(spacing: 8) {
                ForEach(hosts) { host in
                    NearbyHostRow(host: host, paired: model.syncClient.isPaired(host.device)) {
                        model.syncClient.connect(to: host)
                    }
                }
            }
            .padding(.top, 16)
            Button("Нет, войти в Xiaomi на iPhone", action: onSignIn)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    private func joining(_ host: SyncDevice) -> some View {
        let waiting: Bool = {
            if case .waitingApproval = model.syncClient.status { return true }
            return false
        }()
        return VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
                .padding(.top, 8)
            Text(waiting ? "Подтвердите на \(host.kindTitle)" : "Подключаемся к «\(host.name)»")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            if waiting {
                // Names both ends: the prompt on the computer shows this iPhone under the same name.
                Text("На «\(host.name)» появился запрос от «\(model.settings.linkName)» — нажмите «Разрешить». Это нужно один раз для этого iPhone.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WideGlassButton(title: String(localized: "Отменить"), prominent: false) { model.syncClient.disconnect() }
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var failure: some View {
        if case .failed(let message) = model.syncClient.status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NearbyHostRow: View {
    let host: SyncClient.DiscoveredHost
    let paired: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: host.device.symbolName)
                    .font(.system(size: 22))
                    .foregroundStyle(host.info.sessionRunning ? Theme.accent : .white.opacity(0.85))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.device.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(HostText.detail(host, paired: paired))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A MacBook drawn in code with Waiting Paws on its screen (and the camera's name, when it has one); other computers
/// get their SF Symbol.
private struct ComputerIllustration: View {
    let host: SyncClient.DiscoveredHost

    var body: some View {
        if host.device.symbolName == "laptopcomputer" {
            laptop
        } else {
            Image(systemName: host.device.symbolName)
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .overlay { AppIconImage(size: 34, glow: false).offset(y: -10) }
        }
    }

    private var laptop: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let screenWidth = width * 0.78
            let screenHeight = screenWidth * 0.64
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(white: 0.08))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(white: 0.55), lineWidth: 1.2))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.26), Color(red: 0.05, green: 0.05, blue: 0.09)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(5)
                        .padding(.top, 1)
                    VStack(spacing: 6) {
                        AppIconImage(size: 40, glow: false)
                        if !host.info.cameraTitle.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(host.info.cameraReady ? Color(red: 0.36, green: 0.85, blue: 0.56) : .gray)
                                    .frame(width: 5, height: 5)
                                Text(host.info.cameraTitle)
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .frame(width: screenWidth, height: screenHeight)
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 10, bottomTrailingRadius: 10,
                                           topTrailingRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                        .frame(width: width, height: 9)
                    Capsule().fill(Color(white: 0.35)).frame(width: width * 0.16, height: 3)
                }
            }
            .frame(width: width, height: geo.size.height)
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        }
        .accessibilityHidden(true)
    }
}
#endif
