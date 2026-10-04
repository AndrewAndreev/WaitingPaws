#if os(macOS)
import SwiftUI
import WaitingPawsCore

private let pickerTileWidth: CGFloat = 200

/// Выбор камеры (D3): Mi Home cameras and other go2rtc streams as Home-style tiles. Choosing one registers
/// its stream in go2rtc when needed, saves it as the app's camera and closes the sheet.
struct MacCameraPickerSheet: View {
    /// Only go2rtc streams (welcome window «Выбрать поток go2rtc…»).
    var onlyStreams = false
    /// Only this Mi Home account (right after signing in to it).
    var accountID: String? = nil
    var onChosen: () -> Void = {}

    init(onlyStreams: Bool = false, accountID: String? = nil, onChosen: @escaping () -> Void = {}) {
        self.onlyStreams = onlyStreams
        self.accountID = accountID
        self.onChosen = onChosen
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = SetupCameraCatalog()
    @State private var selection: String?
    @State private var choosing = false
    @State private var error: String?
    @State private var addingStream = false

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
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(onlyStreams ? "Выберите поток go2rtc" : "Выберите камеру")
                    .font(.title2.weight(.semibold))
                Text(onlyStreams
                     ? "RTSP, ONVIF и другие источники, которые уже есть в go2rtc."
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
            if visibleAccounts.isEmpty && catalog.otherStreams.isEmpty {
                ContentUnavailableView {
                    Label(onlyStreams ? "В go2rtc нет потоков" : "Камер не найдено", systemImage: "video.slash")
                } description: {
                    Text(onlyStreams
                         ? "Добавьте источник по адресу: rtsp://, onvif:// или http://."
                         : "В аккаунте Mi Home нет камер, а в go2rtc нет потоков.")
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
                ForEach(visibleAccounts) { account in
                    section(title: "Mi Home", detail: "ID \(account.id) · \(SetupText.regionTitle(account.region))") {
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
                section(title: visibleAccounts.isEmpty ? "Потоки go2rtc" : "Другие потоки go2rtc", detail: nil, showsAdd: true) {
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

    private func section<Content: View>(title: String, detail: String?, showsAdd: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if showsAdd { addStreamButton.buttonStyle(.borderless) }
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

    private func reload(force: Bool = false) async {
        await catalog.load(model, account: onlyStreams ? nil : accountID)
        if selection == nil || catalog.choice(for: selection) == nil {
            selection = catalog.currentID(model) ?? firstID
        }
        guard force else { return }
        for stream in catalog.streams { SetupStillStore.shared.request(stream.name, model: model, force: true) }
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
                try await catalog.choose(choice, model: model)
                onChosen()
                dismiss()
            } catch {
                self.error = "Не удалось добавить камеру: \(error.localizedDescription)"
            }
        }
    }
}

/// Home-style tile: still with a status chip, selection ring and check, name and one line of detail.
private struct SetupPickerTile: View {
    @Environment(AppModel.self) private var model
    let choice: SetupCameraCatalog.Choice
    let selected: Bool

    private var streamName: String? {
        switch choice {
        case .camera(let camera): return camera.streamName
        case .stream(let stream): return stream.name
        }
    }

    private var still: SetupStillStore.State? {
        streamName.flatMap { SetupStillStore.shared.state(for: $0, model: model) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SetupStill(stream: streamName, width: pickerTileWidth, cornerRadius: 10,
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
                    .help(subtitle)
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

    private var subtitle: String {
        switch choice {
        case .camera(let camera):
            let model = camera.model ?? "Камера Mi Home"
            if case .loaded(_, let size) = still { return "\(SetupText.pixels(size)) · \(model)" }
            return model
        case .stream(let stream):
            return stream.sources.first ?? "Источник не указан"
        }
    }

    @ViewBuilder
    private var chip: some View {
        let badge: String? = {
            if case .stream(let stream) = choice { return SetupText.sourceBadge(stream.sources.first) }
            return nil
        }()
        if streamName == nil {
            // A Mi Home camera that go2rtc does not play yet: no picture until it is chosen.
            chipBody { Text("Mi Home") }
        } else {
            chipBody {
                switch still {
                case .loaded:
                    StatusDot(color: MacPalette.green, size: 6)
                    Text(badge ?? "В сети")
                case .failed:
                    StatusDot(color: .white.opacity(0.5), size: 6)
                    Text(badge.map { "\($0) · нет связи" } ?? "Нет связи")
                case .loading, nil:
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(badge ?? "Подключение…")
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
