#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «История» (C2 «Таблица + прогресс»): progress over the last weeks on top, every training and recording in a
/// sortable table, the selected row in the inspector (video with exit markers, totals, the log for the trainer).
struct MacHistoryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var controller = MacHistoryController()

    var body: some View {
        @Bindable var controller = controller
        let rows = controller.visibleRows(model)
        let selected = controller.row(controller.selection, model: model)
        let isEmpty = controller.isEmpty(model)

        NavigationStack {
            content(rows: rows, selected: selected, isEmpty: isEmpty)
                .navigationTitle("История")
                .navigationSubtitle(subtitle)
                .searchable(text: $controller.search, placement: .toolbar, prompt: "Поиск")
                .toolbar { toolbar(selected: selected, isEmpty: isEmpty) }
                .inspector(isPresented: Binding(get: { controller.showsInspector && !isEmpty },
                                                set: { controller.showsInspector = $0 })) {
                    Group {
                        if let selected {
                            MacHistoryInspector(row: selected)
                        } else {
                            ContentUnavailableView("Ничего не выбрано", systemImage: "sidebar.trailing",
                                                   description: Text("Выберите тренировку или запись в таблице."))
                        }
                    }
                    .inspectorColumnWidth(min: 290, ideal: 320, max: 440)
                }
        }
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
            } description: {
                Text("Вставьте расписание тренера (⇧⌘V) и проведите тренировку — здесь появятся её лог, видео и график: сколько собака спокойно ждёт за дверью.")
            } actions: {
                Button("Перейти к тренировке") { openWindow(id: "main") }
            }
        } else {
            let records = controller.records(model)
            VStack(spacing: 0) {
                if records.isEmpty {
                    Label("График прогресса появится после первой тренировки.", systemImage: "chart.xyaxis.line")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    MacHistoryProgressPanel(records: records, selected: selected?.record)
                }
                Divider()
                MacHistoryTable(rows: rows, longestEver: records.map(\.longestStayBehindDoor).max() ?? 0)
                    .overlay { if rows.isEmpty { noRows } }
            }
        }
    }

    @ViewBuilder
    private var noRows: some View {
        if !controller.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: controller.search)
        } else if controller.scope == .clips {
            ContentUnavailableView("Нет записей без тренировки", systemImage: "film",
                                   description: Text("Здесь будут видео, снятые кнопкой записи без тренировки, и видео, у которых удалили лог."))
        } else {
            ContentUnavailableView("Тренировок пока нет", systemImage: "pawprint",
                                   description: Text("Есть только записи без тренировки — они во вкладке «Только видео»."))
        }
    }

    /// "11 тренировок, 3 записи · 5,8 ГБ".
    private var subtitle: String {
        let trainings = controller.records(model).count
        let clips = controller.clips(model).count
        if trainings == 0 && clips == 0 { return "" }
        var parts: [String] = []
        if trainings > 0 || clips == 0 { parts.append(MacHistoryFormat.count(trainings, "тренировка", "тренировки", "тренировок")) }
        if clips > 0 { parts.append(MacHistoryFormat.count(clips, "запись", "записи", "записей")) }
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
    }

    /// ⇧⌘C works with the inspector closed too.
    private func shortcuts(selected: MacHistoryRow?) -> some View {
        Button("Скопировать лог") { if let selected { controller.copyLog(of: selected) } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selected?.record == nil)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Delete

    private var deleteTitle: String {
        guard let pending = controller.pendingDelete else { return "" }
        if pending.row.isClip { return "Удалить запись?" }
        return pending.onlyLog == true ? "Удалить лог тренировки?" : "Удалить тренировку?"
    }

    private func deleteMessage(_ pending: MacHistoryController.PendingDelete) -> String {
        let row = pending.row
        let what = row.isClip
            ? "Запись \(MacHistoryFormat.dayMonth(row.date)), \(MacFormat.time.string(from: row.date))."
            : "«\(row.title)», \(MacHistoryFormat.dayMonth(row.date)), \(MacFormat.time.string(from: row.date))."
        if pending.onlyLog == true { return what + " Видео останется в истории как запись без тренировки." }
        return row.video == nil ? what : what + " Копии в Фото не удаляются."
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
        switch (trainings, clips) {
        case (_, 0): return "Удалить \(MacHistoryFormat.count(trainings, "тренировку", "тренировки", "тренировок"))"
        case (0, _): return "Удалить \(MacHistoryFormat.count(clips, "запись", "записи", "записей"))"
        default:
            return "Удалить \(MacHistoryFormat.count(trainings, "тренировку", "тренировки", "тренировок")) и \(MacHistoryFormat.count(clips, "запись", "записи", "записей"))"
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
