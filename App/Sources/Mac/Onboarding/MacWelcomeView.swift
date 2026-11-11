#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Окно приветствия (D1), Xcode / Final Cut style: the app and three ways to get a camera on the left,
/// what go2rtc already knows (signed-in Mi Home accounts with cameras, other streams) on the right.
/// Once a camera is chosen the training window opens and this one closes.
struct MacWelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var catalog = SetupCameraCatalog()
    @State private var selection: String?
    @State private var sheet: WelcomeSheet?
    @State private var opening = false
    @State private var openError: String?
    @State private var finished = false

    /// Height of the (hidden) title bar the window adds on top of the content.
    private static let titleBarHeight: CGFloat = 32

    enum WelcomeSheet: Identifiable, Hashable {
        #if !WP_NO_XIAOMI // a build without Xiaomi has no sign-in (`NoXiaomiText`)
        case signIn
        #endif
        case streams
        case server
        case cameras(accountID: String?)

        var id: String {
            switch self {
            #if !WP_NO_XIAOMI
            case .signIn: return "signIn"
            #endif
            case .streams: return "streams"
            case .server: return "server"
            case .cameras(let account): return "cameras-\(account ?? "all")"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            identity
                .frame(width: 470)
                .frame(maxHeight: .infinity)
            Divider()
            found
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The panels run up under the hidden title bar; the window itself stays 880×560.
        .ignoresSafeArea()
        .frame(width: 880, height: 560 - Self.titleBarHeight)
        .containerBackground(.thickMaterial, for: .window)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                #if !WP_NO_XIAOMI
                case .signIn:
                    SetupXiaomiSignInSheet { account in show(.cameras(accountID: account)) }
                #endif
                case .streams:
                    MacCameraPickerSheet(onlyStreams: true, onChosen: finish)
                case .server:
                    SetupServerSheet()
                case .cameras(let account):
                    MacCameraPickerSheet(accountID: account, onChosen: finish)
                }
            }
            .environment(model)
        }
        .task(id: serverKey) {
            // Settings may be editing the server address: wait until the typing stops.
            if catalog.phase != .idle { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
        .onAppear(perform: openDemoSheet)
        .onChange(of: sheet) { _, new in
            // A sign-in or a new stream may have changed what go2rtc knows.
            if new == nil { Task { await reload() } }
        }
        .preferredColorScheme(SetupDemo.colorScheme)
        .onChange(of: model.settings.isConfigured) { _, configured in
            if configured { finish() }
        }
    }

    // MARK: Left: icon, name, version, actions

    private var identity: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 34)
            SetupAppIcon(size: 112)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            Text("Waiting Paws")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 10)
            Text(SetupText.appVersion)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            SetupServerStatusLabel(probe: catalog)
                .font(.system(size: 11.5))
                .frame(maxWidth: 400)
                .padding(.top, 10)

            VStack(spacing: 6) {
                #if !WP_NO_XIAOMI
                WelcomeActionRow(symbol: "person.badge.key", title: String(localized: "Sign In to Xiaomi…"),
                                 subtitle: String(localized: "Cameras from the Mi Home app")) { sheet = .signIn }
                #endif
                WelcomeActionRow(symbol: "antenna.radiowaves.left.and.right", title: String(localized: "Choose go2rtc Stream…"),
                                 subtitle: String(localized: "RTSP, HTTP and other sources")) { sheet = .streams }
                WelcomeActionRow(symbol: "server.rack", title: String(localized: "Own go2rtc Server…"),
                                 subtitle: serverSubtitle) { sheet = .server }
                WelcomeActionRow(symbol: "timer", title: String(localized: "Continue Without Camera"),
                                 subtitle: String(localized: "Timer, schedule and log")) {
                    model.settings.withoutCamera = true
                    finish()
                }
            }
            .frame(width: 320)
            .padding(.top, 26)

            Spacer(minLength: 16)
            Label("The camera and the Mac must be on the same Wi‑Fi network", systemImage: "wifi")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
    }

    /// What the lists depend on: the server and whether it runs.
    private var serverKey: String {
        let settings = model.settings
        return "\(settings.connectionMode.rawValue)|\(settings.serverURLString)|\(settings.serverUsername)|\(model.setupServerReady)"
    }

    private var serverSubtitle: String {
        if model.settings.connectionMode == .external, let server = model.settings.server {
            return String(localized: "Current: \(SetupServerState.hostText(server.baseURL))")
        }
        return String(localized: "For example, http://192.168.1.10:1984")
    }

    // MARK: Right: what go2rtc already has

    private var found: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(catalog.accounts.isEmpty ? "Already in go2rtc" : "Already Signed In on the Server")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 4)
            Group {
                switch catalog.phase {
                case .idle, .loading:
                    ProgressView("Looking for cameras…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .waiting:
                    switch SetupServerState.of(model) {
                    case .failed, .unavailable:
                        empty(title: String(localized: "No Cameras Yet"), symbol: "video.slash", text: waitingText)
                    case .external:
                        empty(title: String(localized: "No Server Set"), symbol: "server.rack",
                              text: String(localized: "Enter the address of your go2rtc: “Own go2rtc Server…” on the left."))
                    default:
                        // go2rtc is on its way: the sign-in sheet waits for it.
                        signInEmpty
                    }
                case .failed(let message):
                    empty(title: String(localized: "No Connection to go2rtc"), symbol: "exclamationmark.triangle", text: message)
                case .ready:
                    if catalog.isEmpty {
                        signInEmpty
                    } else {
                        list
                    }
                }
            }
            footer
        }
        .background(.background.opacity(0.6))
    }

    private var waitingText: String {
        switch SetupServerState.of(model) {
        case .failed: return String(localized: "go2rtc didn’t start. Click “Try Again” on the left.")
        case .unavailable: return String(localized: "This build has no built-in go2rtc. Enter your own server.")
        default: return String(localized: "The list will appear once go2rtc starts.")
        }
    }

    private func empty(title: String, symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Nothing in go2rtc yet: the way to the cameras is the Xiaomi account (a stream is the second option).
    private var signInEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("No Cameras Yet")
                .font(.headline)
            #if WP_NO_XIAOMI
            // A build without Xiaomi: the stream is the way.
            Text(NoXiaomiText.addCamera)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add an RTSP Stream") { sheet = .streams }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 10)
            #else
            Text("Sign in to your Xiaomi account — cameras from the Mi Home app will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In to Xiaomi…") { sheet = .signIn }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 10)
            Button("Or Add an RTSP Stream…") { sheet = .streams }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.top, 2)
            #endif
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $selection) {
            #if !WP_NO_XIAOMI
            if catalog.accounts.isEmpty {
                // Only streams so far: the Mi Home cameras are one sign-in away.
                Section {
                    SetupMiHomeSignInCard(style: .listRow) { sheet = .signIn }
                        .selectionDisabled()
                } header: {
                    WelcomeSectionHeader(title: "Mi Home", detail: nil)
                }
            }
            #endif
            ForEach(catalog.accounts) { account in
                Section {
                    if let error = account.error {
                        Label("Couldn’t load cameras: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(MacPalette.orange)
                            .lineLimit(3)
                            .selectionDisabled()
                    }
                    ForEach(account.cameras) { camera in
                        WelcomeSourceRow(title: camera.name, detail: camera.kind, tooltip: camera.technicalDetails,
                                         source: camera.stillSource, isCamera: true)
                            .tag(camera.id)
                    }
                } header: {
                    WelcomeSectionHeader(title: "Mi Home · ID \(account.id)",
                                         detail: pluralText(account.cameras.count, en: ("camera", "cameras"),
                                                            ru: ("камера", "камеры", "камер")))
                }
            }
            if !catalog.otherStreams.isEmpty {
                Section {
                    ForEach(catalog.otherStreams) { stream in
                        let detail = stream.sources.first.map(SettingsText.redacted) ?? String(localized: "No source specified")
                        WelcomeSourceRow(title: stream.name, detail: detail, tooltip: detail,
                                         source: .stream(stream.name), isCamera: false)
                            .tag(SetupCameraCatalog.streamID(stream.name))
                    }
                } header: {
                    WelcomeSectionHeader(title: String(localized: "go2rtc Streams"), detail: nil)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Open") { open(ids.first) }
        } primaryAction: { ids in
            open(ids.first)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await reload(force: true) }
            } label: {
                if catalog.refreshing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh the list")
            .disabled(!model.setupServerReadyOrDemo || catalog.refreshing)
            if let openError {
                Text(openError)
                    .font(.system(size: 11))
                    .foregroundStyle(MacPalette.red)
                    .lineLimit(2)
                    .help(openError)
            } else if opening {
                ProgressView().controlSize(.small)
                Text("Adding the camera…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { open(selection) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(catalog.choice(for: selection) == nil || opening)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func reload(force: Bool = false) async {
        await catalog.load(model)
        if catalog.choice(for: selection) == nil {
            selection = catalog.currentID(model) ?? firstID
        }
        guard force else { return }
        for stream in catalog.streams { SetupStillStore.shared.request(stream.name, model: model, force: true) }
        for camera in catalog.accounts.flatMap(\.cameras) where camera.streamName == nil {
            SetupStillStore.shared.request(camera.stillSource, model: model, force: true)
        }
    }

    private var firstID: String? {
        if let camera = catalog.accounts.lazy.flatMap(\.cameras).first { return camera.id }
        return catalog.otherStreams.first.map { SetupCameraCatalog.streamID($0.name) }
    }

    /// Registers the chosen camera and saves it; the `isConfigured` change then swaps the windows.
    private func open(_ id: String?) {
        guard let choice = catalog.choice(for: id), !opening else { return }
        opening = true
        openError = nil
        Task {
            defer { opening = false }
            do {
                try await catalog.choose(choice, model: model)
                finish()
            } catch {
                openError = String(localized: "Couldn’t add the camera: \(error.localizedDescription)")
            }
        }
    }

    /// A camera is set: the training window takes over (also when the same camera was chosen again).
    private func finish() {
        guard !finished else { return }
        finished = true
        openWindow(id: "main")
        // Let a picker sheet finish closing before its window goes.
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            dismissWindow(id: "welcome")
            finished = false
        }
    }

    /// One sheet replaces another (sign-in → its cameras) after the first has gone.
    private func show(_ next: WelcomeSheet) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            sheet = next
        }
    }

    private func openDemoSheet() {
        #if DEBUG
        switch SetupDemo.argument(after: "--demo-welcome-sheet") {
        #if !WP_NO_XIAOMI
        case "signin", "captcha", "verify": sheet = .signIn
        #endif
        case "streams": sheet = .streams
        case "server": sheet = .server
        case "picker": sheet = .cameras(accountID: nil)
        default: break
        }
        #endif
    }
}

/// Xcode-style welcome action: symbol, title, one quiet line of detail.
private struct WelcomeActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct WelcomeSectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            if let detail {
                Text(detail).fontWeight(.regular).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A Mi Home camera or a go2rtc stream: still (a preview for a camera that is not a stream yet), name,
/// kind of camera or source, and whether a picture came through.
private struct WelcomeSourceRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let detail: String
    /// The Mi Home model id and address, or the source.
    let tooltip: String
    let source: SetupStillSource
    let isCamera: Bool

    var body: some View {
        let still = SetupStillStore.shared.state(for: source, model: model)
        HStack(spacing: 10) {
            SetupStill(source: source, width: 64, cornerRadius: 5,
                       symbol: isCamera ? "video.fill" : "antenna.radiowaves.left.and.right")
                .saturation(still == .failed ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detailText(still))
                    .font(isCamera ? .system(size: 11) : .system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            switch still {
            case .loaded: StatusDot(color: MacPalette.green, size: 6).help("The camera is responding")
            case .failed: StatusDot(color: .secondary.opacity(0.5), size: 6).help("No picture from the camera")
            case .loading: ProgressView().controlSize(.mini)
            case nil: EmptyView()
            }
        }
        .padding(.vertical, 3)
        .opacity(still == .failed ? 0.65 : 1)
        .help(tooltip.isEmpty ? detail : tooltip)
    }

    private func detailText(_ still: SetupStillStore.State?) -> String {
        if case .failed = still, isCamera { return String(localized: "Offline") }
        if case .loaded(_, let size) = still, isCamera { return "\(SetupText.pixels(size)) · \(detail)" }
        return detail
    }
}
#endif
