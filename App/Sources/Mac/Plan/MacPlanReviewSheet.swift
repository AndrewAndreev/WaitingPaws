#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The plan to check, the sheet over the «Пульт» right after a paste: the trainer's text on the left as she wrote it,
/// the plan made of it on the right — the training's name as the title (edited in place), the trainers, date and
/// common break without labels, the parsed exits as an editable table, the selected exit's triggers, conditions and
/// note under it, «Готово» and «Начать тренировку» in the bottom bar; «Готово» (Esc) and ✕ keep the plan on the «Пульт»
/// without starting. The two sides are linked both ways: every exit line carries its row's number, a selected row
/// lights its lines, a line under the pointer lights its row's number (a click selects the row), a chip or cell under
/// the pointer lights its line. A value the owner changed is white in the table while the text keeps the trainer's
/// words. The text folds away with the sidebar button. During a training the same sheet edits the running schedule («Сохранить»): the
/// exits already done and the current one keep their place (`fixedExits`).
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
    /// The trainer's text beside the table: open unless the owner folded it away.
    @AppStorage("mac.reviewShowsSource") private var showsSource = true
    /// What the pointer is over, on either side.
    @State private var pointer: MacPlanPointer?
    /// The trainer's text's width, dragged by its edge within `sourceWidths` (less where the table would get narrower
    /// than `tableMinWidth`).
    @State private var sourceWidth: CGFloat = 420
    /// The width of the text and the table together.
    @State private var panesWidth: CGFloat = 0
    /// The text has been folded away in this sheet: it stays as wide as with the text.
    @State private var keepsWideWidth = false
    static let sourceWidths: ClosedRange<CGFloat> = 340...620
    static let tableMinWidth: CGFloat = 690

    /// How wide the text may be now: the table keeps its least width.
    private var sourceRange: ClosedRange<CGFloat> {
        let lower = Self.sourceWidths.lowerBound
        guard panesWidth > 0 else { return Self.sourceWidths }
        return lower...max(lower, min(Self.sourceWidths.upperBound, panesWidth - 1 - Self.tableMinWidth))
    }

    init(plan: Binding<TrainingPlan>, fixedExits: Int? = nil, onStart: @escaping () -> Void, onDone: @escaping () -> Void) {
        _plan = plan
        self.fixedExits = fixedExits
        self.onStart = onStart
        self.onDone = onDone
    }

    private var isRunning: Bool { fixedExits != nil }

    var body: some View {
        let lines = MacSourceLine.lines(plan.rawText)
        let link = MacPlanTextLink(plan: plan, lines: lines)
        let source = showsSource && link.hasText
        // The sheet keeps its width once the text has been beside the table (a sheet takes its least width, and AppKit
        // resizes it at once: it narrowed in a jump while the text slid out). Folded away, the text leaves its room to
        // the table.
        let wide = source || keepsWideWidth
        VStack(spacing: 0) {
            header(hasText: link.hasText)
            Divider()
            // Not an `HSplitView`: AppKit's split took the text away and back at once (and made the table anew). Here
            // the text slides out to the left as the table takes its room, and back in, with the sidebar button.
            HStack(spacing: 0) {
                if source {
                    let range = sourceRange
                    PlanSourcePane(link: link, plan: plan, selection: $selection, pointer: $pointer)
                        .frame(width: min(range.upperBound, max(range.lowerBound, sourceWidth)))
                        .transition(.move(edge: .leading))
                    PaneDivider(width: $sourceWidth, range: range)
                        .transition(.move(edge: .leading))
                        // Over the table's edge: the drag area runs a few points into it.
                        .zIndex(1)
                }
                PlanTablePane(plan: $plan, selection: $selection, pointer: $pointer, link: link,
                              fixedCount: fixedExits ?? 0)
                    .frame(minWidth: Self.tableMinWidth, maxWidth: .infinity)
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { panesWidth = $0 }
            bottomBar
        }
        .frame(minWidth: wide ? 1180 : 860, idealWidth: wide ? 1220 : 900, maxWidth: 1600,
               minHeight: 700, maxHeight: 1100)
        #if DEBUG
        .onAppear {
            let args = CommandLine.arguments
            func exit(after flag: String) -> PlannedExit? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                return plan.exits.first { $0.number == n }
            }
            // `--demo-review-select N`: the row of exit N selected (screenshots of the text ↔ table link).
            if let exit = exit(after: "--demo-review-select") { selection = [exit.id] }
            // `--demo-pointer N`: the pointer over exit N (its line lit and its row's number filled).
            if let exit = exit(after: "--demo-pointer") { pointer = .exit(exit.id) }
            // `--demo-review-edit`: exit 6 changed to 2 мин 30 с and exit 2 without its «куртка» (the trainer's words
            // struck through, the owner's value white).
            if args.contains("--demo-review-edit"), plan.exits.count > 5 {
                plan.exits[5].duration = 150
                plan.exits[1].triggers = []
            }
            // `--demo-review-fold`: the trainer's text folds away 3 s after the sheet opens and comes back 3 s later
            // (frames of the slide; the setting ends as it was). The window comes to the front without taking the
            // keyboard: a window under others gets no frames, and a copy launched in the background froze the slide
            // half-way in the captures.
            if args.contains("--demo-review-fold") {
                Task { @MainActor in
                    NSApp.windows.filter(\.isVisible).forEach { $0.orderFrontRegardless() }
                    for _ in 0..<2 {
                        try? await Task.sleep(for: .seconds(3))
                        toggleSource()
                    }
                }
            }
        }
        #endif
    }

    // MARK: Header

    /// The sidebar button that folds the trainer's text, the training's name (the title of the sheet and its field at
    /// once) and, before the start, ✕ to close.
    private func header(hasText: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if hasText {
                Button(action: toggleSource) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(MacIconButtonStyle(isOn: showsSource))
                .help(showsSource ? "Hide Trainer’s Text" : "Show Trainer’s Text")
            }
            if !plan.isValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(MacPalette.orange)
                    .help("No Exits in the Schedule")
            }
            TextField("Name", text: $plan.title, prompt: Text("Training"))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .labelsHidden()
            if !isRunning {
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(MacIconButtonStyle(isOn: true, circle: true))
                // Esc is «Готово»'s, in the bottom bar.
                .help("Close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// The trainer's text away to the left or back, as the «Пульт» panel folds.
    private func toggleSource() {
        if showsSource { keepsWideWidth = true }
        withAnimation(.smooth(duration: 0.35)) { showsSource.toggle() }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        @Bindable var settings = model.settings
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                // The numbers are the rows' and the card's «≈ 25 мин» on the panel.
                Spacer(minLength: 12)
                if isRunning {
                    Button("Cancel|verb", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                        .help("Close without changes · Esc")
                } else {
                    // Whether the training is recorded is this box's; the button only starts it, as on the iPhone.
                    Toggle("Record video", isOn: $settings.autoRecord)
                        .toggleStyle(.checkbox)
                        .help("Record the camera during the training")
                    // Back from before 1.7 (the owners of earlier versions reach for it): the same as ✕, said in words.
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                        .help("Keep the schedule in the main window and adjust it on the timeline · Esc")
                }
                Button(action: onStart) {
                    ShortcutLabel(title: isRunning ? String(localized: "Save") : String(localized: "Start Training"),
                                  symbol: isRunning ? "checkmark" : "play.fill", key: "⌘↩", prominent: true)
                }
                // Pink in any window, the sheet's screenshots included.
                .buttonStyle(MacStartButtonStyle())
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

/// The edge between the trainer's text and the table: the system's thin line, dragged within `range` as the split
/// view's divider was, with the resize pointer over a few points either side of it.
private struct PaneDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// The width when the drag began.
    @State private var start: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let from = start ?? min(range.upperBound, max(range.lowerBound, width))
                            start = from
                            width = min(range.upperBound, max(range.lowerBound, from + drag.translation.width))
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

/// The trainer's text beside the table (`MacTrainerTextView`): the selected rows' lines lit, a line under the pointer
/// lighting its row's number, a click on an exit's line (or a line under it) selecting its row.
private struct PlanSourcePane: View {
    let link: MacPlanTextLink
    let plan: TrainingPlan
    @Binding var selection: Set<PlannedExit.ID>
    @Binding var pointer: MacPlanPointer?

    var body: some View {
        let lit = MacSourceLine.ids(ofExits: Set(selection.compactMap { link.ordinals[$0] }), in: link.lines)
        MacTrainerTextView(link: link, lit: lit,
                           pointed: MacSourceLine.ids(of: pointer, in: link.lines, ordinals: link.ordinals),
                           focus: lit.min(),
                           onHover: { line in pointer = line?.pointer(exitID: link.exitIDs) },
                           onTap: select)
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// A click on an exit's line, or a line under it: that exit's row.
    private func select(_ line: MacSourceLine) {
        guard let ordinal = line.ordinal, let id = link.exitIDs[ordinal], plan.exits.contains(where: { $0.id == id })
        else { return }
        selection = [id]
    }
}

// MARK: - Table

private struct PlanTablePane: View {
    @Binding var plan: TrainingPlan
    @Binding var selection: Set<PlannedExit.ID>
    @Binding var pointer: MacPlanPointer?
    let link: MacPlanTextLink
    /// During a training: the first exits (done or running) stay where they are.
    var fixedCount = 0

    @Environment(\.colorScheme) private var scheme
    @FocusState private var tableFocused: Bool
    @State private var customDefaultBreak = false
    /// The own breaks «Сделать все по 2 мин» took away, for «Вернуть».
    @State private var takenBreaks: [UUID: TimeInterval] = [:]

    private static let dragPrefix = "waitingpaws.exit:"

    private var ownBreaks: [PlannedExit] { plan.ownBreakExits }

    private var selectedIndices: [Int] {
        plan.exits.indices.filter { selection.contains(plan.exits[$0].id) }
    }

    /// The pointer over `target` here, or off it.
    private func point(_ target: MacPlanPointer, _ inside: Bool) {
        if inside { pointer = target } else if pointer == target { pointer = nil }
    }

    /// The exit's row is what the pointer is over, here or in the text.
    private func pointsAt(_ exit: PlannedExit) -> Bool {
        pointer == .exit(exit.id) || pointer == .breakAfter(exit.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            planForm
            if !plan.commonEarlyEntries.isEmpty {
                Divider()
                commonEntriesBar
            }
            Divider()
            table
            Divider()
            tableFooter
            if selection.count == 1, let id = selection.first, plan.exits.contains(where: { $0.id == id }) {
                Divider()
                MacExitInspector(plan: $plan, exitID: id)
            }
        }
    }

    // MARK: Header fields

    /// One row without labels — the field's prompt, the calendar and ⏸ say what each is: the trainers, the date, the
    /// common break, then the trainer's rules for the whole training as chips. The own breaks are blue in the table.
    private var planForm: some View {
        HStack(spacing: 10) {
            TextField("Trainers", text: $plan.trainers, prompt: Text("Trainers"))
                .labelsHidden()
                .frame(maxWidth: 260)
            PlanDateField(date: $plan.date)
            defaultBreakMenu
                .overlay {
                    if pointer == .commonBreak {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(MacPlanTint.pause(scheme).opacity(0.8), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .onHover { point(.commonBreak, $0) }
            ForEach(ruleChips, id: \.title) { chip in
                let lit = chip.pointer.map { $0 == pointer } ?? false
                Label(chip.title, systemImage: chip.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(chip.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(chip.tint.opacity(lit ? 0.3 : 0.12), in: Capsule())
                    .help(chip.help)
                    .fixedSize()
                    .onHover { inside in if let target = chip.pointer { point(target, inside) } }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// «после 3-го — 5 мин, после 5-го — 1 мин».
    private func breaksList(_ breaks: [(number: Int, value: TimeInterval)]) -> String {
        breaks.map { String(localized: "after #\($0.number) — \(DurationText.short($0.value))") }.joined(separator: ", ")
    }

    /// «Свой перерыв: после 6-го — 5 мин».
    private var ownBreaksTitle: String {
        let list = breaksList(ownBreaks.map { ($0.number, $0.breakAfter ?? 0) })
        return ownBreaks.count == 1 ? String(localized: "Custom breaks: \(list)|one") : String(localized: "Custom breaks: \(list)")
    }

    /// The own breaks «Сделать все по …» took away that are still common now.
    private var restorableBreaks: [(number: Int, value: TimeInterval)] {
        plan.exits.compactMap { exit in
            guard exit.breakAfter == nil, let value = takenBreaks[exit.id], value != plan.defaultBreak else { return nil }
            return (exit.number, value)
        }
    }

    private func restoreBreaks() {
        plan.restoreOwnBreaks(takenBreaks)
        takenBreaks = [:]
    }

    /// Break between exits: presets, the current value if it is not one of them, «Другой…», and under the own breaks
    /// it would take away, «Сделать все по 2 мин».
    private var defaultBreakMenu: some View {
        Menu {
            let presets = MacPlanFormat.breakPresets
            ForEach(presets.contains(plan.defaultBreak) ? presets : (presets + [plan.defaultBreak]).sorted(), id: \.self) { value in
                Toggle(DurationText.short(value), isOn: Binding(
                    get: { plan.defaultBreak == value }, set: { if $0 { setDefaultBreak(value) } }))
            }
            Divider()
            Button("Custom…") { customDefaultBreak = true }
            if !ownBreaks.isEmpty {
                Divider()
                Section(ownBreaksTitle) {
                    Button("Set All to \(DurationText.short(plan.defaultBreak))") {
                        withAnimation(.snappy) { takenBreaks = plan.makeBreaksCommon() }
                    }
                }
            } else if !restorableBreaks.isEmpty {
                Divider()
                Button("Restore: \(breaksList(restorableBreaks))") {
                    withAnimation(.snappy) { restoreBreaks() }
                }
            }
        } label: {
            Label { Text(verbatim: DurationText.short(plan.defaultBreak)).monospacedDigit() } icon: {
                Image(systemName: "pause.fill")
            }
        }
        .fixedSize()
        .help("Break between exits — for every exit except those with their own break")
        .popover(isPresented: $customDefaultBreak, arrowEdge: .bottom) {
            MacDurationEditor(value: Binding(get: { plan.defaultBreak }, set: { setDefaultBreak($0 ?? plan.defaultBreak) }),
                              title: String(localized: "Break Between Exits"), presets: MacPlanFormat.breakPresets,
                              tint: MacPalette.blue) { customDefaultBreak = false }
        }
    }

    /// A new common break; own breaks that now equal it become common again (as `PlanParser` reads them).
    private func setDefaultBreak(_ value: TimeInterval) {
        plan.setDefaultBreak(value)
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
            // The exit's badge, as at its line in the trainer's text (a plain number: added here, not in the text).
            TableColumn("№") { exit in
                HStack(spacing: 3) {
                    if isFixed(exit.id) {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    if link.ordinals[exit.id] != nil {
                        MacExitBadge(number: exit.number, filled: pointsAt(exit) || selection.contains(exit.id))
                    } else {
                        Text("\(exit.number)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { point(.exit(exit.id), $0) }
                .help(isFixed(exit.id) ? String(localized: "This exit is done or running: it can be changed, but not removed or moved") : "")
            }
            .width(fixedCount > 0 ? 42 : 30)
            TableColumn("Outside") { exit in
                ExitDurationCell(exit: binding(exit), trainerValue: link.trainerDuration(of: exit)) { point(.exit(exit.id), $0) }
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Break After") { exit in
                BreakAfterCell(exit: binding(exit), defaultBreak: plan.defaultBreak,
                               isLast: exit.id == plan.exits.last?.id,
                               trainerValue: link.trainerBreak(after: exit)) { point(.breakAfter(exit.id), $0) }
            }
            .width(min: 104, ideal: 130, max: 170)
            // ⚡ 🏃 💬 in the cells say which is which.
            TableColumn("Conditions") { exit in
                ExitSummaryText(plan: plan, exit: exit, size: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { point(.exit(exit.id), $0) }
                    .help(summaryHelp(exit))
            }
            .width(min: 150, ideal: 300)
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
        // No stripes: AppKit draws them on below the last exit too, as empty rows that read as data still loading.
        // The table ends at its last exit.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .onDeleteCommand(perform: deleteSelected)
        .contextMenu(forSelectionType: PlannedExit.ID.self) { ids in
            if !ids.isEmpty {
                Button("Duplicate") { duplicate(ids) }
                Button("Add Exit Below") { add(after: ids) }
                Divider()
                Button("Delete", role: .destructive) { delete(ids) }
            } else {
                Button("Add Exit") { add(after: []) }
            }
        }
    }

    // Classic +/− bar under a table (System Settings, Finder).
    private var tableFooter: some View {
        let hasSelection = !selection.isEmpty
        return HStack(spacing: 2) {
            footerButton("plus", String(localized: "Add exit · ⌘N")) { add(after: selection) }
                .keyboardShortcut("n", modifiers: .command)
            footerButton("minus", String(localized: "Delete selected · ⌫")) { deleteSelected() }
                .disabled(!hasSelection || plan.exits.count <= selection.count)
            Divider().frame(height: 14).padding(.horizontal, 6)
            footerButton("plus.square.on.square", String(localized: "Duplicate · ⌘D")) { duplicate(selection) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!hasSelection)
            footerButton("arrow.up", String(localized: "Move up · ⌥⌘↑")) { shiftSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selectedIndices.first.map { $0 == 0 } ?? true)
            footerButton("arrow.down", String(localized: "Move down · ⌥⌘↓")) { shiftSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selectedIndices.last.map { $0 == plan.exits.count - 1 } ?? true)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private func footerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    /// The common conditions the trainer wrote for the whole training, in the card's words («встала и пошла 1:00 ·
    /// легла 0:20»), and the exits they go to.
    private var commonEntriesBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.run").foregroundStyle(MacPalette.orange)
            Text(verbatim: plan.commonEarlyEntries.map(Self.words).joined(separator: " · "))
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("Which exits", selection: Binding(
                get: { plan.commonEntriesScope.map { $0 == .all ? 0 : 1 } ?? 2 },
                set: { choice in
                    withAnimation(.snappy) {
                        if choice == 0 { plan.applyCommonEarlyEntries(to: .all) }
                        if choice == 1 { plan.applyCommonEarlyEntries(to: .long) }
                    }
                })) {
                Text("All exits").tag(0)
                Text("Long ones ≥ 1 min").tag(1)
                Text("Choose").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("“Pick”: tick “Common conditions” on the exits you want below")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MacPalette.orange.opacity(pointer == .commonConditions ? 0.24 : 0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { point(.commonConditions, $0) }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// «встала и пошла 1:00», «легла сразу»: the trainer's words and the time, without an arrow.
    static func words(_ entry: EarlyEntry) -> String {
        let name = entry.event.prefix(1).lowercased() + entry.event.dropFirst()
        let time = entry.delay.flatMap { $0 > 0 ? DurationText.clock($0) : nil } ?? entry.unreadDelay
            ?? String(localized: "right away")
        return "\(name) \(time)"
    }

    private struct RuleChip {
        let title: String
        let symbol: String
        let tint: Color
        let help: String
        var pointer: MacPlanPointer? = nil
    }

    /// «⊖ Ждать тишины 30 с» (the trainer's 🚩, what it asks) and «🔖 фальстарт»: the trainer's rules for the whole
    /// training. Its other notes («Все перерывы 2 минуты», «В перерывах сидите за столом») are in «Текст тренера», the
    /// break in «⏸ 2 мин»: no chip that only counts them.
    private var ruleChips: [RuleChip] {
        plan.notes.compactMap { note in
            if PlanParser.isDoNotEnterRule(note) {
                return RuleChip(title: MacPlanFormat.quietRuleTitle(plan), symbol: "minus.circle.fill",
                                tint: MacPalette.red, help: PlanParser.stripDecorations(note), pointer: .quietRule)
            }
            if PlanParser.isFalseStartRule(note.lowercased()) {
                return RuleChip(title: String(localized: "false start"), symbol: "bookmark.fill", tint: MacPlanTint.rule(scheme),
                                help: note)
            }
            return nil
        }
    }

    /// The summary in full, for the tooltip.
    private func summaryHelp(_ exit: PlannedExit) -> String {
        var parts: [String] = []
        if !exit.triggers.isEmpty { parts.append("⚡ " + exit.triggers.joined(separator: " · ")) }
        let entries = plan.earlyEntries(of: exit)
        if !entries.isEmpty { parts.append("🏃 " + entries.map(\.summary).joined(separator: " · ")) }
        if let note = exit.noteText { parts.append("📝 " + note) }
        return parts.isEmpty ? String(localized: "Select the row to add triggers, conditions and a note") : parts.joined(separator: "\n")
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
            // The owner's, not the trainer's: no line of the text.
            copy.sourceIndex = nil
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

/// The schedule's date as the iPhone and the history write it — «Вс, 4 окт.», the year only when it is not this one —
/// not «04.10.2026»; a click opens the calendar.
private struct PlanDateField: View {
    @Binding var date: Date?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(verbatim: HistoryDate.day(date ?? Date()))
                    .monospacedDigit()
            }
        }
        .fixedSize()
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            // A day picked is the answer: the calendar closes (the arrows between months keep it open).
            DatePicker("Date", selection: Binding(get: { date ?? Date() }, set: { date = $0; picking = false }),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .padding(12)
        }
    }
}

/// Time behind the door: pink value; click → minutes and seconds or a preset.
private struct ExitDurationCell: View {
    @Binding var exit: PlannedExit
    /// The trainer's time, when the exit came from her text: a value changed from it is white, not pink.
    var trainerValue: TimeInterval?
    var onPoint: (Bool) -> Void = { _ in }
    @State private var editing = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var edited: Bool { trainerValue.map { $0 != exit.duration } ?? false }

    private var help: String {
        let value = String(localized: "Exit \(exit.number) · \(exit.durationDescription)")
        guard edited, let trainerValue else { return value }
        return String(localized: "\(value) · trainer wrote \(DurationText.short(trainerValue))")
    }

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 3) {
                Text(MacPlanFormat.cell(exit.duration))
                    .fontWeight(.semibold)
                    .foregroundStyle(edited ? Color.primary : MacPlanTint.exit(scheme))
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
        .onHover {
            hovering = $0
            onPoint($0)
        }
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
        .help(help)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            MacDurationEditor(value: Binding(get: { exit.duration }, set: { exit.duration = max(0, $0 ?? exit.duration) }),
                              title: String(localized: "Exit \(exit.number) — Outside"), presets: MacPlanFormat.exitPresets,
                              tint: MacPalette.pink) { editing = false }
        }
    }
}

/// Break after an exit: a quiet «—» follows the common break (a click sets one of its own), a blue «5 мин ⌄» is the
/// exit's own break; nothing after the last exit.
private struct BreakAfterCell: View {
    @Binding var exit: PlannedExit
    let defaultBreak: TimeInterval
    let isLast: Bool
    /// The trainer's break after this exit (her common one when she gave it none of its own).
    var trainerValue: TimeInterval?
    var onPoint: (Bool) -> Void = { _ in }
    @State private var custom = false
    @Environment(\.colorScheme) private var scheme

    private var value: TimeInterval { exit.breakAfter ?? defaultBreak }
    private var edited: Bool { trainerValue.map { $0 != value } ?? false }

    private var help: String {
        let base = exit.breakAfter == nil
            ? String(localized: "Break after exit \(exit.number) — default. Choose a value to give it its own break")
            : String(localized: "Own break after exit \(exit.number)")
        guard edited, let trainerValue else { return base }
        return String(localized: "\(base) · trainer wrote \(DurationText.short(trainerValue))")
    }

    var body: some View {
        if isLast {
            // After the last exit the training ends: nothing to set.
            Color.clear.frame(width: 1, height: 1)
        } else {
            Menu {
                Toggle("Default — \(DurationText.short(defaultBreak))", isOn: Binding(
                    get: { exit.breakAfter == nil }, set: { if $0 { exit.breakAfter = nil } }))
                Divider()
                ForEach(MacPlanFormat.breakPresets.filter { $0 != defaultBreak }, id: \.self) { preset in
                    Toggle(DurationText.short(preset), isOn: Binding(
                        get: { exit.breakAfter == preset }, set: { if $0 { exit.breakAfter = preset } }))
                }
                Divider()
                Button("Custom…") { custom = true }
            } label: {
                if let own = exit.breakAfter {
                    // Blue says it is the exit's own; white, that the owner set it, not the trainer.
                    Text(verbatim: MacPlanFormat.cell(own))
                        .fontWeight(.semibold)
                        .foregroundStyle(edited ? Color.primary : MacPlanTint.pause(scheme))
                } else {
                    // The common break is the header's «⏸ 2 мин»: here only a quiet dash to click.
                    Text(verbatim: "—").foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(exit.breakAfter == nil ? .hidden : .visible)
            .monospacedDigit()
            .fixedSize()
            .help(help)
            .onHover(perform: onPoint)
            .popover(isPresented: $custom, arrowEdge: .bottom) {
                MacDurationEditor(value: Binding(get: { exit.breakAfter },
                                                 set: { exit.breakAfter = $0 == defaultBreak ? nil : $0 }),
                                  title: String(localized: "Break After Exit \(exit.number)"), presets: MacPlanFormat.breakPresets,
                                  defaultValue: defaultBreak, tint: MacPalette.blue) { custom = false }
            }
        }
    }
}
#endif
