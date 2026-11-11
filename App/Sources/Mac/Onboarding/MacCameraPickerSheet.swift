#if os(macOS)
import SwiftUI
import WaitingPawsCore

private let pickerTileWidth: CGFloat = 200

/// Выбор камеры (D3): Mi Home cameras and other go2rtc streams as Home-style tiles. Choosing one registers
/// its stream in go2rtc when needed, saves it as the app's camera and closes the sheet. Mi Home cameras that
/// are not streams yet get a preview on demand (`SetupStillStore`). Without a Xiaomi account on go2rtc the
/// Mi Home part is a card with «Войти в Xiaomi…»: after the sign-in its cameras appear right here, so the sheet
/// also switches the training window from a stream to a Mi Home camera.
struct MacCameraPickerSheet: View {
    /// Only go2rtc streams (welcome window «Выбрать поток go2rtc…»).
    var onlyStreams = false
    /// Only this Mi Home account (right after signing in to it).
    var accountID: String? = nil
    /// The camera this picks: the app's one, or the second one to look at.
    var target: SetupCameraCatalog.Target = .main
    var onChosen: () -> Void = {}

    init(onlyStreams: Bool = false, accountID: String? = nil, target: SetupCameraCatalog.Target = .main,
         onChosen: @escaping () -> Void = {}) {
        self.onlyStreams = onlyStreams
        self.accountID = accountID
        self.target = target
        self.onChosen = onChosen
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = SetupCameraCatalog()
    @State private var selection: String?
    @State private var choosing = false
    @State private var error: String?
    @State private var addingStream = false
    @State private var signingIn = false
    /// After a sign-in here every account is listed, not only `accountID`.
    @State private var allAccounts = false

    private let columns = Array(repeating: GridItem(.fixed(pickerTileWidth), spacing: 16, alignment: .top), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 680, height: onlyStreams ? 380 : 548)
        // Fresh stills on every opening, as the iPhone's (design council, round 14: no ↻).
        .task(id: model.setupServerReady) { await reload(force: true) }
        #if !WP_NO_XIAOMI
        .sheet(isPresented: $signingIn) {
            SetupXiaomiSignInSheet { account in
                allAccounts = true
                Task { await reload(selecting: account) }
            }
            .environment(model)
        }
        #endif
    }

    // MARK: Header

    /// The title alone, as the iPhone's (design council, round 12: the pictures say which camera looks at the door);
    /// the stills refresh by themselves on opening (round 14: no ↻).
    private var header: some View {
        HStack(alignment: .center) {
            Text(onlyStreams ? "go2rtc Streams" : target == .second ? "Second Camera" : "Camera")
                .font(.title2.weight(.semibold))
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch catalog.phase {
        case .idle, .loading:
            ProgressView("Looking for cameras…")
        case .waiting:
            ContentUnavailableView {
                Label("go2rtc is not running", systemImage: "video.slash")
            } description: {
                Text("The camera list will appear once go2rtc is running.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No Connection to go2rtc", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again|short") { Task { await reload() } }
            }
        case .ready:
            grid
        }
    }

    private var visibleAccounts: [SetupCameraCatalog.Account] {
        onlyStreams ? [] : catalog.accounts
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if !WP_NO_XIAOMI
                if !onlyStreams && catalog.accounts.isEmpty {
                    SetupMiHomeSignInCard(style: .card) { signingIn = true }
                        .disabled(!model.setupServerReadyOrDemo)
                }
                #endif
                ForEach(visibleAccounts) { account in
                    // The account's id and region only tell two accounts apart (Settings shows them).
                    section(title: "Mi Home",
                            detail: visibleAccounts.count > 1 ? "ID \(account.id) · \(SetupText.regionTitle(account.region))" : nil,
                            accessory: account.id == visibleAccounts.first?.id ? .signIn : nil) {
                        if let error = account.error {
                            Label("Couldn’t load cameras: \(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(MacPalette.orange)
                        } else if account.cameras.isEmpty {
                            Text("This account has no cameras.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(account.cameras) { camera in
                                    tile(.camera(camera))
                                }
                            }
                        }
                    }
                }
                // The cameras added by address, and «Своя камера» as one more tile (design council, round 14: one
                // sign, no row of words). The welcome window's «Выбрать поток go2rtc…» has the title say «Потоки
                // go2rtc» already: no header there.
                section(title: othersTitle, detail: nil) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(catalog.otherStreams) { stream in
                            tile(.stream(stream))
                        }
                        addStreamTile
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// «Другие камеры» under the Mi Home ones; none in a build without Xiaomi, where these are all there is.
    private var othersTitle: String? {
        #if WP_NO_XIAOMI
        return nil
        #else
        return onlyStreams ? nil : String(localized: "Other Cameras")
        #endif
    }

    private enum SectionAccessory { case signIn }

    private func section<Content: View>(title: String?, detail: String?, accessory: SectionAccessory? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    #if !WP_NO_XIAOMI
                    if accessory == .signIn {
                        Button("Sign In to Another Account…", systemImage: "person.badge.key") { signingIn = true }
                            .buttonStyle(.borderless)
                            .help("Add cameras from another Xiaomi account")
                            .disabled(!model.setupServerReadyOrDemo)
                    }
                    #endif
                }
            }
            content()
        }
    }

    /// «Своя камера»: a tile like the cameras', the «+» where their picture is; the address in a popover over it.
    private var addStreamTile: some View {
        Button { addingStream = true } label: {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top,
                                         endPoint: .bottom))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .frame(width: pickerTileWidth, height: pickerTileWidth * 9 / 16)
                Text("Custom camera")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a camera by an rtsp:// or http:// address (an ONVIF camera by its rtsp:// address)")
        .accessibilityLabel(String(localized: "Add a custom camera"))
        .disabled(!model.setupServerReadyOrDemo)
        .popover(isPresented: $addingStream, arrowEdge: .bottom) {
            SetupAddStreamForm(catalog: catalog) { stream in
                addingStream = false
                selection = SetupCameraCatalog.streamID(stream.name)
            }
        }
    }

    private func tile(_ choice: SetupCameraCatalog.Choice) -> some View {
        SetupPickerTile(choice: choice, selected: selection == choice.id)
            .onTapGesture(count: 2) {
                selection = choice.id
                choose()
            }
            .onTapGesture { selection = choice.id }
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selection == choice.id ? .isSelected : [])
    }

    // MARK: Footer

    /// The video server answers: nothing to say about it here.
    private var serverIsFine: Bool {
        switch SetupServerState.of(model, probe: catalog) {
        case .running: return true
        case .external(_, let version): return version != nil
        default: return false
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacPalette.red)
                    .lineLimit(2)
                    .help(error)
            } else if choosing {
                ProgressView().controlSize(.small)
                Text("Adding the camera…").foregroundStyle(.secondary)
            } else if !serverIsFine {
                // Only when the video server needs a hand («Запустить», «Попробовать снова»); its version is in Settings.
                SetupServerStatusLabel(probe: catalog)
            }
            Spacer()
            Button("Cancel|verb") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Choose", action: choose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(catalog.choice(for: selection) == nil || choosing)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(alignment: .top) { Divider() }
    }

    // MARK: Actions

    /// `selecting`: an account just signed in to — its first camera gets selected.
    private func reload(force: Bool = false, selecting account: String? = nil) async {
        await catalog.load(model, account: onlyStreams || allAccounts ? nil : accountID)
        if let account, let camera = catalog.accounts.first(where: { $0.id == account })?.cameras.first(where: { $0.id != mainID }) {
            selection = camera.id
        } else if selection == nil || catalog.choice(for: selection) == nil {
            selection = catalog.currentID(model, target: target) ?? firstID
        }
        guard force else { return }
        for stream in catalog.streams { SetupStillStore.shared.request(stream.name, model: model, force: true) }
        for camera in visibleAccounts.flatMap(\.cameras) where camera.streamName == nil {
            SetupStillStore.shared.request(camera.stillSource, model: model, force: true)
        }
    }

    /// The first camera go2rtc already plays (or the first stream): a sensible default to confirm with Return.
    private var firstID: String? {
        let cameras = visibleAccounts.flatMap(\.cameras).filter { $0.id != mainID }
        if let camera = cameras.first(where: { $0.streamName != nil }) ?? cameras.first { return camera.id }
        return catalog.otherStreams.map { SetupCameraCatalog.streamID($0.name) }.first { $0 != mainID }
    }

    /// Picking the second camera: the main one, never offered as the default (Return gave «Эта камера уже основная»).
    private var mainID: String? {
        target == .second ? catalog.currentID(model) : nil
    }

    private func choose() {
        guard let choice = catalog.choice(for: selection), !choosing else { return }
        choosing = true
        error = nil
        Task {
            defer { choosing = false }
            do {
                try await catalog.choose(choice, model: model, target: target)
                onChosen()
                dismiss()
            } catch {
                self.error = String(localized: "Couldn’t add the camera: \(error.localizedDescription)")
            }
        }
    }
}

/// Home-style tile: still (a spinner on it while the picture comes; the crossed-out camera, grey and dimmed, when none
/// does — «Не в сети» for VoiceOver and in the tooltip), the selection ring, and the name.
/// What a person does not pick by — the resolution, the Mi Home model and address, a stream's source — is in the
/// tooltip.
private struct SetupPickerTile: View {
    @Environment(AppModel.self) private var model
    let choice: SetupCameraCatalog.Choice
    let selected: Bool

    private var stillSource: SetupStillSource {
        switch choice {
        case .camera(let camera): return camera.stillSource
        case .stream(let stream): return .stream(stream.name)
        }
    }

    private var still: SetupStillStore.State? {
        SetupStillStore.shared.state(for: stillSource, model: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SetupStill(source: stillSource, width: pickerTileWidth, cornerRadius: 10,
                       symbol: isCamera ? "video.fill" : "antenna.radiowaves.left.and.right")
                .saturation(still == .failed ? 0 : 1)
                // The ring is the one mark of the camera in use (design council, round 14: no ✓ beside it).
                .overlay(alignment: .bottomLeading) {
                    // A picture is its own «в сети», the crossed-out camera its «не в сети» (design council, round 13).
                    if still == .loading || still == nil { spinner.padding(7) }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                            .padding(-4)
                    }
                }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .opacity(still == .failed && !selected ? 0.6 : 1)
        .contentShape(Rectangle())
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityValue(offlineText ?? "")
    }

    private var isCamera: Bool {
        if case .camera = choice { return true }
        return false
    }

    /// «Не в сети» (a stream: «Нет связи») when no picture comes: for VoiceOver and the tooltip, not on the tile.
    private var offlineText: String? {
        guard still == .failed else { return nil }
        return isCamera ? String(localized: "Offline") : String(localized: "No connection")
    }

    private var title: String {
        switch choice {
        case .camera(let camera): return camera.name
        case .stream(let stream): return stream.name
        }
    }

    /// "2304×1296 · Модель Mi Home: chuangmi.camera.069a01 · IP 192.168.1.34", or the stream's source.
    private var tooltip: String {
        var pixels: String?
        if case .loaded(_, let size) = still { pixels = SetupText.pixels(size) }
        let details: String
        switch choice {
        case .camera(let camera):
            details = camera.technicalDetails.isEmpty ? camera.kind : camera.technicalDetails
        case .stream(let stream):
            details = stream.sources.first.map(SettingsText.redacted) ?? String(localized: "No source specified")
        }
        return [offlineText, pixels, details].compactMap { $0 }.joined(separator: " · ")
    }

    /// The picture is on its way.
    private var spinner: some View {
        ProgressView().controlSize(.mini).tint(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

#if !WP_NO_XIAOMI // a build without Xiaomi has no sign-in (`NoXiaomiText`)
/// «Камеры Mi Home» when go2rtc has no Xiaomi account: one sentence and a prominent «Войти в Xiaomi…».
struct SetupMiHomeSignInCard: View {
    enum Style {
        /// A card of its own (camera picker).
        case card
        /// A row of a grouped form (Settings).
        case formRow
        /// A list row whose icon lines up with the stills of the rows below (welcome window).
        case listRow
    }

    var style: Style = .card
    var signIn: () -> Void

    var body: some View {
        HStack(spacing: style == .card ? 14 : 10) {
            SetupIconTile(symbol: "video.fill", color: MacPalette.pinkDeep, size: style == .listRow ? 30 : (style == .card ? 40 : 34))
                .frame(width: style == .listRow ? 64 : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mi Home Cameras")
                    .font(.system(size: 13, weight: .semibold))
                Text(style == .listRow ? "Xiaomi sign-in required" : "Sign in to your Xiaomi account — your Mi Home cameras will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Sign In to Xiaomi…", action: signIn)
                .buttonStyle(.borderedProminent)
                .controlSize(style == .listRow ? .small : .regular)
        }
        .padding(style == .card ? 14 : 3)
        .background {
            if style == .card {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            }
        }
    }
}
#endif

/// «Добавить поток…»: any go2rtc source by its address.
struct SetupAddStreamForm: View {
    @Environment(AppModel.self) private var model
    let catalog: SetupCameraCatalog
    var onAdded: (Go2RTCStream) -> Void

    @State private var name = ""
    @State private var source = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New go2rtc Stream").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("testcam"))
                    .plainInput()
                TextField("Address", text: $source, prompt: Text("rtsp://192.168.1.20:554/live"))
                    .plainInput()
            }
            .formStyle(.columns)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(MacPalette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Add") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || busy)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && source.contains("://")
    }

    private func add() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            onAdded(try await catalog.addStream(name: name, source: source, model: model))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
