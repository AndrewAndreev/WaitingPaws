import SwiftUI
import WaitingPawsCore

/// «Какая камера смотрит на дверь?» (S5): Mi Home cameras and go2rtc streams as tiles with a still from each
/// (the same catalog and stills as the Mac picker), the chosen one ringed, «Смотреть «…»» at the bottom.
/// A camera go2rtc does not play yet gets its stream when it is chosen.
struct CameraPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Right after a sign-in: only this account's cameras, with «Вход выполнен» above them.
    var signedInAccount: String? = nil
    /// First launch only: nothing to pick, go on with the timer alone.
    var onContinueWithoutCamera: (() -> Void)? = nil
    /// Opened as its own sheet (Settings, the main screen): a ✕ in the corner.
    var showsClose = false
    /// The camera this picks: the app's one, or the second one to look at.
    var target: SetupCameraCatalog.Target = .main
    var onDone: (String) -> Void

    @State private var catalog = SetupCameraCatalog()
    @State private var selection: String?
    @State private var opening = false
    @State private var openError: String?
    @State private var addingStream = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            switch catalog.phase {
            case .idle, .loading, .waiting:
                ProgressView(catalog.phase == .waiting ? "Запускаем go2rtc…" : "Ищем камеры…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                unavailable(title: String(localized: "Нет связи с go2rtc"), symbol: "exclamationmark.triangle", text: message)
            case .ready:
                if groups.isEmpty {
                    unavailable(title: String(localized: "Камер не найдено"), symbol: "video.slash",
                                text: String(localized: "В аккаунте Mi Home нет камер, а в go2rtc нет потоков."))
                } else {
                    tiles
                }
            }
        }
        .background(NightBackground())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showsClose {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Закрыть")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Обновить")
                    .disabled(catalog.phase == .loading || catalog.refreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if catalog.phase == .ready, !groups.isEmpty {
                VStack(spacing: 8) {
                    if let openError {
                        Label(openError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                    WideGlassButton(title: openTitle, busy: opening) { open() }
                        .disabled(catalog.choice(for: selection) == nil || opening)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $addingStream) {
            AddStreamSheet(catalog: catalog) { stream in
                addingStream = false
                selection = SetupCameraCatalog.streamID(stream.name)
            }
            .environment(model)
        }
        // Not ready yet: «Запускаем go2rtc…»; the task runs again once go2rtc answers.
        .task(id: model.setupServerReadyOrDemo) { await reload() }
    }

    // MARK: Tiles

    private enum Item: Identifiable {
        case camera(SetupCameraCatalog.Camera)
        case stream(Go2RTCStream)
        case add

        var id: String {
            switch self {
            case .camera(let camera): return camera.id
            case .stream(let stream): return SetupCameraCatalog.streamID(stream.name)
            case .add: return "add"
            }
        }
    }

    private struct TileGroup: Identifiable {
        let id: String
        let title: String?
        var detail: String?
        var error: String?
        var items: [Item]
    }

    /// Accounts with their cameras, then the other streams; «Поток RTSP / ONVIF» closes the last group.
    private var groups: [TileGroup] {
        var result: [TileGroup] = catalog.accounts
            .filter { !$0.cameras.isEmpty || $0.error != nil }
            .map { account in
                TileGroup(id: account.id, title: "Mi Home · ID \(account.id)",
                      detail: pluralText(account.cameras.count, ru: ("камера", "камеры", "камер"), en: ("camera", "cameras")),
                      error: account.error, items: account.cameras.map { .camera($0) })
            }
        let streams = catalog.otherStreams
        if !streams.isEmpty {
            result.append(TileGroup(id: "streams", title: String(localized: "Потоки go2rtc"), items: streams.map { .stream($0) }))
        }
        guard !result.isEmpty else { return [] }
        result[result.count - 1].items.append(.add)
        return result
    }

    private var tiles: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let signedInAccount {
                    Label("Вход выполнен · Mi Home ID \(signedInAccount)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.56))
                }
                Text("Какая камера смотрит на дверь?")
                    .font(.system(size: 28, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, signedInAccount == nil ? 0 : 8)
                Text("Её картинка будет на экране тренировки. Другую камеру можно выбрать позже в настройках.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                let groups = groups
                ForEach(groups) { group in
                    if groups.count > 1, let title = group.title {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if let detail = group.detail {
                                Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 26)
                    }
                    if let error = group.error {
                        Label("Камеры не загрузились: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                            .padding(.top, 12)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(group.items) { item in tile(item) }
                    }
                    .padding(.top, groups.count > 1 ? 10 : 22)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        switch item {
        case .camera(let camera):
            CameraChoiceTile(title: camera.name, kind: camera.kind, source: camera.stillSource, isCamera: true,
                             selected: selection == item.id) { selection = item.id }
        case .stream(let stream):
            CameraChoiceTile(title: stream.name, kind: SetupText.sourceBadge(stream.sources.first) ?? "go2rtc",
                             source: .stream(stream.name), isCamera: false, selected: selection == item.id) {
                selection = item.id
            }
        case .add:
            AddStreamTile { addingStream = true }
        }
    }

    private func unavailable(title: String, symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.bold())
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                WideGlassButton(title: String(localized: "Обновить"), prominent: false) { Task { await reload(force: true) } }
                WideGlassButton(title: String(localized: "Добавить поток RTSP / ONVIF"), prominent: false) { addingStream = true }
                if let onContinueWithoutCamera {
                    WideGlassButton(title: String(localized: "Продолжить без камеры"), action: onContinueWithoutCamera)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    private var openTitle: String {
        switch catalog.choice(for: selection) {
        case .camera(let camera):
            return target == .second ? String(localized: "Второй камерой — «\(camera.name)»") : String(localized: "Смотреть камеру «\(camera.name)»")
        case .stream(let stream):
            return target == .second ? String(localized: "Второй камерой — «\(stream.name)»") : String(localized: "Смотреть камеру «\(stream.name)»")
        case nil: return target == .second ? String(localized: "Выберите вторую камеру") : String(localized: "Выберите камеру")
        }
    }

    // MARK: Actions

    private func reload(force: Bool = false) async {
        await catalog.load(model, account: signedInAccount)
        if catalog.choice(for: selection) == nil {
            selection = catalog.currentID(model, target: target) ?? firstID
        }
        guard force else { return }
        for stream in catalog.streams { SetupStillStore.shared.request(stream.name, model: model, force: true) }
        for camera in catalog.accounts.flatMap(\.cameras) where camera.streamName == nil {
            SetupStillStore.shared.request(camera.stillSource, model: model, force: true)
        }
    }

    /// The first camera that answers (a still came through), else the first one. Never the main camera for the second
    /// one: it can't be both («Эта камера уже основная»).
    private var firstID: String? {
        let main = target == .second ? catalog.currentID(model) : nil
        let cameras = catalog.accounts.flatMap(\.cameras).filter { $0.id != main }
        let online = cameras.first { camera in
            if case .loaded = SetupStillStore.shared.state(for: camera.stillSource, model: model) { return true }
            return false
        }
        if let camera = online ?? cameras.first(where: { $0.host != nil }) ?? cameras.first { return camera.id }
        return catalog.otherStreams.map { SetupCameraCatalog.streamID($0.name) }.first { $0 != main }
    }

    /// Registers the chosen camera's stream when needed and makes it the app's camera.
    private func open() {
        guard let choice = catalog.choice(for: selection), !opening else { return }
        opening = true
        openError = nil
        Task {
            defer { opening = false }
            do {
                try await catalog.choose(choice, model: model, target: target)
                onDone(target == .main ? model.settings.streamName : model.settings.secondStreamName)
            } catch {
                openError = String(localized: "Не удалось добавить камеру: \(error.localizedDescription)")
            }
        }
    }
}

/// A camera or stream: its still (16:9), name with a dot (answers / not in network), resolution and kind.
private struct CameraChoiceTile: View {
    @Environment(AppModel.self) private var model
    let title: String
    let kind: String
    let source: SetupStillSource
    let isCamera: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let still = SetupStillStore.shared.state(for: source, model: model)
        let offline = still == .failed
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TileStill(source: source, symbol: isCamera ? "video.fill" : "antenna.radiowaves.left.and.right")
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, Theme.accent)
                                .padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        switch still {
                        case .loaded: Circle().fill(Color(red: 0.36, green: 0.85, blue: 0.56)).frame(width: 6, height: 6)
                        case .failed: Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        case .loading: ProgressView().controlSize(.mini)
                        case nil: EmptyView()
                        }
                    }
                    Text(detail(still))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(.white.opacity(selected ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
            }
            .opacity(offline && !selected ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(_ still: SetupStillStore.State?) -> String {
        if case .failed = still, isCamera { return String(localized: "Не в сети") }
        // The tile is narrow: the resolution says more than «Камера Xiaomi» once a picture came through.
        if case .loaded(_, let size) = still { return SetupText.pixels(size) }
        return kind
    }
}

/// A still that fills the tile's width (the Mac `SetupStill` has a fixed width).
private struct TileStill: View {
    @Environment(AppModel.self) private var model
    let source: SetupStillSource
    let symbol: String

    var body: some View {
        let state = SetupStillStore.shared.state(for: source, model: model)
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: state == .failed ? "video.slash.fill" : symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .overlay {
                if case .loaded(let image, _) = state {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .saturation(state == .failed ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: state)
            .task(id: "\(source.id)|\(model.setupServerReady)") {
                SetupStillStore.shared.request(source, model: model)
            }
    }
}

private struct AddStreamTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .glassPanel(in: Circle())
                Text("Поток RTSP / ONVIF")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 150)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// «Поток RTSP / ONVIF»: any go2rtc source by its address (a camera that is not in Mi Home, a recorder).
private struct AddStreamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let catalog: SetupCameraCatalog
    var onAdded: (Go2RTCStream) -> Void

    @State private var name = ""
    @State private var source = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Theme.info.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        Text("Поток RTSP / ONVIF")
                            .font(.system(size: 24, weight: .bold))
                        Text("Адрес из настроек камеры или видеорегистратора.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    SignInFieldRow(label: String(localized: "Название")) {
                        TextField("Название", text: $name, prompt: Text("Прихожая"))
                    }
                    SignInFieldRow(label: String(localized: "Адрес")) {
                        TextField("Адрес", text: $source, prompt: Text(verbatim: "rtsp://192.168.1.20:554/live"))
                            .plainInput()
                            #if os(iOS)
                            .keyboardType(.URL)
                            #endif
                    }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    } else {
                        Text("Подходят rtsp://, onvif:// и http://. Камера должна быть в той же сети Wi‑Fi.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Отменить")
                }
            }
            .safeAreaInset(edge: .bottom) {
                WideGlassButton(title: String(localized: "Добавить"), busy: busy) { Task { await add() } }
                    .disabled(!isValid || busy)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
        }
        .presentationDetents([.large])
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && source.contains("://")
    }

    private func add() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            onAdded(try await catalog.addStream(name: Go2RTCClient.streamName(for: name), source: source, model: model))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
