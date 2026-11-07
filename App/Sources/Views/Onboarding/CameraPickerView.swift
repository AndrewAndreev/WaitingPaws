import SwiftUI
import WaitingPawsCore

/// «Камера» (S5): Mi Home cameras and go2rtc streams as tiles with a still from each (the same catalog and stills as
/// the Mac picker), the current one ringed — the ring its one mark. A tap on a tile picks that camera and closes the
/// list (design council, round 12: the pictures say which camera looks at the door; no question, no explanation, no
/// confirm button). The stills are fetched again on every opening and by pulling the list down: no ↻ (round 14). On the
/// app's dark panel, as its other sheets (round 6: not the setup screens' night gradient). A camera go2rtc does not
/// play yet gets its stream when it is chosen. Only what a person picks by: the name, the picture (its age once it is
/// old), the crossed-out camera of one that doesn't answer, the ring of the one in use; the account id, resolution and
/// the word go2rtc stay in Settings.
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
    /// The camera ringed: the current one, then the one tapped.
    @State private var selection: String?
    /// The tapped camera is being set up (its stream added to go2rtc): a spinner on its tile.
    @State private var opening = false
    @State private var openError: String?
    @State private var addingStream = false
    /// The tiles are scrolled off their top: the top bar gets its backing.
    @State private var scrolledOffTop = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            switch catalog.phase {
            case .idle, .loading, .waiting:
                ProgressView("Ищем камеры…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                unavailable(title: String(localized: "Камеры не загрузились"), symbol: "exclamationmark.triangle", text: message)
            case .ready:
                if groups.isEmpty {
                    #if WP_NO_XIAOMI // a build without Xiaomi (`NoXiaomiText`)
                    unavailable(title: String(localized: "Камер не найдено"), symbol: "video.slash", text: NoXiaomiText.addCamera)
                    #else
                    unavailable(title: String(localized: "Камер не найдено"), symbol: "video.slash",
                                text: String(localized: "В аккаунте Mi Home нет камер, а других камер не добавлено."))
                    #endif
                } else {
                    tiles
                }
            }
        }
        .background(Theme.panel.ignoresSafeArea())
        // The top edge, as the bottom one under the button: scrolled, the title and the tiles go under ✕ and ↻.
        .overlay {
            if scrolledOffTop, catalog.phase == .ready { TopBarBacking().transition(.opacity) }
        }
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
        }
        // A camera that couldn't be added says so in a bar of its own under the tiles, which scroll under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if catalog.phase == .ready, !groups.isEmpty, let openError {
                Label(openError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.top, BottomBarBacking.fade)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background { BottomBarBacking().ignoresSafeArea(edges: .bottom) }
            }
        }
        .sheet(isPresented: $addingStream) {
            // The camera just added is the one wanted: picked at once, as a tap on its tile would.
            AddStreamSheet(catalog: catalog) { stream in
                addingStream = false
                open(SetupCameraCatalog.streamID(stream.name))
            }
            .environment(model)
        }
        // Not ready yet: «Ищем камеры…»; the task runs again once go2rtc answers. Fresh stills on every opening (a
        // preview that came through stays for the session; a failed one is tried again).
        .task(id: model.setupServerReadyOrDemo) { await reload(force: true) }
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

    /// Accounts with their cameras, then the owner's own: the streams added here and «+ Своя камера» (design council,
    /// round 6: one tile, not a group «Другие камеры» with technical tiles). With one account they all share its grid,
    /// without headers; with several, the own ones follow the accounts' groups without a header of their own. The
    /// account's id only tells two accounts apart.
    private var groups: [TileGroup] {
        let accounts = catalog.accounts.filter { !$0.cameras.isEmpty || $0.error != nil }
        let streams = catalog.otherStreams
        guard !accounts.isEmpty || !streams.isEmpty else { return [] }
        var result: [TileGroup] = accounts.map { account in
            TileGroup(id: account.id,
                      title: accounts.count > 1 ? "Mi Home · ID \(account.id)" : "Mi Home",
                      detail: pluralText(account.cameras.count, ru: ("камера", "камеры", "камер"), en: ("camera", "cameras")),
                      error: account.error, items: account.cameras.map { .camera($0) })
        }
        let own: [Item] = streams.map { .stream($0) } + [.add]
        if result.count == 1 {
            result[0].items += own
        } else {
            result.append(TileGroup(id: "own", title: nil, items: own))
        }
        return result
    }

    private var tiles: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if signedInAccount != nil {
                        Label("Вход в Mi Home выполнен", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.56))
                    }
                    Text(target == .second ? "Вторая камера" : "Камера")
                        .font(.system(size: 28, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, signedInAccount == nil ? 0 : 8)

                    let groups = groups
                    ForEach(groups) { group in
                        let header = groups.count > 1 ? group.title : nil
                        if let header {
                            HStack(alignment: .firstTextBaseline) {
                                Text(header).font(.system(size: 15, weight: .semibold))
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
                        // A group without a header carries on the grid above it.
                        .padding(.top, header != nil ? 10 : group.id == groups.first?.id ? 22 : 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) { Color.clear.frame(height: 1).id(Self.endID) }
            }
            // Pulled down, the list fetches its stills again (it bounces even when it fits, or it couldn't be pulled).
            .refreshable { await reload(force: true) }
            .modifier(ScrolledOffTop(scrolled: $scrolledOffTop))
            #if DEBUG
            // `--demo-scroll-bottom`: the end of the list (screenshots). Scrolled there once the tiles are in, as a finger
            // would: the top bar's backing follows the scroll.
            .task {
                guard CommandLine.arguments.contains("--demo-scroll-bottom") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            #endif
        }
    }

    private static let endID = "picker-end"

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        switch item {
        case .camera(let camera):
            CameraChoiceTile(title: camera.name, source: camera.stillSource, isCamera: true,
                             selected: selection == item.id, busy: opening && selection == item.id) { open(item.id) }
                .disabled(opening)
        case .stream(let stream):
            CameraChoiceTile(title: stream.name, source: .stream(stream.name), isCamera: false,
                             selected: selection == item.id, busy: opening && selection == item.id) { open(item.id) }
                .disabled(opening)
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
                WideGlassButton(title: String(localized: "Добавить поток RTSP"), prominent: false) { addingStream = true }
                if let onContinueWithoutCamera {
                    WideGlassButton(title: String(localized: "Продолжить без камеры"), action: onContinueWithoutCamera)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    // MARK: Actions

    private func reload(force: Bool = false) async {
        await catalog.load(model, account: signedInAccount)
        // Only the camera in use is ringed: without a confirm button a suggested one would read as chosen.
        if catalog.choice(for: selection) == nil {
            selection = catalog.currentID(model, target: target)
        }
        guard force else { return }
        for stream in catalog.streams { SetupStillStore.shared.request(stream.name, model: model, force: true) }
        for camera in catalog.accounts.flatMap(\.cameras) where camera.streamName == nil {
            SetupStillStore.shared.request(camera.stillSource, model: model, force: true)
        }
    }

    /// The tapped camera: ringed, its stream registered when needed, made the app's camera (or the second one), and the
    /// list closes (`onDone`). If it can't be added, the ring goes back to the camera in use and the reason shows under
    /// the tiles.
    private func open(_ id: String) {
        guard !opening, let choice = catalog.choice(for: id) else { return }
        selection = id
        opening = true
        openError = nil
        Task {
            defer { opening = false }
            do {
                try await catalog.choose(choice, model: model, target: target)
                onDone(target == .main ? model.settings.streamName : model.settings.secondStreamName)
            } catch {
                selection = catalog.currentID(model, target: target)
                openError = String(localized: "Не удалось добавить камеру: \(error.localizedDescription)")
            }
        }
    }
}

/// Under a bottom bar a list scrolls beneath, as under a system bar: what scrolls under it blurs and fades into `color`
/// over `fade` points, then stays `color` down to the screen's edge. The picker's button and the plan's start
/// (`PlanEditorView`), both into the app's panel.
struct BottomBarBacking: View {
    static let fade: CGFloat = 28
    /// The screen's own background under the bar.
    var color = Theme.panel
    /// How much of `color` under the bar itself.
    var opacity: Double = 1
    var fade: CGFloat = Self.fade

    var body: some View {
        GeometryReader { geometry in
            let edge = min(1, fade / max(1, geometry.size.height))
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: edge * 0.4),
                                                 .init(color: .black, location: edge)],
                                         startPoint: .top, endPoint: .bottom))
                // Darkens ahead of the blur, so the blurred tiles never show as a lighter band at its top.
                LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                       .init(color: color.opacity(opacity * 0.9), location: edge * 0.6),
                                       .init(color: color.opacity(opacity * 0.98), location: edge),
                                       .init(color: color.opacity(opacity), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Over the picker's top bar (✕, ↻) once the list is scrolled: the screen's own background again, down through the bar
/// and fading out `fade` points under it, so the title and the tiles go under the buttons instead of showing through
/// them (the bottom bar's `BottomBarBacking`, upside down).
private struct TopBarBacking: View {
    static let fade: CGFloat = 24

    var body: some View {
        // Inside the safe area, to know the bar's height (a reader that ignores it says 0); drawn from the sheet's top,
        // up by the bar.
        GeometryReader { geometry in
            let bar = geometry.safeAreaInsets.top
            LinearGradient(stops: [.init(color: Theme.panel, location: 0),
                                   .init(color: Theme.panel, location: bar / max(1, bar + Self.fade)),
                                   .init(color: Theme.panel.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: geometry.size.width, height: bar + Self.fade)
                .offset(y: -bar)
        }
        .allowsHitTesting(false)
    }
}

/// The list has moved off its top: `TopBarBacking` shows. Before iOS 18 it never does (as before it existed).
private struct ScrolledOffTop: ViewModifier {
    @Binding var scrolled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y + $0.contentInsets.top > 4 }) { _, value in
                withAnimation(.easeOut(duration: 0.2)) { scrolled = value }
            }
        } else {
            content
        }
    }
}

/// A camera or stream: its still (16:9; how old it is in its corner once it is old, the crossed-out camera and the tile
/// dimmed when no picture comes — «Не в сети» for VoiceOver) and its name; the camera in use ringed, fresh or not.
/// Nothing technical: the resolution and the model are in Settings.
private struct CameraChoiceTile: View {
    @Environment(AppModel.self) private var model
    let title: String
    let source: SetupStillSource
    let isCamera: Bool
    let selected: Bool
    /// Being set up after the tap: a spinner over the still.
    var busy = false
    let action: () -> Void

    var body: some View {
        let still = SetupStillStore.shared.state(for: source, model: model)
        let offline = still == .failed
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TileStill(source: source, symbol: isCamera ? "video.fill" : "antenna.radiowaves.left.and.right")
                    .overlay {
                        if busy {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                                .padding(14)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                    }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
            }
            .padding(8)
            .background(.white.opacity(selected ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2.5)
            }
            .opacity(offline && !selected ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offline ? (isCamera ? String(localized: "Не в сети") : String(localized: "Нет связи")) : "")
    }
}

/// A still that fills the tile's width (the Mac `SetupStill` has a fixed width); a spinner while it comes, the
/// crossed-out camera when none does.
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
                Group {
                    if state == .loading {
                        ProgressView().tint(.white.opacity(0.6))
                    } else {
                        Image(systemName: state == .failed ? "video.slash.fill" : symbol)
                            .font(.system(size: 20, weight: .medium))
                    }
                }
                .foregroundStyle(.white.opacity(0.4))
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
            // How old the still is once it is old, as Home writes it under its snapshots (Fable, round 9: the green
            // dot said «в сети», not whether the picture was of now); a fresh one says nothing (round 13).
            .overlay(alignment: .bottomLeading) {
                if case .loaded(let image, _) = state {
                    StillAge(since: StillClock.firstSeen(image, source: source))
                        .padding(6)
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

/// When each still the tiles show came: the moment a tile first had it (a refresh brings a new picture, and a new
/// moment). The picker is the only place on the iPhone that asks for stills, so that is when it came, give or take
/// the tile scrolling into view.
@MainActor
private enum StillClock {
    private static var seen: [ObjectIdentifier: Date] = [:]

    static func firstSeen(_ image: PlatformImage, source: SetupStillSource) -> Date {
        let key = ObjectIdentifier(image)
        if let date = seen[key] { return date }
        var date = Date()
        #if DEBUG
        // The demo's stills are there from the start: the hall's camera «сейчас», the kitchen's preview a while ago.
        if SetupDemo.isOn, case .camera = source { date = date.addingTimeInterval(-12) }
        #endif
        seen[key] = date
        return date
    }
}

/// Nothing for the first ten seconds (a live picture needs no word), then «12 с назад», «3 мин назад», «1 ч назад»:
/// small, in the still's corner.
private struct StillAge: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let text = Self.text(context.date.timeIntervalSince(since)) {
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
    }

    static func text(_ seconds: TimeInterval) -> String? {
        let whole = max(0, seconds.rounded(.down))
        if whole < 10 { return nil }
        let age = whole < 60 ? whole : whole < 3600 ? (whole / 60).rounded(.down) * 60 : (whole / 3600).rounded(.down) * 3600
        return String(localized: "\(DurationText.short(age)) назад")
    }
}

/// «Своя камера»: a camera that is not in Mi Home, by its address (`AddStreamSheet`). A tile like the cameras' beside
/// it, with one sign — the pink «+» where their picture is — and its name under it (design council, round 14: not a
/// dashed row with a camera and a plus).
private struct AddStreamTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top,
                                               endPoint: .bottom))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Своя камера")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
            }
            .padding(8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Добавить свою камеру"))
        .accessibilityAddTraits(.isButton)
    }
}

/// «Поток RTSP»: any go2rtc source by its address (a camera that is not in Mi Home, a recorder).
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
                        Text("Поток RTSP")
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
                        Text("Подходят rtsp:// и http://; камеру ONVIF добавьте по её адресу rtsp://. Камера должна быть в той же сети Wi‑Fi.")
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
