#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// Настройки (E2), System Settings style: the camera as the "account" row on top of a sidebar with
/// coloured icons and search, grouped panes on the right, back / forward in the toolbar.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: MacSettingsPane? = .camera
    @State private var back: [MacSettingsPane] = []
    @State private var forward: [MacSettingsPane] = []
    @State private var navigating = false
    @State private var search = ""
    @State private var sheet: MacSettingsSheet?

    /// 640 pt with the toolbar. DEBUG `--demo-settings-height <pt>` shows a whole pane in one screenshot.
    private static var minHeight: CGFloat {
        SetupDemo.argument(after: "--demo-settings-height").flatMap { Double($0) }.map { CGFloat($0) } ?? 588
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            MacSettingsDetail(pane: pane ?? .camera, sheet: $sheet)
                .navigationTitle((pane ?? .camera).title)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Назад", systemImage: "chevron.left", action: goBack)
                            .disabled(back.isEmpty)
                            .help("Назад")
                        Button("Вперёд", systemImage: "chevron.right", action: goForward)
                            .disabled(forward.isEmpty)
                            .help("Вперёд")
                    }
                }
        }
        .frame(width: 900)
        .frame(minHeight: Self.minHeight, idealHeight: Self.minHeight)
        .background(SettingsWindowStyler())
        .onChange(of: pane) { old, new in
            if new == nil {
                // A click into empty sidebar space keeps the pane.
                navigating = true
                pane = old
            } else if navigating {
                navigating = false
            } else if let old, old != new {
                back.append(old)
                forward.removeAll()
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .picker(let account):
                    MacCameraPickerSheet(accountID: account)
                case .signIn:
                    SetupXiaomiSignInSheet { account in show(.picker(accountID: account)) }
                }
            }
            .environment(model)
        }
        .onAppear(perform: applyDemo)
        .preferredColorScheme(SetupDemo.colorScheme)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $pane) {
            if matches(.camera) {
                SettingsCameraRow()
                    .tag(MacSettingsPane.camera)
            }
            ForEach(MacSettingsPane.groups, id: \.self) { group in
                let panes = group.filter(matches)
                if !panes.isEmpty {
                    Section {
                        ForEach(panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                SetupIconTile(symbol: pane.symbol, color: pane.color)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Поиск")
        .overlay {
            if !MacSettingsPane.allCases.contains(where: matches) {
                Text("Ничего не найдено")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func matches(_ pane: MacSettingsPane) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return ([pane.title] + pane.keywords).contains { $0.lowercased().contains(query) }
    }

    // MARK: Navigation

    private func goBack() {
        guard let previous = back.popLast() else { return }
        if let pane { forward.append(pane) }
        navigating = true
        pane = previous
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        if let pane { back.append(pane) }
        navigating = true
        pane = next
    }

    private func show(_ next: MacSettingsSheet) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            sheet = next
        }
    }

    /// DEBUG `--demo-pane <pane>` and `--demo-settings-sheet signin|captcha|verify|picker`.
    private func applyDemo() {
        #if DEBUG
        if let raw = SetupDemo.argument(after: "--demo-pane"), let demoPane = MacSettingsPane(rawValue: raw), demoPane != pane {
            navigating = true
            pane = demoPane
        }
        switch SetupDemo.argument(after: "--demo-settings-sheet") {
        case "signin", "captcha", "verify": sheet = .signIn
        case "picker": sheet = .picker(accountID: nil)
        default: break
        }
        #endif
    }
}

enum MacSettingsSheet: Identifiable, Hashable {
    case picker(accountID: String?)
    case signIn

    var id: String {
        switch self {
        case .picker(let account): return "picker-\(account ?? "all")"
        case .signIn: return "signIn"
        }
    }
}

enum MacSettingsPane: String, CaseIterable, Identifiable, Hashable {
    case camera, connection, training, files, iPhone, diagnostics

    var id: String { rawValue }

    /// Sidebar groups under the camera row.
    static let groups: [[MacSettingsPane]] = [[.connection], [.training, .files], [.iPhone, .diagnostics]]

    var title: String {
        switch self {
        case .camera: return "Камера"
        case .connection: return "Подключение"
        case .training: return "Тренировка"
        case .files: return "Запись и файлы"
        case .iPhone: return "iPhone"
        case .diagnostics: return "Диагностика"
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "video.fill"
        case .connection: return "network"
        case .training: return "pawprint.fill"
        case .files: return "folder.fill"
        case .iPhone: return "iphone"
        case .diagnostics: return "gauge.with.needle.fill"
        }
    }

    var color: Color {
        switch self {
        case .camera, .training: return MacPalette.pinkDeep
        case .connection: return Color(red: 0.20, green: 0.68, blue: 0.36)
        case .files: return Color(red: 0.16, green: 0.58, blue: 0.95)
        case .iPhone: return Color(red: 0.36, green: 0.36, blue: 0.86)
        case .diagnostics: return Color(red: 0.95, green: 0.55, blue: 0.15)
        }
    }

    /// What the sidebar search also finds the pane by.
    var keywords: [String] {
        switch self {
        case .camera: return ["xiaomi", "mi home", "аккаунт", "качество", "звук", "плеер", "mse", "hls", "webrtc", "поток", "2k", "hd"]
        case .connection: return ["go2rtc", "сервер", "адрес", "встроенный", "сеть", "логин", "пароль"]
        case .training: return ["запись", "автоматически", "завершать", "выход"]
        case .files: return ["папка", "finder", "видео", "фото", "запись", "место"]
        case .iPhone: return ["телефон", "устройства", "забыть", "связь", "сеть"]
        case .diagnostics: return ["нагрузка", "cpu", "память", "журнал", "логи"]
        }
    }
}

/// The Settings scene gives its window the centred "preferences" toolbar; System Settings has a unified one
/// (title and back / forward next to each other above the pane).
private struct SettingsWindowStyler: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// Like the Apple Account row in System Settings: the camera the app is connected to.
private struct SettingsCameraRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let camera = SettingsCamera(model)
        HStack(spacing: 10) {
            Group {
                if camera.isConfigured {
                    SetupStill(stream: camera.streamName, width: 62, cornerRadius: 0)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.6))
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.isConfigured ? camera.name : "Камера")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(camera))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }

    private func subtitle(_ camera: SettingsCamera) -> String {
        guard camera.isConfigured else { return "Не выбрана" }
        let kind = camera.isXiaomi ? "Камера Xiaomi" : "Поток go2rtc"
        guard model.setupServerReadyOrDemo else { return "\(kind) · go2rtc не запущен" }
        switch SetupStillStore.shared.state(for: camera.streamName, model: model) {
        case .loaded: return "\(kind) · в сети"
        case .failed: return "\(kind) · нет связи"
        case .loading, nil: return kind
        }
    }
}
#endif
