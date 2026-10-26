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
        .task(id: model.setupServerReady) { await reload() }
        .sheet(isPresented: $signingIn) {
            SetupXiaomiSignInSheet { account in
                allAccounts = true
                Task { await reload(selecting: account) }
            }
            .environment(model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(onlyStreams ? "Выберите поток go2rtc" : target == .second ? "Выберите вторую камеру" : "Выберите камеру")
                    .font(.title2.weight(.semibold))
                Text(onlyStreams
                     ? "RTSP, ONVIF и другие источники, которые уже есть в go2rtc."
                     : target == .second
                     ? "Например, в комнате, куда уходит собака. Переключатель выбирает, какую камеру смотреть и записывать."
                     : "Нужна та, что смотрит на входную дверь. Видео идёт по локальной сети через go2rtc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button {
                Task { await reload(force: true) }
            } label: {
                if catalog.refreshing || catalog.phase == .loading {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Label("Обновить", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
            }
            .help("Обновить список камер")
            .disabled(!model.setupServerReadyOrDemo || catalog.refreshing || catalog.phase == .loading)
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
            ProgressView("Ищем камеры…")
        case .waiting:
            ContentUnavailableView {
                Label("go2rtc не запущен", systemImage: "video.slash")
            } description: {
                Text("Список камер появится, когда go2rtc заработает.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Нет связи с go2rtc", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Повторить") { Task { await reload() } }
            }
        case .ready:
            if onlyStreams && catalog.otherStreams.isEmpty {
                ContentUnavailableView {
                    Label("В go2rtc нет потоков", systemImage: "video.slash")
                } description: {
                    Text("Добавьте источник по адресу: rtsp://, onvif:// или http://.")
                } actions: {
                    addStreamButton
                }
            } else {
                grid
            }
        }
    }

    private var visibleAccounts: [SetupCameraCatalog.Account] {
        onlyStreams ? [] : catalog.accounts
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !onlyStreams && catalog.accounts.isEmpty {
                    SetupMiHomeSignInCard(style: .card) { signingIn = true }
                        .disabled(!model.setupServerReadyOrDemo)
                }
                ForEach(visibleAccounts) { account in
                    section(title: "Mi Home", detail: "ID \(account.id) · \(SetupText.regionTitle(account.region))",
                            accessory: account.id == visibleAccounts.first?.id ? .signIn : nil) {
                        if let error = account.error {
                            Label("Камеры не загрузились: \(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(MacPalette.orange)
                        } else if account.cameras.isEmpty {
                            Text("В этом аккаунте нет камер.")
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
                section(title: visibleAccounts.isEmpty ? String(localized: "Потоки go2rtc") : String(localized: "Другие потоки go2rtc"),
                        detail: nil, accessory: .addStream) {
                    if catalog.otherStreams.isEmpty {
                        Text("Здесь появятся RTSP, ONVIF и другие источники go2rtc.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(catalog.otherStreams) { stream in
                                tile(.stream(stream))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private enum SectionAccessory { case signIn, addStream }

    private func section<Content: View>(title: String, detail: String?, accessory: SectionAccessory? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                switch accessory {
                case .signIn:
                    Button("Войти в другой аккаунт…", systemImage: "person.badge.key") { signingIn = true }
                        .buttonStyle(.borderless)
                        .help("Добавить камеры ещё одного аккаунта Xiaomi")
                        .disabled(!model.setupServerReadyOrDemo)
                case .addStream:
                    addStreamButton.buttonStyle(.borderless)
                case nil:
                    EmptyView()
                }
            }
            content()
        }
    }

    private var addStreamButton: some View {
        Button("Добавить поток…", systemImage: "plus") { addingStream = true }
            .help("Добавить источник по адресу: rtsp://, onvif://, http://")
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

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacPalette.red)
                    .lineLimit(2)
                    .help(error)
            } else if choosing {
                ProgressView().controlSize(.small)
                Text("Добавляем камеру в go2rtc…").foregroundStyle(.secondary)
            } else {
                SetupServerStatusLabel(probe: catalog)
            }
            Spacer()
            Button("Отменить") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Выбрать", action: choose)
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
        if let account, let camera = catalog.accounts.first(where: { $0.id == account })?.cameras.first {
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
        let cameras = visibleAccounts.flatMap(\.cameras)
        if let camera = cameras.first(where: { $0.streamName != nil }) ?? cameras.first { return camera.id }
        return catalog.otherStreams.first.map { SetupCameraCatalog.streamID($0.name) }
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
                self.error = String(localized: "Не удалось добавить камеру: \(error.localizedDescription)")
            }
        }
    }
}

/// Home-style tile: still with a status chip, selection ring and check, name and one line of detail.
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
                .overlay(alignment: .bottomLeading) { chip.padding(7) }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(6)
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                            .padding(-4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(isCamera ? .system(size: 11) : .system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(isCamera ? .tail : .middle)
                    .help(tooltip)
            }
            .padding(.horizontal, 2)
        }
        .opacity(still == .failed ? 0.75 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var isCamera: Bool {
        if case .camera = choice { return true }
        return false
    }

    private var title: String {
        switch choice {
        case .camera(let camera): return camera.name
        case .stream(let stream): return stream.name
        }
    }

    /// "2304×1296 · Камера Xiaomi" (the raw model id only in the tooltip) or the stream's source.
    private var subtitle: String {
        switch choice {
        case .camera(let camera):
            if case .loaded(_, let size) = still { return "\(SetupText.pixels(size)) · \(camera.kind)" }
            return camera.kind
        case .stream(let stream):
            return stream.sources.first.map(SettingsText.redacted) ?? String(localized: "Источник не указан")
        }
    }

    private var tooltip: String {
        switch choice {
        case .camera(let camera): return camera.technicalDetails.isEmpty ? camera.kind : camera.technicalDetails
        case .stream: return subtitle
        }
    }

    @ViewBuilder
    private var chip: some View {
        switch choice {
        case .camera:
            chipBody {
                switch still {
                case .loaded:
                    StatusDot(color: MacPalette.green, size: 6)
                    Text("В сети")
                case .failed:
                    StatusDot(color: .white.opacity(0.5), size: 6)
                    Text("Не в сети")
                case .loading, nil:
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Подключение…")
                }
            }
        case .stream(let stream):
            let badge = SetupText.sourceBadge(stream.sources.first)
            chipBody {
                switch still {
                case .loaded:
                    StatusDot(color: MacPalette.green, size: 6)
                    Text(badge ?? String(localized: "В сети"))
                case .failed:
                    StatusDot(color: .white.opacity(0.5), size: 6)
                    Text(badge.map { String(localized: "\($0) · нет связи") } ?? String(localized: "Нет связи"))
                case .loading, nil:
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(badge ?? String(localized: "Подключение…"))
                }
            }
        }
    }

    private func chipBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

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
                Text("Камеры Mi Home")
                    .font(.system(size: 13, weight: .semibold))
                Text(style == .listRow ? "Нужен вход в аккаунт Xiaomi" : "Войдите в аккаунт Xiaomi — здесь появятся камеры из Mi Home.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Войти в Xiaomi…", action: signIn)
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
            Text("Новый поток go2rtc").font(.headline)
            Form {
                TextField("Название", text: $name, prompt: Text("testcam"))
                    .plainInput()
                TextField("Адрес", text: $source, prompt: Text("rtsp://192.168.1.20:554/live"))
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
                Button("Добавить") { Task { await add() } }
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
