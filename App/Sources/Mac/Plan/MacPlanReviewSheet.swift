#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Расписание разобрано» (B1 «Текст ↔ таблица») — the sheet over the «Пульт» right after a paste:
/// the trainer's text on the left as a read-only source view (recognised lines marked in the gutter),
/// the parsed exits as an editable table on the right, the summary and the start in the bottom bar.
/// Selecting a row highlights its lines in the text; clicking an exit line selects its row.
/// During a training the same sheet edits the running schedule («Сохранить»): the exits already done and the
/// current one keep their place (`fixedExits`).
struct MacPlanReviewSheet: View {
    @Binding var plan: TrainingPlan
    /// «Начать тренировку ⌘↩» (during a training: «Сохранить ⌘↩»).
    var onStart: () -> Void
    /// «Готово»: keep the plan on the «Пульт» without starting (during a training: «Отменить»).
    var onDone: () -> Void
    /// During a training: how many exits from the start are done or running (can't be removed or moved).
    var fixedExits: Int?

    @Environment(AppModel.self) private var model
    @State private var selection: Set<PlannedExit.ID> = []

    init(plan: Binding<TrainingPlan>, fixedExits: Int? = nil, onStart: @escaping () -> Void, onDone: @escaping () -> Void) {
        _plan = plan
        self.fixedExits = fixedExits
        self.onStart = onStart
        self.onDone = onDone
    }

    private var isRunning: Bool { fixedExits != nil }

    private var lines: [MacPlanTextLine] { MacPlanTextLine.classify(plan.rawText) }

    var body: some View {
        let lines = lines
        let lineOfExit = MacPlanLineMap.lines(for: plan, textLines: lines)
        VStack(spacing: 0) {
            header(lines)
            Divider()
            if lines.contains(where: { $0.kind != .blank }) {
                HSplitView {
                    PlanSourcePane(lines: lines, plan: plan, lineOfExit: lineOfExit, selection: $selection)
                        .frame(minWidth: 360, idealWidth: 410, maxWidth: 620)
                    PlanTablePane(plan: $plan, selection: $selection, lines: lines, lineOfExit: lineOfExit,
                                  fixedCount: fixedExits ?? 0)
                        .frame(minWidth: 690, maxWidth: .infinity)
                }
            } else {
                PlanTablePane(plan: $plan, selection: $selection, lines: lines, lineOfExit: lineOfExit,
                              fixedCount: fixedExits ?? 0)
            }
            bottomBar
        }
        .frame(minWidth: 1100, maxWidth: 1600, minHeight: 700, maxHeight: 1100)
        #if DEBUG
        .onAppear {
            // `--demo-review-select N`: the row of exit N selected (screenshots of the text ↔ table link).
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--demo-review-select"), i + 1 < args.count, let n = Int(args[i + 1]),
               let exit = plan.exits.first(where: { $0.number == n }) {
                selection = [exit.id]
            }
        }
        #endif
    }

    // MARK: Header

    private func header(_ lines: [MacPlanTextLine]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isRunning ? "pencil.circle.fill" : plan.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(isRunning ? MacPalette.blue : plan.isValid ? MacPalette.green : MacPalette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRunning ? "Расписание тренировки" : plan.isValid ? "Расписание разобрано" : "В расписании нет выходов")
                    .font(.title3.weight(.semibold))
                Text(isRunning
                     ? String(localized: "Тренировка идёт: изменения применятся сразу, и к идущему перерыву тоже. Прошедшие выходы и текущий нельзя удалить или переставить.")
                     : summary(lines))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// «9 выходов, 2 перерыва, правило фальстарта и 3 заметки. Проверьте…».
    private func summary(_ lines: [MacPlanTextLine]) -> String {
        guard !plan.rawText.isEmpty else {
            return String(localized: "\(MacPlanFormat.exits(plan.exits.count)). Проверьте длительности и перерывы перед стартом.")
        }
        var parts = [MacPlanFormat.exits(lines.filter(\.isExit).count)]
        let breaks = lines.filter(\.isBreak).count
        if breaks > 0 { parts.append(MacPlanFormat.breaks(breaks)) }
        if lines.contains(where: { $0.kind == .rule }) { parts.append(String(localized: "правило фальстарта")) }
        let notes = lines.filter { $0.kind == .note }.count
        if notes > 0 { parts.append(MacPlanFormat.notes(notes)) }
        // «a, b и c» / "a, b, and c".
        let list = parts.formatted(.list(type: .and).locale(CoreLanguage.current.locale))
        return String(localized: "\(list.capitalizedFirst). Проверьте и поправьте, если что-то прочитано не так.")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        @Bindable var settings = model.settings
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(MacPlanFormat.exits(plan.exits.count)) · \(MacPlanFormat.approx(plan.estimatedDuration))")
                            .fontWeight(.semibold)
                        if plan.isValid {
                            Text("за дверью \(DurationText.short(MacPlanFormat.exitsTotal(plan))), перерывы \(DurationText.short(MacPlanFormat.breaksTotal(plan)))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                    .fixedSize()
                    MacPlanMiniBar(plan: plan, height: 5)
                        .frame(width: 300)
                }
                Spacer(minLength: 12)
                if isRunning {
                    Button("Отменить", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                        .help("Закрыть без изменений · Esc")
                } else {
                    Toggle("Записывать видео", isOn: $settings.autoRecord)
                        .toggleStyle(.checkbox)
                        .help("Включить запись с камеры вместе с тренировкой")
                    Button("Готово", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                        .help("Оставить расписание на пульте и поправить его на таймлайне · Esc")
                }
                Button(action: onStart) {
                    ShortcutLabel(title: isRunning ? String(localized: "Сохранить") : String(localized: "Начать тренировку"),
                                  symbol: isRunning ? "checkmark" : "play.fill", key: "⌘↩", prominent: true)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacPalette.pinkDeep)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!plan.isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(.bar)
    }
}

// MARK: - Source

/// The pasted text as a read-only source view: line numbers, a coloured bar for every recognised line
/// (like Xcode's change bars), notes dimmed, a legend at the bottom.
private struct PlanSourcePane: View {
    let lines: [MacPlanTextLine]
    let plan: TrainingPlan
    let lineOfExit: [UUID: Int]
    @Binding var selection: Set<PlannedExit.ID>
    @Environment(\.colorScheme) private var scheme

    /// Lines of the selected exits and their own breaks.
    private var linked: Set<Int> {
        let exitLines = Set(selection.compactMap { lineOfExit[$0] })
        var result = exitLines
        for line in lines {
            if case .ownBreak(let after) = line.kind, exitLines.contains(after) { result.insert(line.id) }
        }
        return result
    }

    var body: some View {
        let linked = linked
        VStack(spacing: 0) {
            jumpBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { row($0, linked: linked.contains($0.id)).id($0.id) }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: linked.min()) { _, line in
                    guard let line else { return }
                    withAnimation(.snappy) { proxy.scrollTo(line, anchor: .center) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            legend
        }
    }

    private var jumpBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
            Text("Текст тренера")
            Spacer(minLength: 8)
            Text("разобран автоматически").foregroundStyle(.tertiary).layoutPriority(-1)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(MacPalette.green)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func row(_ line: MacPlanTextLine, linked: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(line.id)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(linked ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 30, alignment: .trailing)
                .padding(.top, 1)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(line.isRecognised ? line.tint(scheme) : .clear)
                .frame(width: 3)
                .padding(.horizontal, 9)
            Text(line.attributed(scheme: scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2.5)
        .padding(.trailing, 14)
        .frame(minHeight: 19)
        .background(linked ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { select(line) }
        .help(help(line))
    }

    /// Click an exit line (or its break) → select that exit in the table.
    private func select(_ line: MacPlanTextLine) {
        let exitLine: Int
        switch line.kind {
        case .exit: exitLine = line.id
        case .ownBreak(let after): exitLine = after
        default: return
        }
        if let id = lineOfExit.first(where: { $0.value == exitLine })?.key, plan.exits.contains(where: { $0.id == id }) {
            selection = [id]
        }
    }

    private func help(_ line: MacPlanTextLine) -> String {
        switch line.kind {
        case .header: String(localized: "Заголовок: название, тренеры и дата")
        case .exit(let number, _): String(localized: "Выход \(number) — щёлкните, чтобы выбрать его в таблице")
        case .ownBreak: String(localized: "Свой перерыв после выхода выше")
        case .defaultBreak: String(localized: "Перерыв между выходами")
        case .rule: String(localized: "Правило фальстарта")
        case .note: String(localized: "Заметка тренера")
        case .blank: ""
        }
    }

    private var legend: some View {
        let exits = lines.filter(\.isExit).count
        let breaks = lines.filter(\.isBreak).count
        let notes = lines.filter { $0.kind == .note }.count
        return HStack(spacing: 14) {
            legendItem(MacPlanTint.exit(scheme), MacPlanFormat.exits(exits))
            if breaks > 0 {
                legendItem(MacPlanTint.pause(scheme), MacPlanFormat.breaks(breaks))
            }
            if lines.contains(where: { $0.kind == .rule }) {
                legendItem(MacPlanTint.rule(scheme), String(localized: "фальстарт"))
            }
            if notes > 0 {
                legendItem(.secondary.opacity(0.6), MacPlanFormat.notes(notes), hollow: true)
            }
            Spacer(minLength: 0)
            Text(pluralText(lines.count, ru: ("строка", "строки", "строк"), en: ("line", "lines"))).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func legendItem(_ color: Color, _ text: String, hollow: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(hollow ? .clear : color)
                .strokeBorder(hollow ? color : .clear, lineWidth: 1)
                .frame(width: 3, height: 11)
            Text(text)
        }
        .fixedSize()
    }
}

// MARK: - Table

private struct PlanTablePane: View {
    @Binding var plan: TrainingPlan
    @Binding var selection: Set<PlannedExit.ID>
    let lines: [MacPlanTextLine]
    let lineOfExit: [UUID: Int]
    /// During a training: the first exits (done or running) stay where they are.
    var fixedCount = 0

    @Environment(\.colorScheme) private var scheme
    @FocusState private var tableFocused: Bool
    @State private var customDefaultBreak = false

    private static let dragPrefix = "waitingpaws.exit:"

    private var ownBreaks: [PlannedExit] {
        plan.exits.dropLast().filter { $0.breakAfter != nil }
    }

    private var selectedIndices: [Int] {
        plan.exits.indices.filter { selection.contains(plan.exits[$0].id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            planForm
            Divider()
            table
            Divider()
            tableFooter
            if let rule = ruleLine {
                Divider()
                ruleView(rule)
            }
        }
    }

    // MARK: Header fields

    /// Mac form layout: right-aligned labels, two columns.
    private var planForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 9) {
            GridRow {
                Text("Название:").gridColumnAlignment(.trailing)
                TextField("Название", text: $plan.title, prompt: Text("Тренировка")).labelsHidden()
                Text("Дата:").gridColumnAlignment(.trailing)
                DatePicker("Дата", selection: Binding(get: { plan.date ?? Date() }, set: { plan.date = $0 }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .fixedSize()
            }
            GridRow {
                Text("Тренеры:")
                TextField("Тренеры", text: $plan.trainers, prompt: Text("Кто тренирует")).labelsHidden()
                Text("Перерыв:")
                HStack(spacing: 8) {
                    defaultBreakMenu
                    Button("Сделать везде \(DurationText.short(plan.defaultBreak))") {
                        withAnimation(.snappy) {
                            for index in plan.exits.indices { plan.exits[index].breakAfter = nil }
                        }
                    }
                    .disabled(ownBreaks.isEmpty)
                    .fixedSize()
                    .help(resetBreaksHelp)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// «Убрать свои перерывы: после 3-го — 5 мин, …».
    private var resetBreaksHelp: String {
        guard !ownBreaks.isEmpty else { return String(localized: "У всех выходов общий перерыв") }
        let list = ownBreaks
            .map { String(localized: "после \($0.number)-го — \(DurationText.short($0.breakAfter ?? 0))") }
            .joined(separator: ", ")
        return String(localized: "Убрать свои перерывы: \(list)")
    }

    /// Break between exits: presets, the current value if it is not one of them, «Другой…».
    private var defaultBreakMenu: some View {
        Menu {
            let presets = MacPlanFormat.breakPresets
            ForEach(presets.contains(plan.defaultBreak) ? presets : (presets + [plan.defaultBreak]).sorted(), id: \.self) { value in
                Toggle(DurationText.short(value), isOn: Binding(
                    get: { plan.defaultBreak == value }, set: { if $0 { setDefaultBreak(value) } }))
            }
            Divider()
            Button("Другой…") { customDefaultBreak = true }
        } label: {
            Text(DurationText.short(plan.defaultBreak)).monospacedDigit()
        }
        .fixedSize()
        .help("Перерыв между выходами — у всех, кроме выходов со своим перерывом")
        .popover(isPresented: $customDefaultBreak, arrowEdge: .bottom) {
            MacDurationEditor(value: Binding(get: { plan.defaultBreak }, set: { setDefaultBreak($0 ?? plan.defaultBreak) }),
                              title: String(localized: "Перерыв между выходами"), presets: MacPlanFormat.breakPresets,
                              tint: MacPalette.blue) { customDefaultBreak = false }
        }
    }

    /// A new common break; own breaks that now equal it become common again (as `PlanParser` reads them).
    private func setDefaultBreak(_ value: TimeInterval) {
        plan.defaultBreak = value
        for index in plan.exits.indices where plan.exits[index].breakAfter == value {
            plan.exits[index].breakAfter = nil
        }
    }

    // MARK: Table

    private func binding(_ exit: PlannedExit) -> Binding<PlannedExit> {
        Binding {
            plan.exits.first { $0.id == exit.id } ?? exit
        } set: { newValue in
            if let index = plan.exits.firstIndex(where: { $0.id == exit.id }) { plan.exits[index] = newValue }
        }
    }

    private var table: some View {
        Table(of: PlannedExit.self, selection: $selection) {
            TableColumn("№") { exit in
                HStack(spacing: 3) {
                    if isFixed(exit.id) {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Text("\(exit.number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(isFixed(exit.id) ? String(localized: "Выход уже прошёл или идёт сейчас: его можно поправить, но не удалить и не переставить") : "")
            }
            .width(fixedCount > 0 ? 36 : 24)
            TableColumn("Начало") { exit in
                Text("+" + DurationText.clock(start(of: exit)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .width(52)
            TableColumn("За дверью") { exit in
                ExitDurationCell(exit: binding(exit))
            }
            .width(min: 70, ideal: 78)
            TableColumn("До вставания") { exit in
                Toggle("Или до вставания", isOn: binding(exit).untilStanding)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help("«ИЛИ до вставания»: собака встала — сразу возвращаться")
            }
            .width(86)
            TableColumn("Перерыв после") { exit in
                BreakAfterCell(exit: binding(exit), defaultBreak: plan.defaultBreak,
                               isLast: exit.id == plan.exits.last?.id)
            }
            .width(min: 104, ideal: 112)
            TableColumn("Заметка") { exit in
                TextField("Заметка", text: Binding(get: { binding(exit).wrappedValue.note ?? "" },
                                                   set: { binding(exit).wrappedValue.note = $0.isEmpty ? nil : $0 }),
                          prompt: Text(""))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Строка") { exit in
                lineCell(exit)
            }
            .width(48)
        } rows: {
            ForEach(plan.exits) { exit in
                TableRow(exit)
                    .draggable(Self.dragPrefix + exit.id.uuidString)
            }
            .dropDestination(for: String.self) { index, items in
                move(items.filter { $0.hasPrefix(Self.dragPrefix) }
                        .compactMap { UUID(uuidString: String($0.dropFirst(Self.dragPrefix.count))) }, to: index)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .onDeleteCommand(perform: deleteSelected)
        .contextMenu(forSelectionType: PlannedExit.ID.self) { ids in
            if !ids.isEmpty {
                Button("Дублировать") { duplicate(ids) }
                Button("Добавить выход ниже") { add(after: ids) }
                Divider()
                Button("Удалить", role: .destructive) { delete(ids) }
            } else {
                Button("Добавить выход") { add(after: []) }
            }
        }
    }

    @ViewBuilder
    private func lineCell(_ exit: PlannedExit) -> some View {
        if let line = lineOfExit[exit.id] {
            Text("\(line)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Строка \(line) в тексте тренера")
        } else {
            Text("вручную")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Выхода нет в тексте тренера — добавлен здесь")
        }
    }

    private func start(of exit: PlannedExit) -> TimeInterval {
        guard let index = plan.exits.firstIndex(where: { $0.id == exit.id }) else { return 0 }
        return MacPlanFormat.start(of: index, in: plan)
    }

    // Classic +/− bar under a table (System Settings, Finder).
    private var tableFooter: some View {
        let hasSelection = !selection.isEmpty
        return HStack(spacing: 2) {
            footerButton("plus", String(localized: "Добавить выход · ⌘N")) { add(after: selection) }
                .keyboardShortcut("n", modifiers: .command)
            footerButton("minus", String(localized: "Удалить выбранные · ⌫")) { deleteSelected() }
                .disabled(!hasSelection || plan.exits.count <= selection.count)
            Divider().frame(height: 14).padding(.horizontal, 6)
            footerButton("plus.square.on.square", String(localized: "Дублировать · ⌘D")) { duplicate(selection) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!hasSelection)
            footerButton("arrow.up", String(localized: "Выше · ⌥⌘↑")) { shiftSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selectedIndices.first.map { $0 == 0 } ?? true)
            footerButton("arrow.down", String(localized: "Ниже · ⌥⌘↓")) { shiftSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selectedIndices.last.map { $0 == plan.exits.count - 1 } ?? true)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                footerHints(drag: String(localized: "Перетащите строку, чтобы изменить порядок"))
                footerHints(drag: String(localized: "Строки можно перетаскивать"))
                footerHints(drag: nil)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private func footerHints(drag: String?) -> some View {
        HStack(spacing: 0) {
            if let drag {
                Text(drag).foregroundStyle(.tertiary).padding(.trailing, 10)
            }
            HStack(spacing: 3) { KeyCap("⌘D"); Text("дублировать") }
            HStack(spacing: 3) { KeyCap("⌫"); Text("удалить") }.padding(.leading, 8)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func footerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Rule

    private var ruleLine: MacPlanTextLine? { lines.first { $0.kind == .rule } }

    private func ruleView(_ line: MacPlanTextLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(MacPlanTint.rule(scheme))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Правило фальстарта").fontWeight(.semibold)
                    Text("строка \(line.id)").foregroundStyle(.tertiary).font(.system(size: 11))
                }
                Text(MacPlanFormat.ruleBody(MacPlanTextLine.stripDecorations(line.text)))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(MacPlanTint.rule(scheme).opacity(0.07))
    }

    // MARK: Editing

    private func isFixed(_ id: UUID) -> Bool {
        plan.exits.prefix(fixedCount).contains { $0.id == id }
    }

    private func add(after ids: Set<PlannedExit.ID>) {
        // Never in between the exits already done.
        let index = max(fixedCount - 1, plan.exits.lastIndex { ids.contains($0.id) } ?? (plan.exits.count - 1))
        let template = plan.exits.indices.contains(index) ? plan.exits[index] : nil
        let exit = PlannedExit(number: 0, duration: template?.duration ?? 30)
        withAnimation(.snappy) {
            plan.exits.insert(exit, at: index + 1)
            plan.renumber()
        }
        selection = [exit.id]
    }

    private func duplicate(_ ids: Set<PlannedExit.ID>) {
        guard let last = plan.exits.lastIndex(where: { ids.contains($0.id) }) else { return }
        let index = max(fixedCount - 1, last)
        let copies = plan.exits.filter { ids.contains($0.id) }.map { source -> PlannedExit in
            var copy = source
            copy.id = UUID()
            return copy
        }
        withAnimation(.snappy) {
            plan.exits.insert(contentsOf: copies, at: index + 1)
            plan.renumber()
        }
        selection = Set(copies.map(\.id))
    }

    private func deleteSelected() { delete(selection) }

    private func delete(_ ids: Set<PlannedExit.ID>) {
        let ids = ids.filter { !isFixed($0) }
        // At least one exit stays: a plan without exits cannot start.
        guard !ids.isEmpty, plan.exits.count > ids.count else { return }
        let next = plan.exits.firstIndex { ids.contains($0.id) }
        withAnimation(.snappy) {
            plan.exits.removeAll { ids.contains($0.id) }
            plan.renumber()
        }
        if let next {
            selection = [plan.exits[min(next, plan.exits.count - 1)].id]
        }
    }

    private func shiftSelection(by delta: Int) {
        let indices = selectedIndices
        guard let first = indices.first, let last = indices.last else { return }
        let destination = delta < 0 ? first - 1 : last + 2
        guard destination >= fixedCount, first >= fixedCount, destination <= plan.exits.count else { return }
        withAnimation(.snappy) {
            plan.exits.move(fromOffsets: IndexSet(indices), toOffset: destination)
            plan.renumber()
        }
    }

    private func move(_ ids: [UUID], to index: Int) {
        let offsets = IndexSet(plan.exits.indices.filter { ids.contains(plan.exits[$0].id) })
        guard !offsets.isEmpty, !ids.contains(where: isFixed) else { return }
        withAnimation(.snappy) {
            plan.exits.move(fromOffsets: offsets, toOffset: min(max(fixedCount, index), plan.exits.count))
            plan.renumber()
        }
        selection = Set(ids)
    }
}

// MARK: - Cells

/// Time behind the door: pink value; click → minutes and seconds or a preset.
private struct ExitDurationCell: View {
    @Binding var exit: PlannedExit
    @State private var editing = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 3) {
                Text(MacPlanFormat.cell(exit.duration))
                    .fontWeight(.semibold)
                    .foregroundStyle(MacPlanTint.exit(scheme))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering || editing ? 1 : 0)
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if DEBUG
        // `--demo-duration-popover N`: the editor of exit N open (screenshots).
        .task {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--demo-duration-popover"), i + 1 < args.count,
                  Int(args[i + 1]) == exit.number else { return }
            try? await Task.sleep(for: .seconds(1))
            editing = true
        }
        #endif
        .help("Выход \(exit.number): \(exit.durationDescription) — изменить")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            MacDurationEditor(value: Binding(get: { exit.duration }, set: { exit.duration = max(0, $0 ?? exit.duration) }),
                              title: String(localized: "Выход \(exit.number) — за дверью"), presets: MacPlanFormat.exitPresets,
                              tint: MacPalette.pink) { editing = false }
        }
    }
}

/// Break after an exit: dimmed «2 мин» follows the plan, a blue «5 мин · свой» is the exit's own break.
private struct BreakAfterCell: View {
    @Binding var exit: PlannedExit
    let defaultBreak: TimeInterval
    let isLast: Bool
    @State private var custom = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if isLast {
            Text("конец").foregroundStyle(.tertiary)
                .help("После последнего выхода тренировка заканчивается")
        } else {
            Menu {
                Toggle("Как у всех — \(DurationText.short(defaultBreak))", isOn: Binding(
                    get: { exit.breakAfter == nil }, set: { if $0 { exit.breakAfter = nil } }))
                Divider()
                ForEach(MacPlanFormat.breakPresets.filter { $0 != defaultBreak }, id: \.self) { preset in
                    Toggle(DurationText.short(preset), isOn: Binding(
                        get: { exit.breakAfter == preset }, set: { if $0 { exit.breakAfter = preset } }))
                }
                Divider()
                Button("Другой…") { custom = true }
            } label: {
                if let own = exit.breakAfter {
                    Text("\(MacPlanFormat.cell(own)) · свой")
                        .fontWeight(.semibold)
                        .foregroundStyle(MacPlanTint.pause(scheme))
                } else {
                    Text(MacPlanFormat.cell(defaultBreak)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .monospacedDigit()
            .fixedSize()
            .help(exit.breakAfter == nil
                  ? "Перерыв после выхода \(exit.number) — как у всех. Выберите, чтобы задать свой"
                  : "Свой перерыв после выхода \(exit.number)")
            .popover(isPresented: $custom, arrowEdge: .bottom) {
                MacDurationEditor(value: Binding(get: { exit.breakAfter },
                                                 set: { exit.breakAfter = $0 == defaultBreak ? nil : $0 }),
                                  title: String(localized: "Перерыв после выхода \(exit.number)"), presets: MacPlanFormat.breakPresets,
                                  defaultValue: defaultBreak, tint: MacPalette.blue) { custom = false }
            }
        }
    }
}
#endif
