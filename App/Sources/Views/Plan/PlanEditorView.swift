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

    @State private var showNotes = false
    @State private var showDetails = false
    /// The exit open in «Выход N».
    @State private var editingExit: EditedExit?
    /// «Выбрать»: which exits get the common conditions.
    @State private var pickingCommonExits = false

    private struct EditedExit: Identifiable {
        let id: UUID
    }
    #if os(iOS) && DEBUG
    // `--demo-plan-edit` opens the editor in edit mode (layout checks without tapping).
    @State private var editMode: EditMode = CommandLine.arguments.contains("--demo-plan-edit") ? .active : .inactive
    #elseif os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    /// Exits whose break is set on its own instead of following "Перерыв между выходами".
    private var ownBreaks: [PlannedExit] { plan.exits.filter { $0.breakAfter != nil } }

    /// "после 2 — 3 мин, после 5 — 1 мин".
    private var ownBreaksList: String {
        ownBreaks.map { String(localized: "после \($0.number) — \(DurationText.short($0.breakAfter ?? 0))") }
            .joined(separator: ", ")
    }

    var body: some View {
        List {
            Section {
                DisclosureGroup(isExpanded: $showDetails) {
                    TextField("Название", text: $plan.title)
                    TextField("Кто тренирует", text: $plan.trainers)
                    DatePicker("Дата", selection: Binding(
                        get: { plan.date ?? Date() },
                        set: { plan.date = $0 }), displayedComponents: .date)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).font(.headline)
                        Text([plan.date.map { TrainingPlan.dateFormatter.string(from: $0) }, plan.trainers.isEmpty ? nil : plan.trainers]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label("Перерыв между выходами", systemImage: "pause.circle")
                    Spacer()
                    DurationButton(value: $plan.defaultBreak, title: String(localized: "Перерыв между выходами"),
                                   presets: DurationPresets.breaks, secondsStep: 5)
                }
                if !ownBreaks.isEmpty {
                    Button {
                        withAnimation {
                            for index in plan.exits.indices { plan.exits[index].breakAfter = nil }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Сделать везде \(DurationText.short(plan.defaultBreak))")
                                Text("Свой перерыв: \(ownBreaksList)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        } icon: {
                            Image(systemName: "equal.circle")
                        }
                    }
                }
            } footer: {
                Text(ownBreaks.isEmpty
                     ? "Один перерыв для всех выходов. Чтобы задать свой перерыв выходу, нажмите на время рядом с ⏸ в его строке."
                     : "Яркие значения в строках выходов — свои перерывы, приглушённые берутся отсюда.")
            }

            if !plan.notes.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showNotes) {
                        ForEach(plan.notes, id: \.self) { note in
                            Label {
                                // The icon already shows the 🚩 / 🔖 the parser keeps on the note.
                                Text(PlanParser.stripDecorations(note)).font(.footnote).foregroundStyle(.secondary)
                            } icon: {
                                let (symbol, tint) = ruleIcon(note)
                                Image(systemName: symbol).foregroundStyle(tint)
                            }
                        }
                    } label: {
                        Label("Правила на всю тренировку · \(plan.notes.count)", systemImage: "list.bullet.rectangle")
                    }
                }
            }

            if !plan.commonEarlyEntries.isEmpty {
                commonEntriesCard
            }

            Section {
                // A new time through the row keeps «к длинным» / «ко всем».
                ForEach(Array($plan.keepingCommonEntriesScope.exits.enumerated()), id: \.element.id) { index, $exit in
                    ExitRow(exit: $exit, plan: plan, defaultBreak: plan.defaultBreak) {
                        editingExit = EditedExit(id: exit.id)
                    }
                    .deleteDisabled(index < (fixedExits ?? 0))
                    .moveDisabled(index < (fixedExits ?? 0))
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
                    Label("Добавить выход", systemImage: "plus.circle.fill")
                }
            } header: {
                HStack {
                    Text("Выходы · \(plan.exits.count)")
                    Spacer()
                    Text("≈ \(DurationText.short(plan.estimatedDuration))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        #if DEBUG
        .onAppear { print("[perf] PlanEditorView appear at", PerformanceMonitor.timeFormatter.string(from: Date())) }
        // `--demo-exit-editor <n>` opens «Выход n» (UI checks without tapping).
        .task {
            let args = CommandLine.arguments
            guard let flag = args.firstIndex(of: "--demo-exit-editor"), flag + 1 < args.count, let number = Int(args[flag + 1]),
                  let exit = plan.exits.first(where: { $0.number == number }) else { return }
            try? await Task.sleep(for: .seconds(1))
            editingExit = EditedExit(id: exit.id)
        }
        #endif
        .navigationTitle(isRunning ? "Расписание" : "Проверьте план")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Linked to a Mac: the parsed schedule and every edit show up there too (start from either side).
        .task(id: plan) {
            guard !isRunning else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            model.sharePlanWithMac(plan)
        }
        .safeAreaInset(edge: .bottom) {
            @Bindable var settings = model.settings
            VStack(spacing: 10) {
                // Why «Начать тренировку» / «Сохранить» below is greyed out.
                if !plan.isValid {
                    Label("В расписании нет выходов", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isRunning {
                    BigButton(title: String(localized: "Сохранить"), systemImage: "checkmark", height: 50) {
                        var final = plan
                        final.renumber()
                        onStart(final)
                    }
                    .disabled(!plan.isValid)
                } else if model.isLinkedToMac {
                    // Recording follows the Mac's setting there.
                    Label("Это расписание уже и на \(model.linkedHostKind) — начать можно там или здесь.", systemImage: "laptopcomputer.and.iphone")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.info)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Toggle(isOn: $settings.autoRecord) {
                        Label("Записывать видео", systemImage: "record.circle")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                    }
                    .tint(Theme.accent)
                }
                if !isRunning {
                    BigButton(title: model.startTitle, systemImage: "play.fill", height: 50) {
                        var final = plan
                        final.renumber()
                        onStart(final)
                    }
                    .disabled(!plan.isValid)
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.92))
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, $editMode)
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

    /// «⛔ ждать тишины» (the trainer's 🚩), «🔖 фальстарт», the rest as points.
    private func ruleIcon(_ note: String) -> (String, Color) {
        if PlanParser.isDoNotEnterRule(note) { return ("minus.circle.fill", Theme.danger) }
        if PlanParser.isFalseStartRule(note.lowercased()) { return ("bookmark.fill", Theme.warning) }
        return ("arrow.right.circle", .secondary)
    }

    /// The conditions the trainer wrote once for the whole training, and which exits they go to.
    private var commonEntriesCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Условия раннего входа — для всей тренировки")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        Text(plan.commonEarlyEntries.map(\.summary).joined(separator: " · "))
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "figure.run").foregroundStyle(Theme.warning)
                }
                Picker("К каким выходам", selection: Binding(
                    get: { plan.commonEntriesScope.map { $0 == .all ? 0 : 1 } ?? 2 },
                    set: { choice in
                        switch choice {
                        case 0: withAnimation { plan.applyCommonEarlyEntries(to: .all) }
                        case 1: withAnimation { plan.applyCommonEarlyEntries(to: .long) }
                        default: pickingCommonExits = true
                        }
                    })) {
                    Text("Ко всем").tag(0)
                    Text("От 1 мин").tag(1)
                    Text("Выбрать").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Тренер написал их один раз, не под выходом. Выходу их можно поменять — нажмите на строку под ним.")
        }
        .listRowBackground(Theme.warning.opacity(0.12))
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
                        Text("Выход \(exit.number) · \(DurationText.short(exit.duration))")
                        if !exit.earlyEntries.isEmpty {
                            Text("свои условия").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(Theme.accent)
                .disabled(!exit.earlyEntries.isEmpty)
            }
        }
        .navigationTitle("Общие условия")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
        }
    }
}

/// One exit: number · − duration + · break on the first line; under it what the exit has in words — triggers,
/// conditions for coming back early, a note — which opens «Выход N». Every control has a fixed width so the row
/// neither jumps when a value changes nor overflows in edit mode, where the ± make room for the delete and reorder
/// controls.
private struct ExitRow: View {
    @Binding var exit: PlannedExit
    let plan: TrainingPlan
    var defaultBreak: TimeInterval
    var onEdit: () -> Void

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }
    #else
    private let isEditing = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("\(exit.number)")
                    .font(.system(.headline, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 20, alignment: .leading)
                if !isEditing {
                    stepButton("minus") { exit.duration = max(0, exit.duration - stepFor(exit.duration - 1)) }
                }
                DurationButton(value: $exit.duration, title: String(localized: "Выход \(exit.number)"), presets: DurationPresets.exits, width: 52)
                if !isEditing {
                    stepButton("plus") { exit.duration += stepFor(exit.duration) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                        .help("Перерыв после выхода")
                    DurationButton(value: $exit.breakAfter, title: String(localized: "Перерыв после выхода \(exit.number)"),
                                   presets: DurationPresets.breaks, defaultValue: defaultBreak, secondsStep: 5,
                                   font: .system(.subheadline, design: .rounded), width: 46)
                }
            }
            Button(action: onEdit) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ExitSummaryText(plan: plan, exit: exit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Выход \(exit.number): триггеры, ранний вход, заметка"))
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button(action: onEdit) { Label("Изменить", systemImage: "slider.horizontal.3") }.tint(Theme.info)
        }
        .contextMenu {
            Button("Триггеры, условия, заметка…", systemImage: "slider.horizontal.3", action: onEdit)
        }
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

extension Binding where Value == TrainingPlan {
    /// The plan written back with its exits still following «ко всем» / «к длинным»
    /// (`TrainingPlan.keepingCommonEntriesScope`): an added exit or a new time gets the common conditions as the
    /// switch says, instead of turning it into «Выбрать». The plan editors of the iPhone and the Mac write through it.
    var keepingCommonEntriesScope: Binding<TrainingPlan> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0.keepingCommonEntriesScope(from: wrappedValue) })
    }
}
