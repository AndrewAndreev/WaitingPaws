#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «История» (C2 «Таблица + прогресс»): progress over the last weeks on top, every training and recording in a
/// sortable table, the selected row in the inspector (video with exit markers, totals, the log for the trainer).
struct MacHistoryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var controller = MacHistoryController()
    /// Where the inspector's left edge is in the window right now (nil while it is closed), and the window's width:
    /// the search field above the inspector follows that edge, and the buttons before it with it.
    @State private var inspectorMinX: CGFloat?
    @State private var windowWidth: CGFloat = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var controller = controller
        let rows = controller.visibleRows(model)
        let selected = controller.row(controller.selection, model: model)
        let isEmpty = controller.isEmpty(model)

        NavigationStack {
            content(rows: rows, selected: selected, isEmpty: isEmpty)
                .navigationTitle("История")
                .navigationSubtitle(subtitle)
                .toolbar { toolbar(selected: selected, isEmpty: isEmpty) }
                .inspector(isPresented: Binding(get: { controller.showsInspector && !isEmpty },
                                                set: { controller.showsInspector = $0 })) {
                    Group {
                        if let selected {
                            MacHistoryInspector(row: selected)
                        } else {
                            ContentUnavailableView("Ничего не выбрано", systemImage: "sidebar.trailing")
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { inspectorMinX = $0 }
                    .onDisappear { inspectorMinX = nil }
                    .inspectorColumnWidth(min: 290, ideal: 320, max: 440)
                }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).width }) { windowWidth = $0 }
        .environment(controller)
        .frame(minWidth: 920, minHeight: 560)
        .background { shortcuts(selected: selected) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { controller.pendingDelete != nil },
                                                              set: { if !$0 { controller.pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: controller.pendingDelete) { pending in
            deleteButtons(pending, rows: rows)
        } message: { pending in
            Text(deleteMessage(pending))
        }
        .confirmationDialog("Удалить всю историю?", isPresented: $controller.confirmDeleteAll, titleVisibility: .visible) {
            Button(deleteAllTitle, role: .destructive) { controller.deleteAll(model) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Логи и видео будут удалены с этого Mac. Копии в Фото останутся.")
        }
        .task(id: controller.filesSignature(model)) { await controller.refreshFiles(model) }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            // Keep a visible row selected (the first one when the selection vanished or got filtered out);
            // next turn of the run loop, as a table that has just appeared would otherwise reset it.
            DispatchQueue.main.async {
                if controller.selection.map({ !ids.contains($0) }) ?? true { controller.selection = ids.first }
            }
        }
        .onChange(of: controller.showsInspector) {
            if !controller.showsInspector { controller.player.player.pause() }
        }
        .onAppear {
            #if DEBUG
            // `--demo-history` keeps its sample trainings in memory only: reloading would drop them.
            if CommandLine.arguments.contains("--demo-history") { return }
            #endif
            model.reloadHistory()
        }
        .onDisappear { controller.player.load(nil) }
        #if DEBUG
        .task { await MacHistoryDebug.setUp(controller, model: model) }
        .preferredColorScheme(MacHistoryDebug.colorScheme)
        #endif
    }

    // MARK: Content

    @ViewBuilder
    private func content(rows: [MacHistoryRow], selected: MacHistoryRow?, isEmpty: Bool) -> some View {
        if isEmpty {
            ContentUnavailableView {
                Label("Пока нет тренировок", systemImage: "pawprint")
            } actions: {
                Button("Перейти к тренировке") { openWindow(id: "main") }
            }
        } else {
            let records = controller.records(model)
            VStack(spacing: 0) {
                // Only recordings so far: no chart, the table alone.
                if !records.isEmpty {
                    MacHistoryProgressPanel(records: records, selected: selected?.record)
                    Divider()
                }
                MacHistoryTable(rows: rows)
                    .overlay { if rows.isEmpty { noRows } }
            }
        }
    }

    @ViewBuilder
    private var noRows: some View {
        if !controller.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: controller.search)
        } else if controller.scope == .clips {
            ContentUnavailableView("Нет записей без тренировки", systemImage: "film")
        } else {
            ContentUnavailableView("Тренировок пока нет", systemImage: "pawprint")
        }
    }

    /// "11 тренировок, 3 записи · 5,8 ГБ".
    private var subtitle: String {
        let trainings = controller.records(model).count
        let clips = controller.clips(model).count
        if trainings == 0 && clips == 0 { return "" }
        var parts: [String] = []
        if trainings > 0 || clips == 0 { parts.append(MacHistoryFormat.trainings(trainings)) }
        if clips > 0 { parts.append(MacHistoryFormat.recordings(clips)) }
        let bytes = controller.videos.values.reduce(Int64(0)) { $0 + $1.bytes }
        return parts.joined(separator: ", ") + (bytes > 0 ? " · " + MacHistoryFormat.bytes(bytes) : "")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(selected: MacHistoryRow?, isEmpty: Bool) -> some ToolbarContent {
        @Bindable var controller = controller
        ToolbarItem(placement: .principal) {
            Picker("Показать", selection: $controller.scope) {
                ForEach(MacHistoryController.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let selected, let record = selected.record, let text = selected.logText {
                ShareLink(item: text, subject: Text(record.plan.title), preview: SharePreview(record.plan.title)) {
                    Label("Отправить лог", systemImage: "square.and.arrow.up")
                }
                .help("Отправить лог тренеру")
            } else {
                Button("Отправить лог", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
                    .help("Отправить лог тренеру")
            }
            Button("Показать в Finder", systemImage: "folder") {
                if let selected { controller.revealInFinder(selected, model: model) } else { Finder.reveal(model.store.rootDirectory) }
            }
            .help(selected?.video != nil ? "Показать видео в Finder" : selected?.record != nil ? "Показать лог в Finder" : "Показать папку истории в Finder")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let selected {
                    MacHistoryDeleteItems(row: selected)
                    Divider()
                }
                Button("Удалить всё…", role: .destructive) { controller.confirmDeleteAll = true }
            } label: {
                Label("Удалить", systemImage: "trash")
            } primaryAction: {
                if let selected { controller.confirmDelete(selected) }
            }
            .disabled(isEmpty)
            .help("Удалить выбранное (⌫)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button("Инспектор", systemImage: "sidebar.trailing") { controller.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(isEmpty)
                .help(controller.showsInspector ? "Скрыть инспектор (⌥⌘I)" : "Показать инспектор (⌥⌘I)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Last in the toolbar, so at the window's edge: as wide as the inspector it sits on, which puts the buttons
        // above right before the inspector's edge; with the inspector closed, a plain field next to them.
        ToolbarItem(placement: .primaryAction) {
            MacToolbarSearchField(text: $controller.search, focus: $searchFocused, prompt: "Поиск")
                .frame(width: searchWidth)
                // Follows the inspector frame by frame as it slides or is resized; an animation of its own would
                // lag behind the toolbar, which places the items at once, and run into the buttons.
                .transaction { $0.animation = nil }
        }
    }

    /// The part of the window the inspector covers right now, less the toolbar's margin at the window's edge and a
    /// gap after the inspector's edge (the field stays inside the inspector); never narrower than a plain field.
    private var searchWidth: CGFloat {
        var covered: CGFloat = 0
        // The first layout passes report the inspector at the window's left: not yet where it will be.
        if let minX = inspectorMinX, windowWidth > 0, minX >= windowWidth / 2 { covered = windowWidth - minX }
        return max(Self.plainSearchWidth, covered - Self.searchInsets)
    }

    private static let plainSearchWidth: CGFloat = 200
    private static let searchInsets: CGFloat = 16

    /// ⇧⌘C works with the inspector closed too; ⌘F goes to the search field.
    private func shortcuts(selected: MacHistoryRow?) -> some View {
        ZStack {
            Button("Скопировать лог") { if let selected { controller.copyLog(of: selected) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selected?.record == nil)
            Button("Поиск") {
                searchFocused = true
                MacToolbarSearchField.focus(in: NSApp.keyWindow, prompt: String(localized: "Поиск"))
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Delete

    private var deleteTitle: String {
        guard let pending = controller.pendingDelete else { return "" }
        if pending.row.isClip { return String(localized: "Удалить запись?") }
        return pending.onlyLog == true ? String(localized: "Удалить лог тренировки?") : String(localized: "Удалить тренировку?")
    }

    private func deleteMessage(_ pending: MacHistoryController.PendingDelete) -> String {
        let row = pending.row
        let day = MacHistoryFormat.dayMonth(row.date)
        let time = MacFormat.time.string(from: row.date)
        let what = row.isClip
            ? String(localized: "Запись \(day), \(time).")
            : String(localized: "«\(row.title)», \(day), \(time).")
        if pending.onlyLog == true { return String(localized: "\(what) Видео останется в истории как запись без тренировки.") }
        return row.video == nil ? what : String(localized: "\(what) Копии в Фото не удаляются.")
    }

    @ViewBuilder
    private func deleteButtons(_ pending: MacHistoryController.PendingDelete, rows: [MacHistoryRow]) -> some View {
        let row = pending.row
        if row.isClip {
            Button("Удалить запись", role: .destructive) { controller.delete(row, onlyLog: false, model: model, visible: rows) }
        } else {
            if pending.onlyLog != true {
                Button(row.video == nil ? "Удалить тренировку" : "Удалить тренировку и видео", role: .destructive) {
                    controller.delete(row, onlyLog: false, model: model, visible: rows)
                }
            }
            if pending.onlyLog != false {
                Button(pending.onlyLog == true ? "Удалить лог" : "Удалить только лог, видео оставить") {
                    controller.delete(row, onlyLog: true, model: model, visible: rows)
                }
            }
        }
        Button("Отмена", role: .cancel) {}
    }

    private var deleteAllTitle: String {
        let trainings = controller.records(model).count
        let clips = controller.clips(model).count
        // Accusative: «Удалить 1 тренировку».
        let trainingsText = pluralText(trainings, ru: ("тренировку", "тренировки", "тренировок"), en: ("training", "trainings"))
        let clipsText = MacHistoryFormat.recordings(clips)
        switch (trainings, clips) {
        case (_, 0): return String(localized: "Удалить \(trainingsText)")
        case (0, _): return String(localized: "Удалить \(clipsText)")
        default: return String(localized: "Удалить \(trainingsText) и \(clipsText)")
        }
    }
}

/// The toolbar's search field, drawn like the system one (the toolbar gives it the glass capsule). Not `.searchable`:
/// SwiftUI gives that field a fixed width at the window's edge, so it ran over the inspector's edge and could not
/// follow the inspector's width.
struct MacToolbarSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var prompt: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                // Esc clears, as in the system field.
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Очистить")
            }
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(prompt))
    }

    /// ⌘F. `FocusState` does not always reach a text field hosted in the toolbar, so the field is also found in the
    /// window's frame view (the toolbar lives there) and made first responder directly.
    static func focus(in window: NSWindow?, prompt: String) {
        DispatchQueue.main.async {
            guard let window, let frame = window.contentView?.superview else { return }
            func field(in view: NSView) -> NSTextField? {
                if let text = view as? NSTextField, text.isEditable, text.placeholderString == prompt { return text }
                return view.subviews.lazy.compactMap(field(in:)).first
            }
            guard let text = field(in: frame), text.currentEditor() == nil else { return }
            window.makeFirstResponder(text)
        }
    }
}

/// Delete commands for one row (toolbar menu); each asks for confirmation.
struct MacHistoryDeleteItems: View {
    @Environment(MacHistoryController.self) private var controller
    let row: MacHistoryRow

    var body: some View {
        switch row.kind {
        case .training:
            Button(row.video == nil ? "Удалить тренировку…" : "Удалить тренировку и видео…", systemImage: "trash", role: .destructive) {
                controller.confirmDelete(row, onlyLog: false)
            }
            if row.video != nil {
                Button("Удалить только лог, видео оставить…", systemImage: "doc.badge.minus") {
                    controller.confirmDelete(row, onlyLog: true)
                }
            }
        case .clip:
            Button("Удалить запись…", systemImage: "trash", role: .destructive) { controller.confirmDelete(row) }
        }
    }
}
#endif
