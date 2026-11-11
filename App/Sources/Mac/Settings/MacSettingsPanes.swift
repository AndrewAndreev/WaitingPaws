#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// The grouped form on the right of Settings.
struct MacSettingsDetail: View {
    let pane: MacSettingsPane
    @Binding var sheet: MacSettingsSheet?

    var body: some View {
        Form {
            switch pane {
            case .camera: SettingsCameraPane(sheet: $sheet)
            case .connection: SettingsConnectionPane()
            case .training: SettingsTrainingPane()
            case .files: SettingsFilesPane()
            case .iPhone: SettingsIPhonePane()
            case .diagnostics: SettingsDiagnosticsPane()
            case .about: SettingsAboutPane()
            }
        }
        .formStyle(.grouped)
    }
}

/// The camera Settings describe: the saved one, or (DEBUG `--demo-cameras`, nothing saved) the demo camera.
struct SettingsCamera {
    var isConfigured: Bool
    var name: String
    var streamName: String
    var accountID: String
    var region: XiaomiRegion
    var isXiaomi: Bool
    var isDemo = false

    /// `source`: the stream's source once read from go2rtc — it settles whether this is a Mi Home camera.
    /// Without it the quality go2rtc reported decides; the saved account only while go2rtc is not running
    /// (it stays saved after switching to an RTSP stream).
    @MainActor
    init(_ model: AppModel, source: String? = nil) {
        let settings = model.settings
        #if DEBUG
        if SetupDemo.isOn && !settings.isConfigured {
            isDemo = true
            region = .ru
            if SetupDemo.hasXiaomi {
                isConfigured = true
                name = SetupDemo.cameraName
                streamName = SetupDemo.cameraStream
                accountID = SetupDemo.accountID
                isXiaomi = true
            } else {
                isConfigured = SetupDemo.hasStreams
                name = isConfigured ? SetupDemo.rtspStream : ""
                streamName = isConfigured ? SetupDemo.rtspStream : ""
                accountID = ""
                isXiaomi = false
            }
            return
        }
        #endif
        isConfigured = settings.isConfigured
        name = settings.cameraDisplayName
        streamName = settings.streamName
        accountID = settings.xiaomiAccountID
        region = settings.xiaomiRegion
        if let source {
            isXiaomi = source.hasPrefix("xiaomi://")
        } else if model.setupServerReady {
            isXiaomi = model.xiaomiQuality != nil
        } else {
            isXiaomi = !settings.xiaomiAccountID.isEmpty
        }
    }
}

/// System Settings pane header: big icon, name, one line about the pane.
private struct SettingsPaneHeader: View {
    let pane: MacSettingsPane
    let text: String

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SetupIconTile(symbol: pane.symbol, color: pane.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Камера

private struct SettingsCameraPane: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: MacSettingsSheet?
    @State private var reloadToken = 0
    @State private var switchingQuality = false
    /// The stream's source as written in the go2rtc config.
    @State private var source: String?
    /// Xiaomi accounts signed in on go2rtc; `nil` while unknown (go2rtc not running, no xiaomi module).
    @State private var accounts: [String]?
    @State private var demoQuality: AppModel.XiaomiQuality = .auto
    /// «Выйти…» asked for this account (confirmation shown).
    @State private var signOutAccount: String?
    @State private var signingOut: String?

    var body: some View {
        @Bindable var settings = model.settings
        let camera = SettingsCamera(model, source: source)

        Section {
            VStack(spacing: 10) {
                SettingsCameraCard(camera: camera, reloadToken: $reloadToken) { sheet = .picker(accountID: nil) }
                    .frame(width: 400)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                VStack(spacing: 2) {
                    Text(camera.isConfigured ? camera.name : String(localized: "No camera selected"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(detailLine(camera))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cameraModel(camera).map { String(localized: "Mi Home model: \($0)") } ?? "")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .task(id: settings.streamName) { await load(camera) }
        #if !WP_NO_XIAOMI // a build without Xiaomi (`NoXiaomiText`) asks go2rtc for no accounts
        // Again after a sign-in or a camera change in a sheet.
        .task(id: "\(model.setupServerReady)|\(sheet == nil)") { await loadAccounts() }
        #endif

        #if !WP_NO_XIAOMI
        if accounts?.isEmpty == true {
            // No Xiaomi account on go2rtc: the way to Mi Home cameras, right under the picture.
            Section {
                SetupMiHomeSignInCard(style: .formRow) { sheet = .signIn }
            }
        }
        #endif

        Section {
            #if !WP_NO_XIAOMI // the quality is a Mi Home camera's: none in a build without Xiaomi
            LabeledContent {
                Picker("Quality", selection: quality(camera)) {
                    ForEach(AppModel.XiaomiQuality.allCases) { Text(model.qualityTitle($0, source: source)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!qualityAvailable(camera) || switchingQuality)
            } label: {
                Text("Quality")
                if !camera.isConfigured {
                    Text("Choose a camera first.")
                } else if !qualityAvailable(camera) {
                    Text("Can only be changed for Mi Home cameras.")
                } else {
                    Text("On screen and in recordings.")
                }
            }
            #endif
            LabeledContent("Current") {
                HStack(spacing: 6) {
                    if switchingQuality { ProgressView().controlSize(.mini) }
                    Text(currentSize(camera)).monospacedDigit()
                }
            }
            Picker("Player", selection: $settings.playerMode) {
                ForEach(settings.availablePlayerModes) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $settings.audioEnabled) {
                Text("Camera sound in the app")
                Text("Player only: recordings always include sound.")
            }
        } header: {
            Text("Picture & Sound")
        } footer: {
            if settings.connectionMode == .embedded {
                Text("WebRTC (lowest latency) is only available with your own go2rtc server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        SettingsCameraModesSection(camera: camera)

        Section {
            LabeledContent("go2rtc stream") {
                Text(camera.isConfigured ? camera.streamName : "—")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let source, !source.hasPrefix("xiaomi://") {
                LabeledContent("Source") {
                    Text(SettingsText.redacted(source))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if camera.isXiaomi {
                LabeledContent("Xiaomi Account",
                               value: camera.accountID.isEmpty ? "—" : "ID \(camera.accountID) · \(SetupText.regionTitle(camera.region))")
            }
        } header: {
            Text("Source")
        } footer: {
            HStack(spacing: 8) {
                Spacer()
                #if !WP_NO_XIAOMI
                // With no account the card above already offers the sign-in.
                if accounts?.isEmpty != true {
                    Button(accounts == nil ? "Sign In to Xiaomi…" : "Sign In to Another Xiaomi Account…") { sheet = .signIn }
                }
                #endif
                Button("Choose Camera…") { sheet = .picker(accountID: nil) }
            }
        }

        #if !WP_NO_XIAOMI
        if let accounts, !accounts.isEmpty {
            Section {
                ForEach(accounts, id: \.self) { account in
                    LabeledContent {
                        if signingOut == account {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Sign Out…") { signOutAccount = account }
                                .disabled(signingOut != nil)
                        }
                    } label: {
                        Label("ID \(account)", systemImage: "person.crop.circle")
                    }
                }
            } header: {
                Text("Xiaomi Accounts")
            } footer: {
                Text("Signing out removes the Xiaomi access key from this Mac and the account’s cameras from the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .alert("Sign Out of Xiaomi?", isPresented: Binding(get: { signOutAccount != nil },
                                                                   set: { if !$0 { signOutAccount = nil } })) {
                Button("Sign Out", role: .destructive) {
                    guard let account = signOutAccount else { return }
                    signingOut = account
                    Task {
                        await model.signOutOfXiaomi(accountID: account)
                        signingOut = nil
                        await loadAccounts()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This account’s cameras will no longer be shown. You can sign in again at any time.")
            }
        }
        #endif
    }

    private func qualityAvailable(_ camera: SettingsCamera) -> Bool {
        camera.isDemo ? camera.isXiaomi : model.xiaomiQuality != nil
    }

    /// "Камера Xiaomi · аккаунт 6218440137" (the Mi Home model id stays in the tooltip) or "RTSP · 192.168.1.20".
    private func detailLine(_ camera: SettingsCamera) -> String {
        #if WP_NO_XIAOMI
        guard camera.isConfigured else { return String(localized: "Choose a camera first.") }
        #else
        guard camera.isConfigured else { return String(localized: "Choose a Mi Home camera or a go2rtc stream.") }
        #endif
        if camera.isXiaomi {
            return [SetupText.cameraKind(model: cameraModel(camera)),
                    camera.accountID.isEmpty ? nil : String(localized: "account \(camera.accountID)")].compactMap { $0 }.joined(separator: " · ")
        }
        if let source, let badge = SetupText.sourceBadge(source) {
            let host = URLComponents(string: source)?.host
            return [badge, host].compactMap { $0 }.joined(separator: " · ")
        }
        return String(localized: "go2rtc stream")
    }

    private func cameraModel(_ camera: SettingsCamera) -> String? {
        source.flatMap { SetupCameraCatalog.query("model", in: $0) }
    }

    private func currentSize(_ camera: SettingsCamera) -> String {
        #if DEBUG
        if camera.isDemo, camera.isConfigured, case .loaded(_, let size) = SetupDemo.still(for: camera.streamName) {
            return SetupText.pixels(size)
        }
        #endif
        guard let size = model.videoSize else { return camera.isConfigured ? "—" : String(localized: "no camera") }
        return SetupText.pixels(size)
    }

    private func quality(_ camera: SettingsCamera) -> Binding<AppModel.XiaomiQuality> {
        Binding {
            camera.isDemo ? demoQuality : (model.xiaomiQuality ?? .auto)
        } set: { new in
            if camera.isDemo {
                demoQuality = new
                return
            }
            guard new != model.xiaomiQuality, !switchingQuality else { return }
            switchingQuality = true
            Task {
                await model.setXiaomiQuality(new)
                switchingQuality = false
            }
        }
    }

    private func loadAccounts() async {
        #if DEBUG
        if SetupDemo.isOn {
            accounts = SetupDemo.accounts.map(\.id)
            return
        }
        #endif
        guard model.setupServerReady, let client = model.client else {
            accounts = nil
            return
        }
        // A server without the xiaomi module answers 404: unknown, no sign-in card then.
        accounts = try? await client.xiaomiAccounts()
    }

    private func load(_ camera: SettingsCamera) async {
        source = nil
        #if DEBUG
        if camera.isDemo {
            source = SetupDemo.streams.first { $0.name == camera.streamName }?.sources.first
            return
        }
        #endif
        guard camera.isConfigured, model.setupServerReady, let client = model.client else { return }
        await model.refreshXiaomiQuality()
        // Again on every visit: the modes may have been changed in Mi Home meanwhile.
        await model.refreshCameraModes()
        let name = model.settings.streamName
        var sources = (try? await client.configuredSources(stream: name)) ?? []
        if sources.isEmpty {
            sources = (try? await client.streams())?.first { $0.name == name }?.sources ?? []
        }
        source = sources.first
    }
}

/// Night mode, image flip, status light… as the camera's MIoT spec declares them (Mi Home cameras only).
private struct SettingsCameraModesSection: View {
    @Environment(AppModel.self) private var model
    let camera: SettingsCamera

    var body: some View {
        let modes = model.cameraModes
        if modes.hasOptions {
            Section {
                ForEach(modes.pictureOptions) { CameraModeFormRow(option: $0) }
                ForEach(modes.behaviourOptions) { CameraModeFormRow(option: $0) }
            } header: {
                HStack(spacing: 6) {
                    Text("Camera Mode")
                    if modes.state == .loading || !modes.pending.isEmpty { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Group {
                    if let error = modes.changeError {
                        Text(error).foregroundStyle(.red)
                    } else if case .unavailable(let reason) = modes.state {
                        Text(reason).foregroundStyle(.orange)
                    } else {
                        Text("These settings are stored in the camera itself and changed through the Xiaomi cloud, as in Mi Home.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
        } else if camera.isXiaomi, modes.state == .loading {
            Section("Camera Mode") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading camera settings…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The live picture on top of the Camera pane (the same go2rtc player as the training window, muted).
private struct SettingsCameraCard: View {
    @Environment(AppModel.self) private var model
    let camera: SettingsCamera
    @Binding var reloadToken: Int
    var choose: () -> Void
    @State private var liveSize: CGSize?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            picture
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let chip = chipText {
                HStack(spacing: 6) {
                    if liveSize == nil && !camera.isDemo {
                        ProgressView().controlSize(.mini)
                    } else {
                        StatusDot(size: 6)
                    }
                    Text(chip)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .glassEffect(.regular, in: .capsule)
                .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isPlaying {
                Button {
                    liveSize = nil
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 24)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Reconnect the camera")
                .padding(8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .onChange(of: camera.streamName) { liveSize = nil }
    }

    private var isPlaying: Bool {
        camera.isConfigured && !camera.isDemo && model.setupServerReady && model.settings.server != nil
    }

    private var chipText: String? {
        if camera.isDemo {
            guard case .loaded(_, let size) = demoStill else { return nil }
            return String(localized: "Live · \(SetupText.pixels(size))")
        }
        guard isPlaying else { return nil }
        return liveSize.map { String(localized: "Live · \(SetupText.pixels($0))") } ?? String(localized: "Connecting…")
    }

    @ViewBuilder
    private var picture: some View {
        if camera.isDemo, let image = demoImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if isPlaying, let server = model.settings.server {
            CameraStreamView(server: server, stream: camera.streamName, mode: model.settings.playerMode,
                             audioEnabled: false, fill: true, reloadToken: reloadToken + model.playerGeneration,
                             showsStatus: false) { size in
                liveSize = size
                model.videoSize = size
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "video.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text(placeholderText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                if !camera.isConfigured {
                    Button("Choose Camera…", action: choose)
                        .buttonStyle(.borderedProminent)
                        .tint(MacPalette.pinkDeep)
                }
            }
        }
    }

    private var placeholderText: String {
        guard camera.isConfigured else { return String(localized: "The camera picture will appear here") }
        switch SetupServerState.of(model) {
        case .starting: return String(localized: "Starting go2rtc…")
        case .failed, .stopped, .unavailable: return String(localized: "go2rtc is not running")
        default: return String(localized: "No picture")
        }
    }

    private var demoImage: NSImage? {
        guard case .loaded(let image, _) = demoStill else { return nil }
        return image
    }

    private var demoStill: SetupStillStore.State? {
        #if DEBUG
        guard camera.isDemo, camera.isConfigured else { return nil }
        return SetupDemo.still(for: camera.streamName)
        #else
        return nil
        #endif
    }
}

// MARK: - Подключение

private struct SettingsConnectionPane: View {
    @Environment(AppModel.self) private var model
    @State private var check: SetupServerSheet.Check = .idle
    /// «Свой сервер go2rtc» picked while there's no address yet: the mode switches with «Подключить». Switched at once,
    /// the app would be left without a camera, and the training window would close into the welcome one.
    @State private var choosingServer = false
    /// What the address field shows while it isn't an address (see `address`).
    @State private var addressDraft: String?

    var body: some View {
        @Bindable var settings = model.settings
        // A training or a recording runs: switching the server would cut the camera (and the recording) off.
        let busy = model.session != nil || model.isRecordingNow
        #if WP_NO_XIAOMI
        SettingsPaneHeader(pane: .connection, text: NoXiaomiText.connectionHeader)
        #else
        SettingsPaneHeader(pane: .connection, text: String(localized: "Where go2rtc runs — the server that pulls video from the Xiaomi camera."))
        #endif
        Section {
            Picker("Mode", selection: modeSelection) {
                ForEach(ConnectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: settings.connectionMode) {
                model.connectionModeChanged()
                check = .idle
            }
            if settings.connectionMode == .embedded && !choosingServer {
                LabeledContent("Status") {
                    SetupServerStatusLabel()
                }
                LabeledContent("Address", value: "127.0.0.1:\(EmbeddedGo2RTC.apiPort)")
                LabeledContent {
                    Button("Show in Finder") { Finder.reveal(EmbeddedGo2RTC.configURL) }
                } label: {
                    Text("go2rtc.yaml File")
                    #if WP_NO_XIAOMI
                    Text(NoXiaomiText.configFile)
                    #else
                    Text("Streams and the Xiaomi sign-in. Don’t share it: it contains tokens.")
                    #endif
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.connectionMode == .embedded && !choosingServer
                     ? "go2rtc runs inside the app; the camera must be on the same Wi‑Fi network. Video and recording work while the app is open."
                     : "A separate go2rtc server on the network: for round-the-clock recording or access from outside your home.")
                if busy { Text("The server can’t be changed during a training or recording.") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .disabled(busy)
        Section {
            TextField("Address", text: address, prompt: Text("http://192.168.1.10:1984"))
                .plainInput()
            TextField("Username", text: $settings.serverUsername, prompt: Text("Optional"))
                .plainInput()
            SecureField("Password", text: $settings.serverPassword, prompt: Text("Optional"))
            HStack(spacing: 8) {
                result
                Spacer(minLength: 8)
                if choosingServer {
                    Button("Connect") {
                        choosingServer = false
                        settings.connectionMode = .external
                    }
                    .disabled(Go2RTCServer.parse(address.wrappedValue) == nil)
                } else {
                    Button("Check") { Task { await runCheck() } }
                        .disabled(check == .checking || Go2RTCServer.parse(address.wrappedValue) == nil)
                }
            }
        } header: {
            Text("Own Server")
        }
        .disabled(busy || (settings.connectionMode == .embedded && !choosingServer))
        .onChange(of: settings.serverURLString) { check = .idle }
    }

    /// The server's address. With «Свой сервер» on, text that isn't an address (a cleared field, one being retyped)
    /// stays in the field only: saved, it would leave the app without a server and close the window into the welcome one.
    private var address: Binding<String> {
        Binding(get: { addressDraft ?? model.settings.serverURLString },
                set: { text in
                    let usable = model.settings.connectionMode == .embedded || Go2RTCServer.parse(text) != nil
                    addressDraft = usable ? nil : text
                    if usable { model.settings.serverURLString = text }
                })
    }

    /// «Свой сервер go2rtc» without a usable address only opens the server's fields (see `choosingServer`).
    private var modeSelection: Binding<ConnectionMode> {
        Binding(get: { choosingServer ? .external : model.settings.connectionMode },
                set: { mode in
                    choosingServer = mode == .external && model.settings.connectionMode == .embedded
                        && Go2RTCServer.parse(model.settings.serverURLString) == nil
                    if !choosingServer { model.settings.connectionMode = mode }
                })
    }

    @ViewBuilder
    private var result: some View {
        switch check {
        case .idle:
            #if WP_NO_XIAOMI
            EmptyView() // any go2rtc plays RTSP
            #else
            Text("Requires version 1.9.11 or later with the xiaomi module.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #endif
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let version):
            Label(version.isEmpty ? "Server is responding" : "go2rtc \(version) is responding", systemImage: "checkmark.circle.fill")
                .foregroundStyle(MacPalette.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(MacPalette.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private func runCheck() async {
        guard let server = model.settings.server, model.settings.connectionMode == .external else {
            check = .failed(String(localized: "Invalid address"))
            return
        }
        check = .checking
        do {
            check = .ok(try await Go2RTCClient(server: server).version())
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Тренировка

private struct SettingsTrainingPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPaneHeader(pane: .training, text: String(localized: "What happens when a training starts. It ends only with the Finish button."))
        Section {
            Toggle(isOn: $settings.autoRecord) {
                Text("Start recording with the training")
                Text("Camera video is recorded from the start of the training to the end.")
            }
        }
    }
}

// MARK: - Запись и файлы

private struct SettingsFilesPane: View {
    @Environment(AppModel.self) private var model
    @State private var usage: String?

    var body: some View {
        @Bindable var settings = model.settings
        let folder = model.store.rootDirectory
        SettingsPaneHeader(pane: .files, text: String(localized: "Training videos and logs are stored on this Mac."))
        Section {
            LabeledContent {
                Button("Show in Finder") { Finder.reveal(folder) }
            } label: {
                Label {
                    Text(folder.lastPathComponent)
                    Text(SettingsText.displayPath(folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color(red: 0.32, green: 0.64, blue: 0.98))
                }
            }
            LabeledContent("Used", value: usage ?? String(localized: "Calculating…"))
        }
        .task(id: model.history.count) { usage = await SettingsText.usage(of: model.store) }
        Section {
            Toggle(isOn: $settings.saveToPhotos) {
                Text("Save videos to Photos")
                Text("A copy of every recording goes to your Photos library.")
            }
        }
    }
}

// MARK: - iPhone

private struct SettingsIPhonePane: View {
    @Environment(AppModel.self) private var model
    /// «Забыть…» clicked for this iPhone (confirmation shown).
    @State private var forgetDevice: SyncHost.PairedDevice?

    var body: some View {
        @Bindable var settings = model.settings
        let host = model.syncHost
        SettingsPaneHeader(pane: .iPhone, text: String(localized: "An iPhone on the same network shows this Mac’s camera and runs the training."))
        Section {
            Toggle(isOn: $settings.shareWithIPhone) {
                Text("Allow connections from iPhone")
                Text("Waiting Paws on an iPhone on the same Wi‑Fi network can see this Mac.")
            }
            .onChange(of: settings.shareWithIPhone) { _, on in
                guard !AppModel.isUIPreview else { return }
                if on { host.start() } else { host.stop() }
            }
        } footer: {
            if settings.shareWithIPhone && !model.embedded.lanEnabled && settings.connectionMode == .embedded {
                Label("Video for iPhone will be available after Waiting Paws restarts.", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if settings.shareWithIPhone && settings.connectionMode == .external {
                // The iPhone is given only this Mac's built-in go2rtc, never the user's server (`AppModel.setUpSync`).
                Label("With your own go2rtc server, the iPhone runs the training but doesn’t show the camera.", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            LabeledContent {
                TextField("This Mac's Name", text: $settings.deviceName, prompt: Text(SyncIdentity.systemName))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240)
            } label: {
                Text("This Mac's Name")
                Text("iPhones see this \(SyncIdentity.model) under this name.")
            }
        }
        Section {
            if host.pairedDevices.isEmpty {
                Text("No iPhone has connected yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(host.pairedDevices) { paired in
                let online = host.isConnected(paired)
                LabeledContent {
                    Button("Forget…") { forgetDevice = paired }
                } label: {
                    Label {
                        Text(paired.name)
                        Text(detail(paired, online: online))
                    } icon: {
                        Image(systemName: paired.device.symbolName)
                            .foregroundStyle(online ? MacPalette.green : .secondary)
                    }
                }
            }
        } header: {
            Text("Allowed iPhones")
        } footer: {
            Text("Each iPhone’s first connection must be allowed on this Mac. The recording and log stay on the Mac. After “Forget”, the iPhone will ask for permission again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .alert(forgetDevice.map { String(localized: "Forget “\($0.name)”?") } ?? "",
               isPresented: Binding(get: { forgetDevice != nil }, set: { if !$0 { forgetDevice = nil } }),
               presenting: forgetDevice) { paired in
            Button("Forget", role: .destructive) { host.forget(paired) }
            Button("Cancel", role: .cancel) {}
        } message: { paired in
            let again = String(localized: "To connect again, the iPhone will ask for permission on this Mac.")
            Text(host.isConnected(paired) ? String(localized: "The iPhone will disconnect.") + " " + again : again)
        }
    }

    /// "iPhone 16 · Подключён сейчас": the model tells two iPhones apart (iOS names them all "iPhone").
    private func detail(_ paired: SyncHost.PairedDevice, online: Bool) -> String {
        var parts: [String] = []
        if let model = paired.device.distinctModel { parts.append(model) }
        if online {
            parts.append(String(localized: "Connected now"))
        } else if let lastSeen = paired.lastSeen {
            parts.append(String(localized: "Last connected \(lastSeen.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(String(localized: "Connection allowed"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Диагностика

private struct SettingsDiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPaneHeader(pane: .diagnostics, text: String(localized: "CPU and memory load — in case the video stutters."))
        Section {
            Toggle(isOn: $settings.showPerformance) {
                Text("Show performance stats")
                Text("Over the camera: how many seconds the picture trails the camera (network and player buffer), CPU, memory and interface hangs.")
            }
            .onChange(of: settings.showPerformance) { _, on in
                if on { model.performance.start() } else { model.performance.stop() }
            }
            if model.performance.isRunning {
                LabeledContent("Current", value: SettingsText.performance(model.performance.sample))
                    .monospacedDigit()
                if let delay = model.performance.sample.videoDelayText {
                    LabeledContent("Delay", value: delay)
                        .monospacedDigit()
                }
            }
        }
        Section {
            LabeledContent {
                Button("Show in Finder") {
                    Finder.reveal(AppModel.logsDirectory)
                }
            } label: {
                Text("App Log")
                Text("Useful if the camera won’t connect or a recording stopped unexpectedly.")
            }
        }
    }
}

// MARK: - О приложении

private struct SettingsAboutPane: View {
    @State private var showPrivacy = false
    @State private var showLicenses = false

    var body: some View {
        SettingsPaneHeader(pane: .about, text: String(localized: "Version, privacy policy and licenses."))
        Section {
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Privacy Policy") {
                Button("Open…") { showPrivacy = true }
            }
            LabeledContent("Open-Source Licenses") {
                Button("Open…") { showLicenses = true }
            }
        } footer: {
            Text("Waiting Paws collects nothing and sends nothing to the developer: settings, logs and videos stay on your devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showPrivacy) { AboutSheet { PrivacyPolicyView() } }
        .sheet(isPresented: $showLicenses) { AboutSheet { LicensesView() } }
        #if WP_DIRECT
        if let updater = AppUpdater.shared {
            SettingsUpdatesSection(updater: updater)
        }
        #endif
    }
}

#if WP_DIRECT
/// The app from GitHub (lab Design/updates-lab, S2): the mode, nightly builds, a waiting version, «Проверить сейчас».
/// The App Store app has no such section.
private struct SettingsUpdatesSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section("Updates") {
            if updater.isAvailable {
                Picker(selection: $updater.mode) {
                    ForEach(AppUpdater.Mode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("New versions")
                    Text(updater.mode.explanation)
                }
                Toggle(isOn: $updater.nightly) {
                    Text("Test builds (nightly)")
                    Text("New things before the regular versions, with possible bugs. After turning this off, the test build stays until the next regular version.")
                }
                if let pending = updater.pending {
                    LabeledContent {
                        Button(pending.downloaded ? "Restart" : "Download and Install") { updater.installPending() }
                    } label: {
                        Text(pending.downloaded ? "Version \(pending.version) downloaded" : "Version \(pending.version) available")
                            .foregroundStyle(MacPalette.accent)
                        Text(pending.downloaded ? "Installs when you quit Waiting Paws." : "Downloads and installs when you click the button.")
                    }
                }
                LabeledContent {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                } label: {
                    Text("Last check")
                    if let lastCheck = updater.lastCheck {
                        Text(lastCheck, format: .relative(presentation: .named))
                    } else {
                        Text("not yet")
                    }
                }
            } else {
                Text("Updates are off in a development build.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

/// The privacy policy or the licenses over Settings, with «Готово».
private struct AboutSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - Text helpers

enum SettingsText {
    /// The real path with "~" for the user's home (in the sandbox `NSHomeDirectory()` is the container).
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A source URL without its password ("rtsp://admin:secret@…" → "rtsp://admin@…").
    static func redacted(_ source: String) -> String {
        guard var components = URLComponents(string: source), components.password != nil else { return source }
        components.password = nil
        return components.string ?? source
    }

    /// "3,9 ГБ · 13 видео · 11 логов" / "3.9 GB · 13 videos · 11 logs".
    static func usage(of store: SessionStore) async -> String {
        let root = store.rootDirectory
        let recordings = store.recordingsDirectory
        let sessions = store.sessionsDirectory
        return await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let bytes = folderSize(root)
            let videos = ((try? manager.contentsOfDirectory(atPath: recordings.path)) ?? []).filter { $0.hasSuffix(".mp4") }.count
            let logs = ((try? manager.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { $0.hasSuffix(".json") }.count
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            guard videos > 0 || logs > 0 else { return bytes > 0 ? String(localized: "\(size) · no trainings yet") : String(localized: "Nothing yet") }
            var parts = [size]
            if videos > 0 { parts.append(pluralText(videos, en: ("video", "videos"), ru: ("видео", "видео", "видео"))) }
            if logs > 0 { parts.append(pluralText(logs, en: ("log", "logs"), ru: ("лог", "лога", "логов"))) }
            return parts.joined(separator: " · ")
        }.value
    }

    private static func folderSize(_ root: URL) -> Int64 {
        var bytes: Int64 = 0
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return bytes
    }

    /// "CPU 14 % · главный поток 3 % · 212 МБ · UI +18 мс · 41 поток".
    static func performance(_ sample: PerformanceMonitor.Sample) -> String {
        [
            String(localized: "CPU \(Int(sample.cpuTotal.rounded())) %"),
            String(localized: "main thread \(Int(sample.cpuMain.rounded()))%"),
            String(localized: "\(Int(sample.memoryMB.rounded())) MB"),
            String(localized: "UI +\(Int(sample.maxHangMs.rounded())) ms"),
            pluralText(sample.threads, en: ("thread", "threads"), ru: ("поток", "потока", "потоков")),
        ].joined(separator: " · ")
    }
}
#endif
