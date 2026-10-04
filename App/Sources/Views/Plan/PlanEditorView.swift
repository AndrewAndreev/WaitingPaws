import SwiftUI
import WaitingPawsCore

/// Review and correct the parsed plan before starting.
struct PlanEditorView: View {
    @Environment(AppModel.self) private var model
    @State var plan: TrainingPlan
    var onStart: (TrainingPlan) -> Void

    @State private var showNotes = false
    @State private var showDetails = false
    #if os(iOS) && DEBUG
    // `--demo-plan-edit` opens the editor in edit mode (layout checks without tapping).
    @State private var editMode: EditMode = CommandLine.arguments.contains("--demo-plan-edit") ? .active : .inactive
    #elseif os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    /// Exits whose break is set on its own instead of following "Перерыв между выходами".
    private var ownBreaks: [PlannedExit] { plan.exits.filter { $0.breakAfter != nil } }

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
                    DurationButton(value: $plan.defaultBreak, title: "Перерыв между выходами",
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
                                Text("Свой перерыв: " + ownBreaks.map { "после \($0.number) — \(DurationText.short($0.breakAfter ?? 0))" }
                                    .joined(separator: ", "))
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

            Section {
                ForEach($plan.exits) { $exit in
                    ExitRow(exit: $exit, defaultBreak: plan.defaultBreak)
                }
                .onDelete { offsets in
                    plan.exits.remove(atOffsets: offsets)
                    plan.renumber()
                }
                .onMove { source, destination in
                    plan.exits.move(fromOffsets: source, toOffset: destination)
                    plan.renumber()
                }
                Button {
                    let last = plan.exits.last
                    plan.exits.append(PlannedExit(number: plan.exits.count + 1, duration: last?.duration ?? 5))
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

            if !plan.notes.isEmpty {
                Section {
                    DisclosureGroup("Заметки тренера · \(plan.notes.count)", isExpanded: $showNotes) {
                        ForEach(plan.notes, id: \.self) { note in
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        #if DEBUG
        .onAppear { print("[perf] PlanEditorView appear at", PerformanceMonitor.timeFormatter.string(from: Date())) }
        #endif
        .navigationTitle("Проверьте план")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            @Bindable var settings = model.settings
            VStack(spacing: 10) {
                Toggle(isOn: $settings.autoRecord) {
                    Label("Записывать видео", systemImage: "record.circle")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .tint(Theme.accent)
                BigButton(title: "Начать тренировку", systemImage: "play.fill", height: 50) {
                    var final = plan
                    final.renumber()
                    onStart(final)
                }
                .disabled(!plan.isValid)
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
    }
}

/// One exit on a single line: number · − duration + · break · "until standing" toggle.
/// Every control has a fixed width so the row neither jumps when a value changes nor overflows
/// in edit mode, where the ± and toggle make room for the delete and reorder controls.
/// The note (if any) goes on a second line; add one via swipe or long press.
private struct ExitRow: View {
    @Binding var exit: PlannedExit
    var defaultBreak: TimeInterval

    @State private var editingNote = false
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
                DurationButton(value: $exit.duration, title: "Выход \(exit.number)", presets: DurationPresets.exits, width: 52)
                if !isEditing {
                    stepButton("plus") { exit.duration += stepFor(exit.duration) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                        .help("Перерыв после выхода")
                    DurationButton(value: $exit.breakAfter, title: "Перерыв после выхода \(exit.number)",
                                   presets: DurationPresets.breaks, defaultValue: defaultBreak, secondsStep: 5,
                                   font: .system(.subheadline, design: .rounded), width: 46)
                }
                if isEditing {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                        .opacity(exit.untilStanding ? 1 : 0)
                } else {
                    standingToggle
                }
            }
            if editingNote || exit.note != nil {
                TextField("Заметка", text: Binding(
                    get: { exit.note ?? "" },
                    set: { exit.note = $0.isEmpty ? nil : $0 }))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 25)
                    #if os(macOS)
                    .textFieldStyle(.plain)
                    #endif
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button { editingNote = true } label: { Label("Заметка", systemImage: "text.bubble") }.tint(Theme.info)
        }
        .contextMenu {
            Button("Добавить заметку", systemImage: "text.bubble") { editingNote = true }
            Toggle("Или до вставания", systemImage: "figure.stand", isOn: $exit.untilStanding)
        }
    }

    private var standingToggle: some View {
        Button {
            exit.untilStanding.toggle()
        } label: {
            Image(systemName: "figure.stand")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(exit.untilStanding ? Theme.accent : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(exit.untilStanding ? .black : .white)
        }
        .buttonStyle(.plain)
        .help("Или до вставания")
        .accessibilityLabel("Или до вставания")
        .accessibilityValue(exit.untilStanding ? "включено" : "выключено")
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
