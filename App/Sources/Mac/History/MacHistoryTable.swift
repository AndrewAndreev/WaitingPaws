#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Every training and recording in a sortable table, few columns: when (a thumbnail where there is a video), what,
/// the exits with their false starts, the longest stay (its plan only where it fell short). Trainers, the length and the file are in
/// the inspector; the selection drives it.
struct MacHistoryTable: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let rows: [MacHistoryRow]

    /// Height of the header and the rows as laid out (nil until measured): the table ends with its last row.
    @State private var contentHeight: CGFloat?

    var body: some View {
        table
            .background { MacTableContentHeight(rowCount: rows.count) { contentHeight = $0 } }
            // Where a row's «Отправить…» opens the share picker (at the pointer, where its menu was).
            .background { MacShareAnchorView(anchor: controller.shareAnchor) }
            // The stripes of alternating rows would go on under the last row, as rows with nothing in them.
            .frame(maxHeight: rows.isEmpty ? nil : contentHeight)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var table: some View {
        @Bindable var controller = controller
        ScrollViewReader { scroller in
            Table(rows, selection: $controller.selection, sortOrder: $controller.sortOrder) {
                TableColumn("Дата", value: \.date) { row in
                    HStack(spacing: 8) {
                        MacHistoryThumbnail(video: row.video, preparing: preparing(row),
                                            progress: row.video.flatMap { model.videoPreparations[$0.fileName]?.fraction } ?? 0,
                                            isClip: row.isClip)
                        Text(verbatim: "\(MacHistoryFormat.day(row.date)), \(MacFormat.time.string(from: row.date))")
                            .monospacedDigit()
                    }
                }
                .width(min: 170, ideal: 186)

                TableColumn("Тренировка", value: \.title) { row in
                    Text(row.title)
                        .foregroundStyle(row.isClip ? .secondary : .primary)
                        .help(row.title)
                }
                .width(min: 130, ideal: 196)

                // «7 · ↶1»: the exits done — «5 из 7» only where not all were — and the false starts with them, in
                // their orange, only where there were any.
                TableColumn("Выходы", value: \.exitsDone) { row in
                    if let record = row.record {
                        HStack(spacing: 6) {
                            Group {
                                if record.completedExits < record.plan.exits.count {
                                    Text("\(record.completedExits) из \(record.plan.exits.count)")
                                } else {
                                    Text(verbatim: "\(record.completedExits)")
                                }
                            }
                            .monospacedDigit()
                            if record.falseStarts > 0 {
                                Text(verbatim: "·").foregroundStyle(.tertiary)
                                FalseStartsCell(count: record.falseStarts)
                            }
                        }
                    } else {
                        Dash()
                    }
                }
                .width(min: 90, ideal: 104)

                TableColumn("Дольше всего", value: \.longest) { row in
                    if let record = row.record {
                        LongestCell(value: record.longestStayBehindDoor,
                                    plan: record.longestResult?.plannedDuration ?? record.longestPlannedExit)
                    } else {
                        Dash()
                    }
                }
                .width(min: 96, ideal: 110)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: HistoryRoute.self) { ids in
                if let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                    MacHistoryRowMenu(row: row)
                }
            } primaryAction: { ids in
                guard let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) else { return }
                if row.video != nil { controller.play(row) } else { controller.showsInspector = true }
            }
            .onKeyPress(.space) {
                guard let row = controller.row(controller.selection, model: model), row.video != nil else { return .ignored }
                controller.togglePlayback(row)
                return .handled
            }
            .onDeleteCommand {
                if let row = controller.row(controller.selection, model: model) { controller.confirmDelete(row) }
            }
            .copyable(selectedLogs)
            .onChange(of: controller.scrollRequest) {
                if let id = controller.selection { withAnimation { scroller.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// The row's video is being remuxed right now.
    private func preparing(_ row: MacHistoryRow) -> Bool {
        row.video.map { model.finalizingFileNames.contains($0.fileName) } ?? false
    }

    /// ⌘C on a training copies its log.
    private var selectedLogs: [String] {
        controller.row(controller.selection, model: model)?.logText.map { [$0] } ?? []
    }
}

/// Context menu of a row (also used by the toolbar's «…» where it makes sense).
struct MacHistoryRowMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let row: MacHistoryRow

    var body: some View {
        Button("Воспроизвести", systemImage: "play") { controller.play(row) }
            .disabled(row.video == nil)
        Button(row.video == nil ? "Показать лог в Finder" : "Показать в Finder", systemImage: "folder") {
            controller.revealInFinder(row, model: model)
        }
        if let video = row.video {
            Button("Сохранить в Фото", systemImage: "photo.badge.plus") { model.saveToPhotos(video.url) }
            // AppKit's share picker with the file itself, not ShareLink (see `MacShareItem`).
            Button("Отправить видео…", systemImage: "film") { controller.shareAnchor.show(.file(video.url), atPointer: true) }
                .disabled(model.finalizingFileNames.contains(video.fileName))
        }
        if let record = row.record, let log = row.logText {
            Divider()
            Button("Скопировать лог", systemImage: "doc.on.doc") { controller.copyLog(of: row) }
            Button("Отправить лог…", systemImage: "square.and.arrow.up") {
                controller.shareAnchor.show(.text(log, title: record.plan.title, subject: record.plan.title), atPointer: true)
            }
        }
        Divider()
        MacHistoryDeleteItems(row: row)
    }
}

// MARK: - Height

/// The height of a SwiftUI `Table`'s header and rows once AppKit has laid them out. With alternating row
/// backgrounds, NSTableView stripes the empty space below the last row as if more rows were there; a table framed
/// to this height ends with its rows, and the window's background (the table's own colour) shows below.
private struct MacTableContentHeight: NSViewRepresentable {
    let rowCount: Int
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.measure(from: view, rowCount: rowCount)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onChange: (CGFloat) -> Void = { _ in }
        private var reported: CGFloat?
        private weak var observed: NSTableView?
        private var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Next turn of the run loop, when the table has its new rows; again a little later while it hasn't.
        func measure(from view: NSView, rowCount: Int, attempt: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self, weak view] in
                guard let self, let view, rowCount > 0 else { return }
                guard let table = Self.table(beside: view), table.numberOfRows == rowCount else {
                    if attempt < 20 { self.measure(from: view, rowCount: rowCount, attempt: attempt + 1) }
                    return
                }
                self.observe(table)
                self.report(table)
            }
        }

        /// Rows not yet on screen have an estimated height; the table's frame changes as they get their own.
        private func observe(_ table: NSTableView) {
            guard observed !== table else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observed = table
            table.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: table,
                                                              queue: .main) { [weak self, weak table] _ in
                MainActor.assumeIsolated {
                    if let self, let table { self.report(table) }
                }
            }
        }

        private func report(_ table: NSTableView) {
            guard let scroll = table.enclosingScrollView else { return }
            // Down to the last row's edge: the inset style's padding under it would show the top of the next
            // stripe. The header sits above the rows in the scroll view (in its top inset, where it has one).
            let count = table.numberOfRows
            guard count > 0 else { return }
            let rows = table.rect(ofRow: count - 1).maxY
            let header = max(scroll.contentInsets.top, table.headerView?.frame.height ?? 0)
            let height = (header + rows + scroll.contentInsets.bottom).rounded(.up)
            guard height != reported else { return }
            reported = height
            onChange(height)
        }

        /// The table this view is the background of: among the tables of its nearest ancestors, the one whose
        /// scroll view covers the most of it.
        private static func table(beside view: NSView) -> NSTableView? {
            guard let window = view.window else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            var ancestor = view.superview
            for _ in 0..<8 {
                guard let current = ancestor else { break }
                let candidates = tables(in: current).compactMap { table -> (NSTableView, CGFloat)? in
                    guard let scroll = table.enclosingScrollView, scroll.window === window else { return nil }
                    let overlap = scroll.convert(scroll.bounds, to: nil).intersection(frame)
                    return overlap.isNull ? nil : (table, overlap.width * overlap.height)
                }
                if let best = candidates.max(by: { $0.1 < $1.1 }) { return best.0 }
                ancestor = current.superview
            }
            return nil
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap(tables(in:))
        }
    }
}

// MARK: - Cells

private struct Dash: View {
    var body: some View { Text("—").foregroundStyle(.tertiary) }
}

private struct FalseStartsCell: View {
    let count: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label("\(count)", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .help(HistoryText.falseStarts(count))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(MacHistoryInk.orange))
    }
}

/// «2:32»: the longest stay; its plan quieter beside it only where the stay fell short of it, «0:50  1:00».
private struct LongestCell: View {
    let value: TimeInterval
    let plan: TimeInterval
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DurationText.clock(value))
                .frame(minWidth: 34, alignment: .trailing)
            if value.rounded(.down) < plan.rounded(.down) {
                Text(DurationText.clock(plan))
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
        }
        .monospacedDigit()
        .help(String(localized: "план \(DurationText.clock(plan))"))
    }
}
#endif
