import SwiftUI
import WaitingPawsCore

/// Review and correct the parsed plan before starting — or, with `fixedExits`, the running training's schedule
/// («Сохранить»; the exits already done and the current one can be changed but not removed or moved).
struct PlanEditorView: View {
    @Environment(AppModel.self) private var model
    @State var plan: TrainingPlan
    /// During a training: how many exits from the start are done or running.
    var fixedExits: Int? = nil
    var onStart: (TrainingPlan) -> Void

    private var isRunning: Bool { fixedExits != nil }

    @State private var showDetails = false
    /// The exit row unfolded into its editors (one at a time); the others read as the overview.
    @State private var expandedExit: UUID?
    /// The exit open in «Выход N».
    @State private var editingExit: EditedExit?
    /// «Выбрать»: which exits get the common conditions.
    @State private var pickingCommonExits = false
    /// The own breaks «Сделать все по 2 мин» in the break menu took away, for «Вернуть».
    @State private var takenBreaks: [UUID: TimeInterval] = [:]
    /// «Другой…» in the break menu: any time on the wheels.
    @State private var customBreak = false
    /// «Текст тренера» open over the plan.
    @State private var showSource = false
    /// An exit's line tapped in the trainer's text: the exit to bring into view once the text has closed.
    @State private var jumpToExit: UUID?

    private struct EditedExit: Identifiable {
        let id: UUID
    }
    #if os(iOS) && DEBUG
    // `--demo-plan-edit` opens the editor in edit mode (layout checks without tapping).
    @State private var editMode: EditMode = CommandLine.arguments.contains("--demo-plan-edit") ? .active : .inactive
    #elseif os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    /// Exits whose break is set on its own instead of following «Перерывы».
    private var ownBreaks: [PlannedExit] { plan.ownBreakExits }

    /// "после 2 — 3 мин, после 5 — 1 мин".
    private func breaksList(_ breaks: [(number: Int, value: TimeInterval)]) -> String {
        breaks.map { String(localized: "after \($0.number) — \(DurationText.short($0.value))") }
            .joined(separator: ", ")
    }

    /// «Свой перерыв: после 6 — 5 мин»: the exceptions to the common break, named.
    private var ownBreaksTitle: String {
        let list = breaksList(ownBreaks.map { ($0.number, $0.breakAfter ?? 0) })
        return ownBreaks.count == 1 ? String(localized: "Custom breaks: \(list)|one") : String(localized: "Custom breaks: \(list)")
    }

    /// The own breaks «Сделать все по …» took away that are still common now: what «Вернуть» gives back.
    private var restorableBreaks: [(number: Int, value: TimeInterval)] {
        plan.exits.compactMap { exit in
            guard exit.breakAfter == nil, let value = takenBreaks[exit.id], value != plan.defaultBreak else { return nil }
            return (exit.number, value)
        }
    }

    /// The trainer's rules for the whole training (⛔ «ждать тишины», 🔖 «фальстарт»): each on its own row.
    private var ruleNotes: [String] {
        plan.notes.filter { PlanParser.isDoNotEnterRule($0) || PlanParser.isFalseStartRule($0.lowercased()) }
    }

    /// A rule's row says what it asks — «Ждать тишины 30 с» — and the trainer's own words under it: «🚩 Если залаяла,
    /// завыла — ждём…».
    private func ruleTitle(_ note: String) -> String? {
        guard PlanParser.isDoNotEnterRule(note) else { return nil }
        if let quiet = plan.doNotEnterRule?.quietTime {
            return String(localized: "Wait for quiet \(DurationText.short(quiet))")
        }
        return String(localized: "Wait for quiet")
    }

    /// The training's name, without the spaces round it.
    private var titleText: String { plan.title.trimmingCharacters(in: .whitespaces) }

    /// «Вс, 4 окт.» as in the history, the year only when it is not this one; and who trains.
    private var subtitle: String {
        [plan.date.map(HistoryDate.day), plan.trainers.isEmpty ? nil : plan.trainers]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "≈ 25 мин": the whole training with its breaks, not the time behind the door; seconds dropped from ten minutes
    /// up. «с перерывами» after it went (design council, round 12): the list over it has the breaks.
    private var totalText: String {
        let total = DurationText.wholeSeconds(plan.estimatedDuration)
        return total >= 600 ? String(localized: "≈ \(Int((Double(total) / 60).rounded())) min")
                            : "≈ " + DurationText.short(plan.estimatedDuration)
    }

    #if os(iOS)
    private var isReordering: Bool { editMode.isEditing }
    #else
    private let isReordering = false
    #endif

    private func toggle(_ exit: PlannedExit) {
        guard !isReordering else { return }
        withAnimation(.smooth(duration: 0.25)) { expandedExit = expandedExit == exit.id ? nil : exit.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
            #if DEBUG
            .task { await applyDemo(proxy) }
            #endif
            // The trainer's text; a tap on an exit's line closes it on that exit's row, unfolded.
            .sheet(isPresented: $showSource, onDismiss: { jump(proxy) }) {
                NavigationStack {
                    TrainerSourceView(plan: plan, highlighted: expandedExit, onJump: { id in
                        jumpToExit = id
                        showSource = false
                    })
                }
                .sheetFrame(width: 560, height: 720)
            }
        }
        // On the bottom panel's colour: the rows fade into it under the panel's soft edge.
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        #if os(iOS)
        // The title bar covers the rows that scroll under it, on the screen's own colour (GPT, round 14: «Ждать тишины»
        // showed through behind the name and the buttons).
        .modifier(HardTopEdge())
        .toolbarBackground(Theme.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        #if DEBUG
        .onAppear { print("[perf] PlanEditorView appear at", PerformanceMonitor.timeFormatter.string(from: Date())) }
        #endif
        // The training's name, as the trainer titled it (design council, round 13: «Проверьте план» said what to do).
        .navigationTitle(isRunning ? String(localized: "Schedule") : (titleText.isEmpty ? String(localized: "Review Plan") : titleText))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Linked to a Mac: the parsed schedule and every edit show up there too (start from either side).
        .task(id: plan) {
            guard !isRunning else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            model.sharePlanWithMac(plan)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        #if os(iOS)
        .environment(\.editMode, $editMode)
        // The list's edit mode, as Apple's lists edit: handles for the order, ⊖ for deletion (also a swipe on the row)
        // — instead of a row «Изменить порядок» under the exits (design council, round 12). A sign, not «Править»: the
        // training's name in the title needs the room (round 13).
        .toolbar {
            if plan.exits.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation {
                            expandedExit = nil
                            editMode = isReordering ? .inactive : .active
                        }
                    } label: {
                        Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(isReordering ? String(localized: "Done") : String(localized: "Reorder"))
                }
            }
        }
        #endif
        .sheet(item: $editingExit) { edited in
            NavigationStack {
                ExitEditorView(plan: $plan, exitID: edited.id)
            }
            .sheetFrame(width: 520, height: 640)
        }
        .sheet(isPresented: $pickingCommonExits) {
            NavigationStack {
                CommonExitsPicker(plan: $plan)
            }
            .sheetFrame(width: 420, height: 520)
        }
    }

    /// The overview: what the plan is, the common break, the trainer's rules and notes — one short card, tighter rows
    /// than a list's own — then the exits, each with what is its own beside it: its own break («⏸ 5 мин»), «или
    /// до вставания», its conditions (GPT, round 7: the card took half the screen, and «Ранний вход: выходы 6 и 8» in
    /// it named the exceptions without saying them, far from the exits; now the exceptions live only on their rows).
    private func list(_ proxy: ScrollViewProxy) -> some View {
        // The trainer's text matched to the plan, once for all the rows.
        let source = TrainerSource(plan)
        let trailingNotes = Self.paragraphs(notes(after: true, source))
        return List {
            Section {
                DisclosureGroup(isExpanded: $showDetails) {
                    TextField("Name", text: $plan.title)
                    TextField("Who’s training", text: $plan.trainers)
                    DatePicker("Date", selection: Binding(
                        get: { plan.date ?? Date() },
                        set: { plan.date = $0 }), displayedComponents: .date)
                } label: {
                    // The name is the screen's title (design council, round 13): here the day and who trains, and
                    // under it the fields for all three; the trainer's head line they were read from under the row.
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(subtitle.isEmpty ? String(localized: "Date") : subtitle)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            let header = source.words(.header, in: plan)
                            if !header.isEmpty { TrainerQuote(lines: header) }
                        }
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                // The rest in the order of the trainer's text, each row with her words under it: her notes before the
                // exits where she wrote them (owner, 05.11.2026: the text is the owner's own input and the way to check
                // the plan — round 12 had put it out of sight behind «Текст тренера»), the common break, her rules.
                ForEach(cardRows(source)) { row in
                    switch row {
                    case .breaks: breaksRow(source)
                    case .rule(let note): ruleRow(note, source: source)
                    case .note(let lines): noteRow(lines)
                    }
                }
                // The whole text, to read it as she wrote it (Fable, round 8: on the Mac it stands beside the table).
                if hasSource {
                    sourceRow
                }
            }
            .compactPlanRow()
            // The card's rows that unfold with the same quiet chevron as «Текст тренера ›» and the exits' rows (Fable,
            // round 13: a bold one beside a thin one).
            .disclosureGroupStyle(QuietDisclosureStyle())
            .labelStyle(PlanCardLabelStyle())

            if !plan.commonEarlyEntries.isEmpty {
                commonEntriesCard(source)
            }

            Section {
                // A new time through the row keeps «к длинным» / «ко всем».
                ForEach(Array($plan.keepingCommonEntriesScope.exits.enumerated()), id: \.element.id) { index, $exit in
                    let id = exit.id
                    let fixed = index < (fixedExits ?? 0)
                    ExitRow(exit: $exit, plan: plan, defaultBreak: plan.defaultBreak, isLast: index == plan.exits.count - 1,
                            words: source.words(of: exit, in: plan), beyondWords: source.beyondWords(of: exit, in: plan),
                            isExpanded: expandedExit == id,
                            onToggle: { toggle(exit) },
                            onEdit: { editingExit = EditedExit(id: id) },
                            onDelete: fixed ? nil : {
                                withAnimation {
                                    plan.exits.removeAll { $0.id == id }
                                    plan.renumber()
                                }
                            })
                    .deleteDisabled(fixed)
                    .moveDisabled(fixed)
                    .id(id)
                }
                .onDelete { offsets in
                    plan.exits.remove(atOffsets: offsets.filteredIndexSet { $0 >= (fixedExits ?? 0) })
                    plan.renumber()
                }
                .onMove { source, destination in
                    guard destination >= (fixedExits ?? 0) else { return }
                    plan.exits.move(fromOffsets: source, toOffset: destination)
                    plan.renumber()
                }
                Button {
                    let old = plan
                    plan.exits.append(PlannedExit(number: plan.exits.count + 1, duration: old.exits.last?.duration ?? 5))
                    plan = plan.keepingCommonEntriesScope(from: old)
                } label: {
                    Label("Add Exit", systemImage: "plus.circle.fill")
                }
                .id(Self.endID)
            } header: {
                HStack {
                    Text("Exits · \(plan.exits.count)")
                    Spacer()
                    Text(totalText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            // The trainer's notes among and after the exits, where she wrote them («Если при возвращении с 6 выхода
            // понимаешь, что она проспала его…»).
            if !trailingNotes.isEmpty {
                Section {
                    ForEach(trailingNotes, id: \.first?.id) { lines in
                        noteRow(lines).id(lines.first?.id == trailingNotes.last?.first?.id ? Self.notesEndID : "note \(lines.first?.id ?? 0)")
                    }
                }
                .compactPlanRow()
                .labelStyle(PlanCardLabelStyle())
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        // The plan card right under the title, not a screen's worth of air below it.
        .contentMargins(.top, 8, for: .scrollContent)
        #endif
    }

    private static let endID = "plan-end"
    private static let notesEndID = "plan-notes-end"

    /// «Перерывы  2 мин ⌃⌄», one line, and the trainer's «Все перерывы 2 минуты» under it: the exits that have their own
    /// say so on their rows («⏸ 5 мин»). The menu sets the common break; «Сделать все по 2 мин» sits in it under the
    /// exceptions it would take away («Свой перерыв: после 6 — 5 мин»), and «Вернуть» right under the row brings them
    /// back.
    private func breaksRow(_ source: TrainerSource) -> some View {
        let restorable = restorableBreaks
        let words = source.words(.commonBreak, in: plan)
        return Label {
          VStack(alignment: .leading, spacing: 5) {
            Menu {
                let presets = DurationPresets.breaks
                ForEach(presets.contains(plan.defaultBreak) ? presets : (presets + [plan.defaultBreak]).sorted(), id: \.self) { value in
                    Toggle(DurationText.short(value), isOn: Binding(
                        get: { plan.defaultBreak == value }, set: { if $0 { setDefaultBreak(value) } }))
                }
                Divider()
                Button("Custom…", systemImage: "timer") { customBreak = true }
                if !ownBreaks.isEmpty {
                    Section(ownBreaksTitle) {
                        Button("Set All to \(DurationText.short(plan.defaultBreak))", systemImage: "equal.circle") {
                            makeBreaksCommon()
                        }
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // «Перерывы»: the list under it says between what (design council, round 12).
                    Text("Breaks")
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(DurationText.short(plan.defaultBreak)).monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.secondary)
                    .fixedSize()
                }
                // A menu centres its label's lines; the row reads from the left like the others.
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .accessibilityValue(ownBreaks.isEmpty ? DurationText.short(plan.defaultBreak)
                                                  : "\(DurationText.short(plan.defaultBreak)); \(ownBreaksTitle)")
            if !words.isEmpty { TrainerQuote(lines: words) }
            if ownBreaks.isEmpty, !restorable.isEmpty {
                // Under the row's words.
                Button {
                    withAnimation { restoreBreaks() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Restore: \(breaksList(restorable))")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
                .padding(.top, 3)
            }
          }
        } icon: {
            Image(systemName: "pause.circle")
        }
        .popover(isPresented: $customBreak) {
            DurationEditor(value: Binding(get: { plan.defaultBreak }, set: { setDefaultBreak($0 ?? plan.defaultBreak) }),
                           title: String(localized: "Breaks"), presets: DurationPresets.breaks,
                           defaultValue: nil, secondsStep: 5)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func setDefaultBreak(_ value: TimeInterval) {
        plan.setDefaultBreak(value)
    }

    /// «Сделать все по 2 мин»: the own breaks go, and are kept for «Вернуть».
    private func makeBreaksCommon() {
        withAnimation {
            takenBreaks = plan.makeBreaksCommon()
        }
    }

    private func restoreBreaks() {
        plan.restoreOwnBreaks(takenBreaks)
        takenBreaks = [:]
    }

    #if DEBUG
    private func applyDemoChanges() {
        func edit(_ number: Int, _ change: (inout PlannedExit) -> Void) {
            guard let index = plan.exits.firstIndex(where: { $0.number == number }) else { return }
            change(&plan.exits[index])
        }
        plan.setDefaultBreak(180)
        edit(4) { $0.duration += 30 }
        edit(2) { $0.triggers = [] }
        edit(6) { exit in
            exit.breakAfter = 240
            if let lying = exit.earlyEntries.firstIndex(where: { $0.event.lowercased().hasPrefix("легла") }) {
                exit.earlyEntries[lying].delay = 60
            }
        }
    }

    /// `--demo-exit-editor <n>` opens «Выход n», `--demo-plan-expand <n>` unfolds its row and `--demo-plan-end` scrolls
    /// to the bottom (UI checks without tapping).
    private func applyDemo(_ proxy: ScrollViewProxy) async {
        func demoExit(after flag: String) -> PlannedExit? {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: flag), index + 1 < args.count, let number = Int(args[index + 1]) else { return nil }
            return plan.exits.first { $0.number == number }
        }
        if let exit = demoExit(after: "--demo-plan-expand") { expandedExit = exit.id }
        // `--demo-plan-changed`: the owner's own changes against the trainer's words — exit 4 half a minute longer, exit 2
        // without its trigger, exit 6's «легла» a minute and its break 4 min, the common break 3 min.
        if CommandLine.arguments.contains("--demo-plan-changed") { applyDemoChanges() }
        // `--demo-plan-breaks-common`: «Сделать все по …» from the break menu done, «Вернуть» showing.
        if CommandLine.arguments.contains("--demo-plan-breaks-common") { takenBreaks = plan.makeBreaksCommon() }
        try? await Task.sleep(for: .seconds(1))
        if CommandLine.arguments.contains("--demo-plan-end") { proxy.scrollTo(Self.endID, anchor: .bottom) }
        // `--demo-plan-notes`: down to the trainer's notes after the exits.
        if CommandLine.arguments.contains("--demo-plan-notes") { proxy.scrollTo(Self.notesEndID, anchor: .bottom) }
        if let exit = demoExit(after: "--demo-exit-editor") { editingExit = EditedExit(id: exit.id) }
        // `--demo-plan-details`: the name, the trainers and the date unfolded; `--demo-plan-source`: the trainer's text
        // open.
        if CommandLine.arguments.contains("--demo-plan-details") { showDetails = true }
        if CommandLine.arguments.contains("--demo-plan-source") { showSource = true }
        // `--demo-plan-jump <n>`: then exit n's line tapped in it, after a moment.
        if let exit = demoExit(after: "--demo-plan-jump") {
            try? await Task.sleep(for: .seconds(2))
            jumpToExit = exit.id
            showSource = false
        }
    }
    #endif

    /// Toggle «Записывать видео» and the start, on the panel's own colour: the rows that scroll under it blur and fade
    /// into it over a soft edge above the toggle (as under a system bottom bar, and as in the camera picker) instead of
    /// ending at a hard line. The list's last row ends above that edge.
    private var bottomPanel: some View {
        @Bindable var settings = model.settings
        return VStack(spacing: 10) {
            // Why «Начать тренировку» / «Сохранить» below is greyed out.
            if !plan.isValid {
                Label("No Exits in the Schedule", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isRunning {
                BigButton(title: String(localized: "Save"), systemImage: "checkmark", height: 50) {
                    var final = plan
                    final.renumber()
                    onStart(final)
                }
                .disabled(!plan.isValid)
            } else if model.isLinkedToMac {
                // Recording follows the Mac's setting there.
                Label("This schedule is on the \(model.linkedHostKind) too — start it there or here.", systemImage: "laptopcomputer.and.iphone")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Theme.info)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Toggle(isOn: $settings.autoRecord) {
                    Label("Record video", systemImage: "record.circle")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .tint(Theme.accent)
            }
            if !isRunning {
                // «Начать тренировку» alone: the switch right above it says whether the recording starts too (design
                // council, round 12: «и запись» said it again).
                BigButton(title: String(localized: "Start Training"), systemImage: "play.fill", height: 50) {
                    var final = plan
                    final.renumber()
                    onStart(final)
                }
                .disabled(!plan.isValid)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, Self.panelFade)
        .padding(.bottom, 8)
        .background {
            BottomBarBacking(color: Theme.panel, opacity: 1, fade: Self.panelFade)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The soft edge over the bottom panel.
    private static let panelFade: CGFloat = 22

    /// ⛔: «Ждать тишины 30 с»; 🔖: the trainer's head word, «Фальстарт»; and under it the trainer's own line, always
    /// in sight (owner, 05.11.2026; Fable, round 8, had put it behind a disclosure): «🚩 Если залаяла, завыла - ждём,
    /// входим когда молчала 30 секунд», the quiet she asks in red.
    private func ruleRow(_ note: String, source: TrainerSource) -> some View {
        let (symbol, tint) = ruleIcon(note)
        let line = source.lines.first { [.doNotEnter, .falseStart].contains($0.role) && Self.isRule(note, line: $0) }
        let words = line.map { source.text($0, plan: plan, exit: nil, style: .quote) }
            ?? TrainerWords.plain(note)
        return Label {
            VStack(alignment: .leading, spacing: 5) {
                // What it asks, and no «все выходы» beside it (design council, round 12): a rule is for every exit.
                Text(ruleHead(note)).lineLimit(1)
                TrainerQuote(lines: [words])
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    /// The row's title: «Ждать тишины 30 с»; the head word before a colon, «Фальстарт»; else the rule's first words.
    private func ruleHead(_ note: String) -> String {
        if let title = ruleTitle(note) { return title }
        let words = PlanParser.stripDecorations(note)
        if let colon = words.firstIndex(of: ":"), words.distance(from: words.startIndex, to: colon) <= 24 {
            return String(words[..<colon])
        }
        return words
    }

    /// The note `parse` kept is the trainer's line without its decorations (a 🚩 put back in front).
    private static func isRule(_ note: String, line: PlanParser.SourceLine) -> Bool {
        PlanParser.stripDecorations(note) == PlanParser.stripDecorations(line.text)
    }

    /// A note of the trainer's that the plan took nothing from — the lines of one paragraph together: her words alone,
    /// by the note's sign, where she wrote them.
    private func noteRow(_ lines: [PlanParser.SourceLine]) -> some View {
        Label {
            TrainerQuote(lines: lines.map { TrainerWords.text($0, plan: plan, exit: nil, style: .quote) })
                // The row's line under it starts where the other rows' do.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } icon: {
            // Grey, not the tint's grey: the plan took nothing from it.
            Image(systemName: "text.bubble").foregroundStyle(Color.secondary)
        }
    }

    /// The card's rows after the date, in the order of the trainer's text: her notes before the first exit, the common
    /// break («Перерывы» first when she names none), her rules wherever she wrote them (they act on every exit).
    private enum CardRow: Identifiable {
        case breaks
        case rule(String)
        case note([PlanParser.SourceLine])

        var id: String {
            switch self {
            case .breaks: return "breaks"
            case .rule(let note): return "rule " + note
            case .note(let lines): return "note \(lines.first?.id ?? 0)"
            }
        }
    }

    private func cardRows(_ source: TrainerSource) -> [CardRow] {
        let firstExit = source.firstExitLine ?? .max
        var rows: [CardRow] = []
        var rules = ruleNotes
        var hasBreaks = false
        for line in source.lines where line.exitIndex == nil {
            switch line.role {
            case .commonBreak:
                if !hasBreaks { rows.append(.breaks) }
                hasBreaks = true
            case .doNotEnter, .falseStart:
                if let index = rules.firstIndex(where: { Self.isRule($0, line: line) }) { rows.append(.rule(rules.remove(at: index))) }
            case .note where line.id < firstExit:
                // A line right under a note goes on its paragraph.
                if case .note(let lines)? = rows.last, lines.last?.id == line.id - 1 {
                    rows[rows.count - 1] = .note(lines + [line])
                } else {
                    rows.append(.note([line]))
                }
            default:
                break
            }
        }
        if !hasBreaks { rows.insert(.breaks, at: 0) }
        return rows + rules.map(CardRow.rule)
    }

    /// Lines in paragraphs: those right under one another together.
    private static func paragraphs(_ lines: [PlanParser.SourceLine]) -> [[PlanParser.SourceLine]] {
        var result: [[PlanParser.SourceLine]] = []
        for line in lines {
            if let last = result.last?.last, last.id == line.id - 1 {
                result[result.count - 1].append(line)
            } else {
                result.append([line])
            }
        }
        return result
    }

    /// The trainer's notes the plan took nothing from: before the first exit (`after` false: the card's) or from it on
    /// (the list's end).
    private func notes(after: Bool, _ source: TrainerSource) -> [PlanParser.SourceLine] {
        let first = source.firstExitLine ?? .max
        return source.lines.filter { $0.role == .note && ($0.id > first) == after }
    }

    /// The plan was read from a trainer's text (not put together by hand).
    private var hasSource: Bool {
        !plan.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// «Текст тренера ›» (design council, round 12: «15 строк» beside it decided nothing).
    private var sourceRow: some View {
        Button { showSource = true } label: {
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Trainer’s Text").foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            } icon: {
                Image(systemName: "doc.plaintext")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "The trainer's lines the plan was read from"))
    }

    /// After an exit's line tapped in the trainer's text: that exit's row in view, unfolded to its editors.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let id = jumpToExit, let exit = plan.exits.first(where: { $0.id == id }) else { return }
        jumpToExit = nil
        withAnimation(.smooth(duration: 0.3)) {
            expandedExit = exit.id
            proxy.scrollTo(exit.id, anchor: .center)
        }
    }

    /// «⛔ ждать тишины» (the trainer's 🚩), «🔖 фальстарт», the rest as points.
    private func ruleIcon(_ note: String) -> (String, Color) {
        if PlanParser.isDoNotEnterRule(note) { return ("minus.circle.fill", Theme.danger) }
        if PlanParser.isFalseStartRule(note.lowercased()) { return ("bookmark.fill", Theme.warning) }
        return ("arrow.right.circle", .secondary)
    }

    /// The conditions the trainer wrote once for the whole training — her lines for them (in their one form only when
    /// they no longer say it) — and which exits they go to.
    private func commonEntriesCard(_ source: TrainerSource) -> some View {
        let words = source.words(.commonCondition, in: plan)
        let saidByWords = !words.isEmpty && source.commonEntriesAreAsWritten(in: plan)
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Common conditions")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        if !saidByWords {
                            Text(plan.commonEarlyEntries.map(\.conditionText).joined(separator: " · "))
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        if !words.isEmpty { TrainerQuote(lines: words).padding(.top, 3) }
                    }
                } icon: {
                    Image(systemName: "figure.run").foregroundStyle(Theme.warning)
                }
                Picker("Which exits", selection: Binding(
                    get: { plan.commonEntriesScope.map { $0 == .all ? 0 : 1 } ?? 2 },
                    set: { choice in
                        switch choice {
                        case 0: withAnimation { plan.applyCommonEarlyEntries(to: .all) }
                        case 1: withAnimation { plan.applyCommonEarlyEntries(to: .long) }
                        default: pickingCommonExits = true
                        }
                    })) {
                    Text("All exits").tag(0)
                    Text("From 1 min").tag(1)
                    Text("Choose").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
        }
        .labelStyle(PlanCardLabelStyle())
        .listRowBackground(Theme.warning.opacity(0.12))
    }
}

/// «Текст тренера» from the plan's check: the trainer's own words, as she wrote them, and in a narrow margin at their
/// side where each line went — an exit's line the exit's number as the plan has it now (a moved exit keeps its words),
/// the lines under it a thin pink rule, a line for the whole training the sign of its row in the plan (⏸ the common
/// break, ⛔ the rule to wait for quiet, the calendar the header), a note nothing (and dimmed). What the plan read in a
/// line is marked in it, the times in their colours (`TrainerWords`); a line of an exit taken out of the plan is struck
/// through. A tap on an exit's lines closes the text on that exit's row, unfolded. No line numbers, legend or «→ выход
/// 6» plates (design council, round 12); the exit unfolded in the plan has its lines marked.
private struct TrainerSourceView: View {
    let plan: TrainingPlan
    /// The exit unfolded in the plan: its lines marked, and in view.
    var highlighted: UUID?
    var onJump: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let source = TrainerSource(plan)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(source.lines) { line in
                        row(line, source: source).id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                guard let highlighted, let exit = plan.exits.first(where: { $0.id == highlighted }),
                      let first = source.lines.first(where: { $0.kind == .exit && source.isLine($0, of: exit) }) else { return }
                proxy.scrollTo(first.id, anchor: UnitPoint(x: 0, y: 0.3))
            }
        }
        .background(Theme.panel)
        .navigationTitle("Trainer’s Text")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: Line

    @ViewBuilder
    private func row(_ line: PlanParser.SourceLine, source: TrainerSource) -> some View {
        if line.role == .blank {
            Color.clear.frame(height: 10)
        } else {
            let exit = source.exit(of: line, in: plan)
            let content = TrainerPageLine(line: line, source: source, plan: plan, chevron: true)
                .padding(.leading, 14)
                .padding(.trailing, 18)
                .background(highlighted != nil && exit?.id == highlighted ? Theme.accent.opacity(0.13) : .clear)
                .contentShape(Rectangle())
            if let exit {
                Button { onJump(exit.id) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Open exit \(exit.number) in the plan"))
            } else {
                content
            }
        }
    }
}

/// One line of the trainer's text as her whole text shows it — «Текст тренера» from the plan and the drawer during the
/// training: in a narrow margin at its side where it went (an exit's line the exit's number as the plan has it now, the
/// lines under it a thin pink rule, a line for the whole training the sign of its row in the plan, a note nothing), the
/// words marked (`TrainerWords`), a line of an exit taken out of the plan struck through.
struct TrainerPageLine: View {
    let line: PlanParser.SourceLine
    let source: TrainerSource
    let plan: TrainingPlan
    /// A quiet chevron after an exit's line: a tap opens the exit.
    var chevron = false
    /// The rule down the margin beside an exit's lines.
    var exitRule = true

    /// The margin with the marks.
    @ScaledMetric(relativeTo: .callout) private var margin: CGFloat = 30

    var body: some View {
        let exit = source.exit(of: line, in: plan)
        let underExit = line.exitIndex != nil && line.kind != .exit
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // A line with no mark keeps the margin too (an empty view takes no room).
            ZStack(alignment: .leading) {
                Color.clear.frame(width: margin, height: 1)
                mark(line.role, exit: exit)
            }
            Text(words(exit: exit, removed: line.exitIndex != nil && exit == nil))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chevron, line.kind == .exit, exit != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        // The exit's block: a thin rule down the margin from its number to its last line.
        .background(alignment: .leading) {
            if exitRule, exit != nil, underExit {
                Capsule()
                    .fill(Theme.accent.opacity(0.4))
                    .frame(width: 2)
                    .padding(.leading, 10)
            }
        }
    }

    /// The line's words; an exit taken out of the plan, struck through and dimmed.
    private func words(exit: PlannedExit?, removed: Bool) -> AttributedString {
        var words = source.text(line, plan: plan, exit: exit, style: .page)
        if removed {
            words.strikethroughStyle = Text.LineStyle.single
            words.foregroundColor = .secondary
        }
        return words
    }

    /// The margin: the exit's number as the plan has it now, or the sign of the row the line went to.
    @ViewBuilder
    private func mark(_ role: TrainerLineRole, exit: PlannedExit?) -> some View {
        switch role {
        case .exit:
            if let exit {
                Text("\(exit.number)")
                    .font(.system(.caption, design: .rounded, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 22)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .header: sign("calendar", Theme.accent)
        case .commonBreak: sign("pause.circle", Theme.accent)
        case .commonCondition: sign("figure.run", Theme.warning)
        case .doNotEnter: sign("minus.circle.fill", Theme.danger)
        case .falseStart: sign("bookmark.fill", Theme.warning)
        case .blank, .note, .exitBreak, .exitCondition, .exitNote: EmptyView()
        }
    }

    /// A row's sign, on the line's baseline.
    private func sign(_ symbol: String, _ tint: Color) -> some View {
        Text(Image(systemName: symbol))
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

/// «Выбрать»: a switch per exit for the common conditions; an exit with its own ones keeps them.
private struct CommonExitsPicker: View {
    @Binding var plan: TrainingPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach($plan.exits) { $exit in
                Toggle(isOn: $exit.usesCommonEarlyEntries) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exit \(exit.number) · \(DurationText.short(exit.duration))")
                        if !exit.earlyEntries.isEmpty {
                            Text("own conditions").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(Theme.accent)
                .disabled(!exit.earlyEntries.isEmpty)
            }
        }
        .navigationTitle("Common conditions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// One exit. Folded, as the overview: the number and the time, under them what the exit has in words — triggers,
/// conditions for coming back early, «или до вставания», a note — or nothing, and last the break after it when it is
/// its own («⏸ 5 мин»). A tap unfolds it into the editors: − time +, the break after it, and the line that opens «Выход N»
/// (a tap on the row again, or on another row, folds it). Every control has a fixed width so the row neither jumps
/// when a value changes nor overflows in edit mode, where the row stays folded for the delete and reorder controls.
private struct ExitRow: View {
    @Binding var exit: PlannedExit
    let plan: TrainingPlan
    var defaultBreak: TimeInterval
    /// No break after the last exit: the training ends there.
    var isLast: Bool
    /// The trainer's lines it was read from (`TrainerSource`): none for an exit added by hand.
    var words: [AttributedString] = []
    /// The exit with only what its words don't say (`TrainerSource.beyondWords`): what the line over them shows.
    var beyondWords: PlannedExit?
    var isExpanded: Bool
    var onToggle: () -> Void
    var onEdit: () -> Void
    /// nil for the exits already done and the current one.
    var onDelete: (() -> Void)?

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }
    #else
    private let isEditing = false
    #endif

    var body: some View {
        Group {
            if isExpanded && !isEditing {
                expanded
            } else {
                folded
            }
        }
        .swipeActions(edge: .leading) {
            Button(action: onEdit) { Label("Edit", systemImage: "slider.horizontal.3") }.tint(Theme.info)
        }
        // Set explicitly: with the leading action SwiftUI no longer adds the list's own «Удалить».
        .swipeActions(edge: .trailing) {
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            Button("Triggers, Conditions, Note…", systemImage: "slider.horizontal.3", action: onEdit)
        }
    }

    /// In the conditions' one form, as on the training card and the Mac («встала и пошла 1:00 · легла 0:20»): what the
    /// trainer's words under it don't already say (owner, 05.11.2026: «⚡ куртка» over «+ куртка» said it twice).
    private var summary: ExitSummaryText { ExitSummaryText(plan: plan, exit: beyondWords ?? exit) }

    private var number: some View {
        Text("\(exit.number)")
            .font(.system(.headline, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 20, alignment: .leading)
    }

    /// The row unfolds, like the title's: a quiet chevron that turns down when it is open.
    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }

    // MARK: Folded

    private var folded: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    number
                    Text(exit.isOpen ? PlannedExit.openText : DurationText.short(exit.duration))
                        .font(.system(.body, design: .rounded, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.primary)
                        .layoutPriority(2)
                    // «2 мин или до вставания», as the trainer wrote it: the exit's own way to end early, by its time
                    // (a «Встала → сразу» condition says it in the line under it, with the others).
                    if exit.untilStanding, !exit.isOpen {
                        Text(PlannedExit.untilStandingText)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .layoutPriority(1)
                    }
                    signs
                    Spacer(minLength: 8)
                    if !isEditing { disclosure }
                }
                if !summary.isEmpty {
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 25)
                }
                // The exception to the common break lives here, by its exit (the card above says only the common one),
                // as the row's last line — where it comes in the training, after the exit and what it asks: «⏸ 5 мин»
                // (GPT, round 9: at the right of the time it left open whether it came before the exit or after it).
                if !isLast, let own = (beyondWords ?? exit).breakAfter {
                    ownBreak(own)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 25)
                }
                trainerWords
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    /// The trainer's lines under the row: what the plan made of them above, her words to check it against (and, where
    /// the owner has changed a time, the trainer's struck through).
    @ViewBuilder
    private var trainerWords: some View {
        if !words.isEmpty {
            TrainerQuote(lines: words)
                .padding(.leading, 25)
                .padding(.top, 3)
        }
    }

    /// What the exit has besides its time, as signs only, as on the training card's chips: ⚡ triggers, 🏃 conditions
    /// for coming back early (its own or the training's common ones), ⏸ a break of its own («6  2 мин 🏃 ⏸»). Which
    /// ones, the trainer's words under it say (design council, round 17: the list had lost the signs).
    @ViewBuilder
    private var signs: some View {
        let triggers = !exit.triggers.isEmpty
        let entries = !plan.earlyEntries(of: exit).isEmpty
        let ownBreak = !isLast && exit.breakAfter != nil
        if triggers || entries || ownBreak {
            HStack(spacing: 7) {
                if triggers { sign("bolt.fill", Theme.warning).accessibilityLabel(String(localized: "Triggers on the way out")) }
                if entries { sign("figure.run", Theme.info).accessibilityLabel(String(localized: "Coming back early")) }
                if ownBreak, let own = exit.breakAfter {
                    sign("pause.circle", Theme.info)
                        .accessibilityLabel(String(localized: "Own break after this exit: \(DurationText.short(own))"))
                }
            }
            .padding(.leading, 4)
        }
    }

    private func sign(_ symbol: String, _ tint: Color) -> some View {
        Text(Image(systemName: symbol))
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
    }

    /// «⏸ 5 мин» in the summary line's size, the sign in the break's blue: the row's last line, after the exit as the
    /// break comes (design council, round 13: «После — перерыв» said what the sign and the place say).
    private func ownBreak(_ value: TimeInterval) -> some View {
        Text("\(Text(Image(systemName: "pause.circle")).foregroundStyle(Theme.info)) \(Text(verbatim: DurationText.short(value)).foregroundStyle(.white.opacity(0.6)))")
            .font(.system(size: 13, design: .rounded))
            .lineLimit(1)
            .accessibilityLabel(String(localized: "Own break after this exit: \(DurationText.short(value))"))
    }

    // MARK: Unfolded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                number
                stepButton("minus") { exit.duration = max(0, exit.duration - stepFor(exit.duration - 1)) }
                DurationButton(value: $exit.duration, title: String(localized: "Exit \(exit.number)"), presets: DurationPresets.exits, width: 52)
                stepButton("plus") { exit.duration += stepFor(exit.duration) }
                Spacer(minLength: 0)
                if !isLast {
                    HStack(spacing: 3) {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.secondary)
                            .help("Break after the exit")
                        DurationButton(value: $exit.breakAfter, title: String(localized: "Break After Exit \(exit.number)"),
                                       presets: DurationPresets.breaks, defaultValue: defaultBreak, secondsStep: 5,
                                       font: .system(.subheadline, design: .rounded), width: 46)
                    }
                }
                disclosure
            }
            Button(action: onEdit) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if summary.isEmpty {
                            Text("Triggers, Conditions, Note")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            summary
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Exit \(exit.number): triggers, coming back early, note"))
            trainerWords
        }
        .padding(.vertical, 4)
        // The controls take their own taps; the rest of the row folds it.
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// 5 s steps under a minute, 30 s from a minute up.
    private func stepFor(_ current: TimeInterval) -> TimeInterval {
        current >= 60 ? 30 : 5
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Theme.control, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breaks

/// The plan editors of the iPhone and the Mac change the breaks through these: the common break, the exceptions to
/// it, and «Сделать все по …» with its way back.
extension TrainingPlan {
    /// Exits with a break of their own (there is none after the last exit: the training ends there).
    var ownBreakExits: [PlannedExit] { exits.dropLast().filter { $0.breakAfter != nil } }

    /// A new common break; own breaks that now equal it follow it again (as `PlanParser` reads them).
    mutating func setDefaultBreak(_ value: TimeInterval) {
        defaultBreak = value
        for index in exits.indices where exits[index].breakAfter == value {
            exits[index].breakAfter = nil
        }
    }

    /// «Сделать все по 2 мин»: every break follows the common one. Returns the own breaks it took away, by exit.
    mutating func makeBreaksCommon() -> [UUID: TimeInterval] {
        var taken: [UUID: TimeInterval] = [:]
        for index in exits.indices {
            if let own = exits[index].breakAfter { taken[exits[index].id] = own }
            exits[index].breakAfter = nil
        }
        return taken
    }

    /// «Вернуть»: the own breaks `makeBreaksCommon` took, on the exits still here that follow the common one.
    mutating func restoreOwnBreaks(_ taken: [UUID: TimeInterval]) {
        for index in exits.indices where exits[index].breakAfter == nil {
            if let own = taken[exits[index].id], own != defaultBreak { exits[index].breakAfter = own }
        }
    }
}

extension Binding where Value == TrainingPlan {
    /// The plan written back with its exits still following «ко всем» / «к длинным»
    /// (`TrainingPlan.keepingCommonEntriesScope`): an added exit or a new time gets the common conditions as the
    /// switch says, instead of turning it into «Выбрать». The plan editors of the iPhone and the Mac write through it.
    var keepingCommonEntriesScope: Binding<TrainingPlan> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0.keepingCommonEntriesScope(from: wrappedValue) })
    }
}

/// A row that unfolds in place: its label and, at the trailing edge, the list's quiet chevron, turning down when open;
/// what it holds under it, row by row.
private struct QuietDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { configuration.isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
        if configuration.isExpanded {
            configuration.content
        }
    }
}

/// The plan's card rows: the sign in a column of its own, in the tint, beside what the row says — the trainer's words
/// under its title stay in their column at every text size (the list's own label wraps the lines of a long title under
/// the sign at the accessibility sizes).
private struct PlanCardLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var signColumn: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.icon
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .frame(width: signColumn)
            configuration.title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    /// The plan card's rows a little tighter than a list's own, so that the exits start higher (GPT, round 7). iOS 26
    /// sets the vertical insets alone; before it, and on the Mac, the list's own.
    @ViewBuilder func compactPlanRow() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            listRowInsets(.vertical, 7)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - The trainer's words

/// What a line of the trainer's text went to in the plan.
enum TrainerLineRole: Equatable {
    case blank, header, exit, exitBreak, exitCondition, exitNote, commonBreak, commonCondition, doNotEnter, falseStart, note
}

extension PlanParser.SourceLine {
    /// The row of the plan the line went to: the date's (the header), an exit's (its own line, its break, its
    /// conditions, a note under them), the common break's, the common conditions', a rule's, or none (a note).
    var role: TrainerLineRole {
        switch kind {
        case .blank: return .blank
        case .header: return .header
        case .exit: return .exit
        case .breakTime: return .exitBreak
        case .earlyEntry: return exitIndex == nil ? .commonCondition : .exitCondition
        case .doNotEnter: return .doNotEnter
        case .falseStart: return .falseStart
        case .note:
            let words = PlanParser.stripDecorations(text)
            // A lone «➡️» says nothing.
            if words.isEmpty { return .blank }
            if exitIndex != nil { return .exitNote }
            return PlanParser.commonBreak(in: words) != nil ? .commonBreak : .note
        }
    }
}

/// The trainer's text matched to the plan: each exit with the lines it was read from — by its place in her text
/// (`PlannedExit.sourceIndex`), so a moved exit keeps its words; by its number in a plan from before that.
struct TrainerSource {
    let lines: [PlanParser.SourceLine]
    private let byPlace: Bool

    init(_ plan: TrainingPlan) {
        lines = PlanParser.sourceLines(plan.rawText)
        byPlace = plan.exits.contains { $0.sourceIndex != nil }
    }

    func isLine(_ line: PlanParser.SourceLine, of exit: PlannedExit) -> Bool {
        if byPlace { return exit.sourceIndex != nil && line.exitIndex == exit.sourceIndex }
        return line.exitNumber != nil && line.exitNumber == exit.number
    }

    /// The exit a line went to, while it is in the plan (nil for a line of no exit, or of one taken out).
    func exit(of line: PlanParser.SourceLine, in plan: TrainingPlan) -> PlannedExit? {
        guard line.exitIndex != nil else { return nil }
        return plan.exits.first { isLine(line, of: $0) }
    }

    /// The exit's own lines, as its row quotes them: its line, its conditions, its break, a note under them.
    func words(of exit: PlannedExit, in plan: TrainingPlan) -> [AttributedString] {
        lines.filter { $0.role != .blank && isLine($0, of: exit) }
            .map { text($0, plan: plan, exit: exit, style: .quote) }
    }

    /// A line marked (`TrainerWords`), with what its exit's other lines decide about it.
    func text(_ line: PlanParser.SourceLine, plan: TrainingPlan?, exit: PlannedExit?, style: TrainerWords.Style) -> AttributedString {
        TrainerWords.text(line, plan: plan, exit: exit, style: style, standingOverridden: standingOverridden(line))
    }

    /// The exit of the line has a line of its own about standing up («🟡 Если встала и пошла - входим через 1 минуту»):
    /// that says what standing up means for it, and its «ИЛИ до вставания» became no condition of its own
    /// (`TrainingPlan.foldUntilStanding`).
    func standingOverridden(_ line: PlanParser.SourceLine) -> Bool {
        guard line.kind == .exit, let index = line.exitIndex else { return false }
        return lines.contains { other in
            other.exitIndex == index && other.role == .exitCondition && PlanParser.parseEarlyEntry(other.text)?.isStandingUp == true
        }
    }

    /// What the exit's row says above its words: only what they don't say — a trigger or condition the owner added or
    /// changed («🏃 легла 1:00», not the unchanged «встала и пошла 1:00» beside it), her note changed, an own break
    /// changed. The training's common conditions on it are the 🏃 on its time line, their words on their card. What
    /// she wrote and the plan kept is in her words, marked (an exit added by hand, with no words, keeps everything).
    func beyondWords(of exit: PlannedExit, in plan: TrainingPlan) -> PlannedExit {
        let own = lines.filter { $0.role != .blank && isLine($0, of: exit) }
        guard let line = own.first(where: { $0.kind == .exit }),
              let written = PlanParser.parseExit(PlanParser.stripDecorations(line.text)) else { return exit }
        var shown = exit
        let writtenTriggers = Set(written.triggers.map { $0.lowercased() })
        shown.triggers = exit.triggers.filter { !writtenTriggers.contains($0.lowercased()) }
        // Her conditions under the exit, and «ИЛИ до вставания» as `TrainingPlan.foldUntilStanding` reads it.
        var entries = own.filter { $0.role == .exitCondition }.compactMap { PlanParser.parseEarlyEntry($0.text) }
        if written.untilStanding, !entries.contains(where: \.isStandingUp) { entries.insert(.untilStanding, at: 0) }
        func key(_ entry: EarlyEntry) -> String { "\(entry.event.lowercased())|\(entry.delay ?? 0)|\(entry.detail ?? "")" }
        let writtenKeys = Set(entries.map(key))
        shown.earlyEntries = plan.usesCommonEarlyEntries(exit) ? []
            : plan.earlyEntries(of: exit).filter { !writtenKeys.contains(key($0)) }
        shown.usesCommonEarlyEntries = false
        let note = ([written.noteText] + own.filter { $0.role == .exitNote }.map { PlanParser.stripDecorations($0.text) })
            .compactMap { $0 }.joined(separator: "\n")
        if (exit.noteText ?? "") == note { shown.note = nil }
        // Her own break after it: kept, said by her words; changed (also to the common one), the break it has now.
        if let written = own.first(where: { $0.role == .exitBreak }).flatMap({ DurationText.sumOfUnits(in: PlanParser.stripDecorations($0.text)) }),
           let index = plan.exits.firstIndex(where: { $0.id == exit.id }) {
            shown.breakAfter = plan.breakAfter(exitAt: index) == written ? nil : plan.breakAfter(exitAt: index)
        }
        return shown
    }

    /// The training's common conditions are the ones her lines for them say.
    func commonEntriesAreAsWritten(in plan: TrainingPlan) -> Bool {
        let written = lines.filter { $0.role == .commonCondition }.compactMap { PlanParser.parseEarlyEntry($0.text) }
        func key(_ entry: EarlyEntry) -> String { "\(entry.event.lowercased())|\(entry.delay ?? 0)|\(entry.detail ?? "")" }
        return plan.commonEarlyEntries.map(key) == written.map(key)
    }

    /// The lines of `role` that belong to no exit, as quoted.
    func words(_ role: TrainerLineRole, in plan: TrainingPlan) -> [AttributedString] {
        lines.filter { $0.role == role }.map { text($0, plan: plan, exit: nil, style: .quote) }
    }

    /// Where the first exit's line stands: the notes before it belong to the training's card, those after it stand
    /// among or after the exits.
    var firstExitLine: Int? { lines.first { $0.kind == .exit }?.id }
}

/// A line of the trainer's text with what the plan read in it marked: the exit's time pink, a break's or a condition's
/// blue, the quiet the ⛔ rule asks red, a trigger amber, what the dog does brighter — and struck through where the
/// plan no longer says so (the owner changed it). `quote`: small and quiet, under a row of the plan; `page`: the full
/// text, an exit's line in the body's weight.
enum TrainerWords {
    enum Style { case quote, page }

    /// `standingOverridden`: the exit's own lines say what standing up means for it (`TrainerSource.standingOverridden`),
    /// so its «ИЛИ до вставания» is left unmarked.
    static func text(_ line: PlanParser.SourceLine, plan: TrainingPlan?, exit: PlannedExit?, style: Style,
                     standingOverridden: Bool = false) -> AttributedString {
        let role = line.role
        let shown = style == .quote ? quoted(line.text) : line.text
        let size: Font.TextStyle = style == .quote ? .footnote : .callout
        var result = AttributedString(shown)
        result.font = .system(size, design: .rounded, weight: style == .page && (role == .header || role == .exit) ? .semibold : .regular)
        result.foregroundColor = base(role, style)
        let spanWeight: Font.Weight = style == .quote ? .medium : role == .header ? .bold : .semibold
        for span in spans(in: shown, role: role, plan: plan, exit: exit, standingOverridden: standingOverridden) {
            guard let range = Range(span.range, in: result) else { continue }
            let color = tint(span.tint, style) ?? base(role, style)
            result[range].foregroundColor = span.stale ? color.opacity(0.55) : color
            if span.tint != .words || style == .page {
                result[range].font = .system(size, design: .rounded, weight: spanWeight)
            }
            if span.stale { result[range].strikethroughStyle = Text.LineStyle.single }
        }
        return result
    }

    /// Words with no line of the text behind them, as quoted.
    static func plain(_ text: String) -> AttributedString {
        var result = AttributedString(quoted(text))
        result.font = .system(.footnote, design: .rounded)
        result.foregroundColor = base(.note, .quote)
        return result
    }

    /// The line as a row of the plan quotes it: without the ➡️, bullets and 🐹 in front, with the trainer's own marks
    /// 🟡, 🟢, 🚩 and 🔖.
    static func quoted(_ text: String) -> String {
        ["🟡", "🟠", "🟢", "🚩", "🔖"].contains { PlanParser.hasMark(text, $0) } ? text : PlanParser.stripDecorations(text)
    }

    private static func base(_ role: TrainerLineRole, _ style: Style) -> Color {
        if style == .quote { return .white.opacity(0.5) }
        switch role {
        // The header dimmer: its date and trainers, which the plan read, stand out.
        case .header: return .primary.opacity(0.7)
        case .exit: return .primary
        case .exitBreak, .exitCondition, .commonBreak, .commonCondition: return .primary.opacity(0.85)
        case .doNotEnter: return Theme.danger.opacity(0.95)
        case .falseStart: return .primary.opacity(0.8)
        case .exitNote, .note, .blank: return .secondary
        }
    }

    private enum Tint { case exitTime, time, condition, quiet, trigger, words, warning }

    private static func tint(_ tint: Tint, _ style: Style) -> Color? {
        switch tint {
        case .exitTime: return Theme.accent
        case .time, .condition: return Theme.info
        case .quiet: return Theme.danger
        case .trigger, .warning: return Theme.warning
        case .words: return style == .quote ? .white.opacity(0.88) : .primary
        }
    }

    private struct Span {
        let range: Range<String.Index>
        let tint: Tint
        var stale = false
    }

    private static func spans(in text: String, role: TrainerLineRole, plan: TrainingPlan?, exit: PlannedExit?,
                              standingOverridden: Bool) -> [Span] {
        let words = PlanParser.stripDecorations(text)
        switch role {
        case .exit:
            return exitSpans(text, plan: plan, exit: exit, standingOverridden: standingOverridden)
        case .header:
            return headerSpans(text, plan: plan)
        case .exitBreak:
            // The break after the exit now, against the trainer's (none after the last exit: nothing to compare).
            var stale = false
            if let plan, let exit, let index = plan.exits.firstIndex(where: { $0.id == exit.id }), index < plan.exits.count - 1,
               let written = DurationText.sumOfUnits(in: words) {
                stale = plan.breakAfter(exitAt: index) != written
            }
            return matches(durationRegex, in: text).map { Span(range: $0, tint: .time, stale: stale) }
        case .commonBreak:
            let stale = plan.map { plan in PlanParser.commonBreak(in: words).map { $0 != plan.defaultBreak } ?? false } ?? false
            return matches(durationRegex, in: text).map { Span(range: $0, tint: .time, stale: stale) }
        case .exitCondition, .commonCondition:
            let entries = plan.map { plan in
                role == .commonCondition ? plan.commonEarlyEntries : exit.map { plan.earlyEntries(of: $0) } ?? []
            }
            return conditionSpans(text, entries: entries)
        case .doNotEnter:
            var spans = event(in: text).map { [Span(range: $0, tint: .words)] } ?? []
            if let quiet = matches(durationRegex, in: text).first { spans.append(Span(range: quiet, tint: .quiet)) }
            return spans
        case .falseStart:
            var spans: [Span] = []
            if let colon = text.firstIndex(of: ":") {
                spans.append(Span(range: text.startIndex..<text.index(after: colon), tint: .warning))
            }
            if let window = matches(firstSecondsRegex, in: text, group: 1).first {
                spans.append(Span(range: window, tint: .warning))
            }
            return spans
        case .blank, .exitNote, .note:
            return []
        }
    }

    /// «🐹 Тренировка на воскресенье - Аня/Марк - 04.10.2026»: the date and the trainers the plan read (the name
    /// went to the screen's title); struck through where the owner has changed them.
    private static func headerSpans(_ text: String, plan: TrainingPlan?) -> [Span] {
        let read = PlanParser.parse(PlanParser.stripDecorations(text))
        var spans: [Span] = []
        let date = matches(dateRegex, in: text).first
        if let date {
            let stale = plan.map { plan in
                read.date.map { day in plan.date.map { !Calendar.current.isDate($0, inSameDayAs: day) } ?? true } ?? false
            } ?? false
            spans.append(Span(range: date, tint: .words, stale: stale))
        }
        // The parts after the name, between « - », without the date.
        let trainersStale = plan.map { $0.trainers.trimmingCharacters(in: .whitespaces) != read.trainers } ?? false
        let separators = matches(headerSeparatorRegex, in: text)
        for (start, end) in zip(separators.map(\.upperBound), separators.dropFirst().map(\.lowerBound) + [text.endIndex]) {
            var lower = start, upper = end
            if let date, date.lowerBound >= lower, date.lowerBound <= upper { upper = date.lowerBound }
            while lower < upper, " -–—".contains(text[lower]) { lower = text.index(after: lower) }
            while upper > lower, " -–—".contains(text[text.index(before: upper)]) { upper = text.index(before: upper) }
            if lower < upper { spans.append(Span(range: lower..<upper, tint: .words, stale: trainersStale)) }
        }
        return spans
    }

    /// «6 выход - 2 минуты ИЛИ до вставания», «2 выход - 30 секунд + куртка»: the time up to the first «+», «(» or
    /// «или»; «или до вставания» in the condition's blue when it became the exit's condition («встала сразу»); each
    /// trigger after a «+».
    private static func exitSpans(_ text: String, plan: TrainingPlan?, exit: PlannedExit?, standingOverridden: Bool) -> [Span] {
        let labelEnd = matches(exitLabelRegex, in: text).first?.upperBound ?? text.startIndex
        var timeEnd = text[labelEnd...].firstIndex { $0 == "+" || $0 == "(" } ?? text.endIndex
        if let or = matches(orRegex, in: text, from: labelEnd).first, or.lowerBound < timeEnd { timeEnd = or.lowerBound }
        let written = PlanParser.parseExit(PlanParser.stripDecorations(text))
        let timeStale = exit.map { exit in !exit.isOpen && written.map { $0.duration != exit.duration } ?? false } ?? false
        var spans = matches(durationRegex, in: text, from: labelEnd)
            .filter { $0.upperBound <= timeEnd }
            .map { Span(range: $0, tint: .exitTime, stale: timeStale) }
        // Not where a line of the exit about standing up («встала и пошла - 1 минуту») says it instead: the plan made
        // that line the condition, not these words. Struck through when the exit's «встала сразу» is gone.
        if !standingOverridden, let until = matches(untilStandingRegex, in: text, from: labelEnd).first {
            let stale = plan.flatMap { plan in exit.map { !plan.earlyEntries(of: $0).contains(where: \.isUntilStanding) } } ?? false
            spans.append(Span(range: until, tint: .condition, stale: stale))
        }
        for trigger in matches(triggerRegex, in: text, from: labelEnd, group: 1) {
            let words = text[trigger].trimmingCharacters(in: .whitespaces).lowercased()
            let stale = exit.map { exit in !exit.triggers.contains { $0.lowercased() == words } } ?? false
            spans.append(Span(range: trigger, tint: .trigger, stale: stale))
        }
        return spans
    }

    /// «🟡 Если встала и пошла - входим через 1 минуту»: what the dog does and the time; struck through when the plan
    /// has no such condition any more, or another time for it.
    private static func conditionSpans(_ text: String, entries: [EarlyEntry]?) -> [Span] {
        guard let written = PlanParser.parseEarlyEntry(text) else { return [] }
        let match = entries?.first { $0.event.lowercased() == written.event.lowercased() }
        let gone = entries != nil && match == nil
        let delayStale = gone || match.map { ($0.delay ?? 0) != (written.delay ?? 0) } == true
        var spans: [Span] = []
        if let event = event(in: text) { spans.append(Span(range: event, tint: .words, stale: gone)) }
        if let delay = matches(delayRegex, in: text, group: 1).first ?? matches(delayRegex, in: text, group: 2).first {
            spans.append(Span(range: delay, tint: .time, stale: delayStale))
        }
        return spans
    }

    /// «встала и пошла» in «🟡 Если встала и пошла - входим…»: after «если», up to the dash (as
    /// `PlanParser.splitCondition`).
    private static func event(in text: String) -> Range<String.Index>? {
        guard let ifWord = matches(ifRegex, in: text).first else { return nil }
        let body = text[ifWord.upperBound...]
        let separator = [" - ", " – ", " — ", "- ", "— "].compactMap { body.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            ?? body.range(of: ", ")
        var end = separator?.lowerBound ?? body.endIndex
        while end > body.startIndex, " ,;:".contains(text[text.index(before: end)]) { end = text.index(before: end) }
        return end > body.startIndex ? body.startIndex..<end : nil
    }

    private static func matches(_ regex: NSRegularExpression, in text: String, from start: String.Index? = nil,
                                group: Int = 0) -> [Range<String.Index>] {
        let range = NSRange((start ?? text.startIndex)..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: group), in: text) }
    }

    /// "<number> <unit>": «2 минуты», «30 секунд», "45 sec".
    private static let durationRegex = try! NSRegularExpression(
        pattern: #"\d+(?:[.,]\d+)?\s*(?:час\p{L}*|мин\p{L}*|сек\p{L}*|hours?\b|hrs?\b|min\p{L}*|sec\p{L}*)"#, options: [.caseInsensitive])

    /// «6 выход», «выход №6», "Exit 6", "6th exit", after the trainer's marks.
    private static let exitLabelRegex = try! NSRegularExpression(
        pattern: #"^[^\p{L}\p{N}(]*(?:\d+(?:st|nd|rd|th)?\s*[-–—.)]?\s*(?:выход|exit|departure)\p{L}*|(?:выход|exit|departure)\p{L}*\s*(?:№|#|no\.?)?\s*\d+)"#,
        options: [.caseInsensitive])

    private static let orRegex = try! NSRegularExpression(pattern: #"(?:^|\s)(?:или|or)\s"#, options: [.caseInsensitive])

    private static let untilStandingRegex = try! NSRegularExpression(
        pattern: #"(?:или|or)\s+(?:до\s+вставания|пока\s+не\s+встанет|until\b[^+(]*?\bstand\p{L}*(?:\s+up)?)"#,
        options: [.caseInsensitive])

    /// What follows a «+», up to the next one, a «(» or «ИЛИ до вставания».
    private static let triggerRegex = try! NSRegularExpression(
        pattern: #"\+\s*([^+(]+?)\s*(?=\+|\(|(?:или|or)\s+(?:до|пока|until)\b|$)"#, options: [.caseInsensitive])

    private static let ifRegex = try! NSRegularExpression(pattern: #"(?<!\p{L})(?:если|if)\s+"#, options: [.caseInsensitive])

    /// The time after «через» / "in": «1 минуту», «20 секунд», «минуту», «полминуты», «две минуты»; or «сразу».
    private static let delayRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:через|спустя|in|after)\s+(\d+(?:[.,]\d+)?\s*(?:час\p{L}*|мин\p{L}*|сек\p{L}*|hours?\b|hrs?\b|min\p{L}*|sec\p{L}*)(?:\s+\d+\s*(?:сек\p{L}*|sec\p{L}*))?|(?:(?:одну|одна|две|два|три|четыре|пять|десять|пятнадцать|двадцать|тридцать|полторы|полтора|a|an|one|two|three|four|five|ten|half\s+an?)\s+)?(?:пол)?(?:час\p{L}*|минут\p{L}*|секунд\p{L}*|hours?\b|minutes?\b|seconds?\b))|(?<!\p{L})(сразу|немедленно|right away|immediately|at once)(?!\p{L})"#,
        options: [.caseInsensitive])

    /// «04.10.2026», «4/10/26» (as `PlanParser`).
    private static let dateRegex = try! NSRegularExpression(pattern: #"\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})"#)

    /// « - » between the header's parts.
    private static let headerSeparatorRegex = try! NSRegularExpression(pattern: #"\s+[-–—]\s+"#)

    /// «в первые 20 секунд», "in the first 20 seconds".
    private static let firstSecondsRegex = try! NSRegularExpression(
        pattern: #"(?:перв\p{L}*|first)\s+(\d+(?:[.,]\d+)?\s*\p{L}+)"#, options: [.caseInsensitive])
}

/// The trainer's own lines under the row of the plan made of them: small and quiet beside a hairline, what the plan
/// read in them marked (`TrainerWords`). Her words are what the plan is checked against, so they stay in sight.
struct TrainerQuote: View {
    let lines: [AttributedString]

    var body: some View {
        // A little more between her lines than inside a wrapped one.
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Trainer's words: \(lines.map { String($0.characters) }.joined(separator: "\n"))"))
    }
}
