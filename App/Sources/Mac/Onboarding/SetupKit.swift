#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

// Building blocks of the Mac setup screens (welcome window, Xiaomi sign-in, camera picker) and Settings:
// go2rtc state, the status line, the app icon, the code field and DEBUG demo data for UI checks.

/// What the status line says about go2rtc.
enum SetupServerState: Equatable {
    case starting
    case running(String)
    case stopped
    case failed(String)
    case unavailable
    /// Own server: version once a request went through, `nil` before.
    case external(host: String, version: String?)
    case externalFailed(host: String, message: String)

    @MainActor
    static func of(_ model: AppModel, probe: SetupCameraCatalog? = nil) -> SetupServerState {
        #if DEBUG
        if SetupDemo.isOn {
            return model.settings.connectionMode == .external
                ? .external(host: SetupDemo.serverHost, version: SetupDemo.go2rtcVersion)
                : .running(SetupDemo.go2rtcVersion)
        }
        #endif
        switch model.settings.connectionMode {
        case .embedded:
            switch model.embedded.status {
            case .idle: return .stopped
            case .starting: return .starting
            case .running(let version): return .running(version)
            case .failed(let message): return .failed(message)
            case .unavailable: return .unavailable
            }
        case .external:
            let host = model.settings.server.map { Self.hostText($0.baseURL) } ?? String(localized: "адрес не указан")
            if case .failed(let message) = probe?.phase { return .externalFailed(host: host, message: message) }
            return .external(host: host, version: probe?.serverVersion)
        }
    }

    static func hostText(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// "● Встроенный go2rtc 1.9.14 работает" / "Запускаем…" / the error with «Попробовать снова».
struct SetupServerStatusLabel: View {
    @Environment(AppModel.self) private var model
    var probe: SetupCameraCatalog? = nil
    /// "go2rtc 1.9.14" instead of the full sentence.
    var compact = false

    var body: some View {
        let state = SetupServerState.of(model, probe: probe)
        HStack(spacing: 6) {
            switch state {
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Запускаем встроенный go2rtc…")
            case .running(let version):
                StatusDot(color: MacPalette.green, size: 6)
                Text(compact ? "go2rtc \(version)" : "Встроенный go2rtc \(version) работает")
            case .stopped:
                StatusDot(color: .secondary.opacity(0.6), size: 6)
                Text("Встроенный go2rtc не запущен")
                Button("Запустить") { model.setupRetryEmbedded() }
                    .buttonStyle(.borderless)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MacPalette.orange)
                Text(message)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(message)
                Button("Попробовать снова") { model.setupRetryEmbedded() }
                    .buttonStyle(.borderless)
                    .fixedSize()
            case .unavailable:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MacPalette.orange)
                Text("Сборка без встроенного go2rtc — укажите свой сервер")
            case .external(let host, let version):
                if let version {
                    StatusDot(color: MacPalette.green, size: 6)
                    Text(compact ? "go2rtc \(version)" : "Свой сервер go2rtc \(version) · \(host)")
                } else {
                    Image(systemName: "server.rack")
                    Text("Свой сервер go2rtc · \(host)")
                }
            case .externalFailed(let host, let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MacPalette.orange)
                Text("\(host) не отвечает")
                    .help(message)
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Small pieces

/// The real app icon (05b «night»).
struct SetupAppIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Six-digit code entry, the way Apple Account asks for a two-factor code.
struct SetupCodeField: View {
    @Binding var code: String
    var length = 6
    var onComplete: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<length, id: \.self) { index in
                let chars = Array(code)
                let filled = index < chars.count
                let current = focused && index == min(chars.count, length - 1) && chars.count < length
                Text(filled ? String(chars[index]) : "")
                    .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
                    .frame(width: 34, height: 42)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: current ? 2 : 1))
                if index == length / 2 - 1 {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityHidden(true)
        .overlay {
            // The real field covers the boxes with invisible text: it takes the typing, the boxes draw it.
            TextField("", text: $code)
                .labelsHidden()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .opacity(0.011)
                .focused($focused)
                .accessibilityLabel("Код подтверждения")
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(length))
                    if digits != new { code = digits }
                    if digits.count == length { onComplete() }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }
}

/// White rounded plate for the captcha picture Xiaomi sends.
struct SetupCaptchaImage: View {
    let data: Data

    var body: some View {
        Group {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 210, height: 64)
        .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.12)))
        .accessibilityLabel("Капча")
    }
}

/// System Settings–style icon: white symbol on a coloured rounded square.
struct SetupIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .accessibilityHidden(true)
    }
}

#endif
