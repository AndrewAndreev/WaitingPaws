import SwiftUI
import WaitingPawsCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var checkStatus = ""
    @State private var showXiaomi = false
    @State private var showCameraPicker = false
    @State private var confirmSignOut = false
    @State private var signingOut = false
    /// «Свой сервер go2rtc» picked while there's no address yet: the mode switches with «Подключить». Switched at once,
    /// the app would be left without a camera and go back to the first-launch setup.
    @State private var choosingServer = false
    /// What the address field shows while it isn't an address (see `address`).
    @State private var addressDraft: String?
    #if os(iOS)
    /// «Забыть» tapped for this computer (confirmation shown).
    @State private var forgetHost: SyncClient.PairedHost?
    #endif

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Mode", selection: modeSelection) {
                        ForEach(ConnectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .onChange(of: settings.connectionMode) { _, _ in
                        model.startEmbeddedIfNeeded()
                        checkStatus = ""
                    }
                    if settings.connectionMode == .embedded && !choosingServer {
                        LabeledContent("Status", value: embeddedStatusText)
                    } else {
                        TextField("Address", text: address, prompt: Text("http://192.168.1.10:1984"))
                            .plainInput()
                        TextField("Username", text: $settings.serverUsername)
                            .plainInput()
                        SecureField("Password", text: $settings.serverPassword)
                        HStack {
                            if choosingServer {
                                Button("Connect") {
                                    choosingServer = false
                                    settings.connectionMode = .external
                                }
                                .disabled(Go2RTCServer.parse(address.wrappedValue) == nil)
                            } else {
                                Button("Check") { Task { await check() } }
                            }
                            Spacer()
                            Text(checkStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.connectionMode == .embedded && !choosingServer
                             ? "go2rtc runs inside the app; the camera must be on the same Wi-Fi network. Video and recording work while the app is open."
                             : "A separate go2rtc server on your network: useful for access away from home or for continuous recording.")
                        if isBusy { Text("The server can’t be changed during a training or recording.") }
                    }
                }
                .disabled(isBusy)

                Section {
                    LabeledContent("Stream", value: settings.cameraDisplayName.isEmpty ? "—" : settings.cameraDisplayName)
                    #if WP_NO_XIAOMI // a build without Xiaomi (`NoXiaomiText`): no account, no sign-in
                    Button("Choose Camera…") { showCameraPicker = true }
                    #else
                    LabeledContent("Xiaomi Account", value: settings.xiaomiAccountID.isEmpty ? "—" : "ID \(settings.xiaomiAccountID) · \(settings.xiaomiRegion.rawValue)")
                    Button("Choose Camera…") { showCameraPicker = true }
                    if settings.xiaomiAccountID.isEmpty {
                        Button("Sign In to Xiaomi…|account") { showXiaomi = true }
                    } else {
                        Button("Sign In to Another Xiaomi Account…") { showXiaomi = true }
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            HStack {
                                Text("Sign Out of Xiaomi")
                                if signingOut { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(signingOut)
                    }
                    #endif
                } header: {
                    Text("Camera")
                } footer: {
                    #if !WP_NO_XIAOMI
                    if !settings.xiaomiAccountID.isEmpty {
                        Text("After you sign out, the Xiaomi access key is removed from the device and this account’s cameras are removed from the app.")
                    }
                    #endif
                }

                Section {
                    Picker("Mode", selection: $settings.playerMode) {
                        ForEach(settings.availablePlayerModes) { mode in Text(mode.title).tag(mode) }
                    }
                    Toggle("Camera sound in the app", isOn: $settings.audioEnabled)
                } header: {
                    Text("Player")
                } footer: {
                    Text("This only affects the player; video is always recorded with the camera’s sound.")
                }

                Section {
                    Toggle("Start recording with the training", isOn: $settings.autoRecord)
                    Toggle("Save videos to Photos", isOn: $settings.saveToPhotos)
                    #if os(iOS)
                    Picker("Haptics", selection: $settings.hapticStrength) {
                        ForEach(HapticStrength.allCases) { strength in Text(strength.title).tag(strength) }
                    }
                    // Chosen, it is felt at once: put the phone where it lies during a training and listen.
                    .onChange(of: settings.hapticStrength) { _, strength in TrainingBuzz.shared.play(strength) }
                    TrainingAlertsToggle(isOn: $settings.notifications)
                    #endif
                } header: {
                    Text("Training")
                } footer: {
                    #if os(iOS)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A short vibration when time is up: the exit's plan, the break, a condition's countdown or the quiet. It's a timer signal, not a sign that it's OK to go in.")
                        Text("When the app is in the background or the screen is locked, a notification tells you the same — silently, so the dog doesn't hear it.")
                        Text("The strength is for the end of a break, and each iPhone keeps its own: Light is one short buzz, like a notification; Strong is three long ones, felt with the phone on a table. With the screen locked, iOS vibrates its own way.")
                    }
                    #endif
                }
                .id("training")

                #if os(iOS)
                macSection
                P2PSettingsSection()
                #endif

                #if os(macOS)
                Section {
                    Toggle("Allow connections from iPhone", isOn: $settings.shareWithIPhone)
                        .onChange(of: settings.shareWithIPhone) { _, on in
                            if on { model.syncHost.start() } else { model.syncHost.stop() }
                        }
                    ForEach(model.syncHost.pairedDevices) { device in
                        LabeledContent(device.name) {
                            Button("Forget") { model.syncHost.forget(device) }
                        }
                    }
                } header: {
                    Text("iPhone")
                } footer: {
                    Text(settings.shareWithIPhone && !model.embedded.lanEnabled && settings.connectionMode == .embedded
                         ? "An iPhone on the same network will find this Mac, show its camera, and be able to run the training. Video for iPhone becomes available after the app restarts."
                         : "An iPhone on the same network will find this Mac, show its camera, and be able to run the training. Recordings and the log stay on the Mac. Each iPhone’s first connection must be allowed here.")
                }
                #endif

                Section("Diagnostics") {
                    Toggle("Show performance stats", isOn: $settings.showPerformance)
                        .onChange(of: settings.showPerformance) { _, on in
                            if on { model.performance.start() } else { model.performance.stop() }
                        }
                    Text("Over the camera: how many seconds the picture trails the camera (network and player buffer), CPU, memory and interface hangs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    #if os(macOS)
                    Button("Show in Finder") { Finder.reveal(model.store.rootDirectory) }
                    #else
                    Text("Videos and logs are in the Files app → On My iPhone → Waiting Paws.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                } header: {
                    Text("Files")
                }

                Section {
                    LabeledContent("Version", value: AppInfo.version)
                    NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                    NavigationLink("Open-Source Licenses") { LicensesView() }
                } header: {
                    Text("About")
                }
            }
            .formStyle(.grouped)
            #if DEBUG && os(iOS)
            // `--demo-screen settings-sync` / `settings-training`: opens scrolled to «Синхронизация» / «Тренировка» (UI
            // checks without scrolling).
            .onAppear {
                let target = CommandLine.arguments.contains("settings-sync") ? "sync"
                    : CommandLine.arguments.contains("settings-training") ? "training" : nil
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
            }
            #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if !WP_NO_XIAOMI
            .sheet(isPresented: $showXiaomi) {
                XiaomiSignInSheet { _ in
                    showXiaomi = false
                    showCameraPicker = true
                }
                .environment(model)
                .sheetFrame(width: 520, height: 620)
            }
            .confirmationDialog("Sign Out of Xiaomi?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    let account = settings.xiaomiAccountID
                    signingOut = true
                    Task {
                        await model.signOutOfXiaomi(accountID: account)
                        signingOut = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This account’s cameras will no longer be shown. You can sign in again at any time.")
            }
            #endif
            .sheet(isPresented: $showCameraPicker) {
                NavigationStack {
                    CameraPickerView(showsClose: true) { _ in
                        showCameraPicker = false
                    }
                }
                .environment(model)
                .sheetFrame(width: 520, height: 560)
            }
            #if os(iOS)
            .confirmationDialog(forgetHost.map { String(localized: "Forget “\($0.device.name)”?") } ?? "",
                                isPresented: Binding(get: { forgetHost != nil }, set: { if !$0 { forgetHost = nil } }),
                                titleVisibility: .visible, presenting: forgetHost) { host in
                Button("Forget", role: .destructive) { model.syncClient.forget(host.id) }
                Button("Cancel", role: .cancel) {}
            } message: { host in
                Text(forgetMessage(host))
            }
            #endif
        }
    }

    /// A training or a recording runs here: switching the server would cut the camera (and the recording) off. One on
    /// a linked Mac doesn't use this iPhone's server.
    private var isBusy: Bool {
        (model.session != nil && !model.isMirroringSession) || (model.isRecordingNow && !model.isLinkedToMac)
    }

    /// The server's address. With «Свой сервер» on, text that isn't an address (a cleared field, one being retyped)
    /// stays in the field only: saved, it would leave the app without a server and send it back to the first-launch setup.
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

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle: return String(localized: "not running")
        case .starting: return String(localized: "starting…")
        case .running(let version): return String(localized: "running, go2rtc \(version)")
        case .failed(let message): return String(localized: "error: \(message)")
        case .unavailable: return String(localized: "framework not built")
        }
    }

    #if os(iOS)
    /// The way to a computer that is always there (the «Рядом Mac» card on the main screen can be closed or pushed
    /// out): which one to sync with, this iPhone's name for them, and the ones joined before (to forget).
    @ViewBuilder
    private var macSection: some View {
        @Bindable var settings = model.settings
        let client = model.syncClient
        Section {
            LabeledContent("This \(SyncIdentity.platform.title)'s Name") {
                TextField(SyncIdentity.systemName, text: $settings.deviceName)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
            .id("sync")
            switch client.status {
            case .connected(let host):
                hostLabel(host, detail: String(localized: "Synced"))
                Button("Stop Syncing", role: .destructive) { client.disconnect() }
            case .connecting(let host), .waitingApproval(let host):
                hostLabel(host, detail: String(localized: "Connecting…|verb"))
            case .idle, .failed:
                if case .failed(let message) = client.status {
                    Text(message).foregroundStyle(.orange)
                }
                if client.hosts.isEmpty {
                    Text("No Mac with Waiting Paws open on this network").foregroundStyle(.secondary)
                }
            }
            ForEach(client.hosts.filter { $0.id != client.host?.id }) { host in
                Button {
                    client.connect(to: host)
                } label: {
                    hostLabel(host.device, detail: HostText.detail(host, paired: client.isPaired(host.device)))
                }
                .tint(.primary)
                .disabled(model.session != nil || !host.isCompatible || client.isBusy)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("The camera, recording and log stay on the Mac, while the iPhone runs the training from behind the door. The iPhone reconnects by itself to the last Mac it worked with. The Mac sees the name above when the iPhone connects.")
        }
        if !client.pairedHosts.isEmpty {
            Section {
                ForEach(client.pairedHosts.sorted { $0.lastConnected > $1.lastConnected }) { paired in
                    LabeledContent {
                        Button("Forget", role: .destructive) { forgetHost = paired }
                            .buttonStyle(.borderless)
                    } label: {
                        hostLabel(paired.device, detail: pairedDetail(paired))
                    }
                }
            } header: {
                Text("Connected Before")
            } footer: {
                Text("After Forget, syncing with that computer needs Allow on it again.")
            }
        }
    }

    private func hostLabel(_ host: SyncDevice, detail: String) -> some View {
        Label {
            Text(host.name)
            if !detail.isEmpty { Text(detail) }
        } icon: {
            Image(systemName: host.symbolName)
        }
    }

    /// «Забыть «…»?»: the computer will have to allow this iPhone again; a sync with it running now stops.
    private func forgetMessage(_ host: SyncClient.PairedHost) -> String {
        let again = String(localized: "To sync again, you’ll need to allow it on the \(host.device.kindTitle).")
        let client = model.syncClient
        // `forget` also gives up a link being restored.
        let linked = (client.isConnected && client.host?.id == host.id) || client.reconnecting?.id == host.id
        return linked ? String(localized: "Syncing will stop.") + " " + again : again
    }

    private func pairedDetail(_ paired: SyncClient.PairedHost) -> String {
        var parts: [String] = []
        if let model = paired.device.distinctModel { parts.append(model) }
        if model.syncClient.host?.id == paired.id, model.syncClient.isConnected {
            parts.append(String(localized: "connected now"))
        } else if model.syncClient.isNearby(paired.id) {
            parts.append(String(localized: "nearby"))
        } else {
            parts.append(String(localized: "last connected \(paired.lastConnected.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }
    #endif

    private func check() async {
        guard let client = model.client else {
            checkStatus = String(localized: "Invalid address")
            return
        }
        checkStatus = "…"
        do {
            let version = try await client.version()
            checkStatus = version.isEmpty ? String(localized: "Server is responding") : "go2rtc \(version)"
        } catch {
            checkStatus = error.localizedDescription
        }
    }
}
