import SwiftUI
import WaitingPawsCore

/// «Выход 7»: everything about one exit before the training — the time, the break after it, what to take on the way
/// out, when to come back early and its note. Works on a copy of the plan; «Готово» puts it back.
struct ExitEditorView: View {
    @Binding var plan: TrainingPlan
    let exitID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TrainingPlan
    /// The trigger being typed: an index into the exit's triggers, or nil for a new one.
    @State private var triggerEdit: TriggerEdit?
    @State private var triggerText = ""

    private struct TriggerEdit: Identifiable {
        let index: Int?
        var id: Int { index ?? -1 }
    }

    init(plan: Binding<TrainingPlan>, exitID: UUID) {
        _plan = plan
        self.exitID = exitID
        _draft = State(initialValue: plan.wrappedValue)
    }

    private var index: Int? { draft.exits.firstIndex { $0.id == exitID } }

    var body: some View {
        if let index {
            form(index)
        }
    }

    private func form(_ index: Int) -> some View {
        let exit = draft.exits[index]
        return Form {
            Section {
                HStack {
                    Text("За дверью")
                    Spacer()
                    DurationButton(value: $draft.exits[index].duration, title: String(localized: "Выход \(exit.number)"),
                                   presets: DurationPresets.exits)
                }
                if index < draft.exits.count - 1 {
                    HStack {
                        Text("Перерыв после")
                        Spacer()
                        DurationButton(value: $draft.exits[index].breakAfter,
                                       title: String(localized: "Перерыв после выхода \(exit.number)"),
                                       presets: DurationPresets.breaks, defaultValue: draft.defaultBreak, secondsStep: 5)
                    }
                }
            }

            Section {
                FlowLayout(spacing: 8) {
                    ForEach(Array(exit.triggers.enumerated()), id: \.offset) { offset, trigger in
                        triggerChip(trigger, at: offset, exitIndex: index)
                    }
                    Button {
                        triggerText = ""
                        triggerEdit = TriggerEdit(index: nil)
                    } label: {
                        Label("Добавить", systemImage: "plus")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            } header: {
                Label("Триггеры на выходе", systemImage: "bolt.fill")
            } footer: {
                Text("Что взять или сделать, выходя: куртка, обувь, звякнуть ключами.")
            }

            entriesSection(index)

            Section {
                TextField("Заметка к выходу", text: Binding(
                    get: { draft.exits[index].note ?? "" },
                    set: { draft.exits[index].note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(3...10)
            } header: {
                Label("Заметка", systemImage: "text.bubble")
            } footer: {
                Text("Во время тренировки заметка свёрнута в одну строку под условиями.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(String(localized: "Выход \(exit.number)"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    plan = draft
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .alert(triggerEdit?.index == nil ? String(localized: "Новый триггер") : String(localized: "Триггер"),
               isPresented: Binding(get: { triggerEdit != nil }, set: { if !$0 { triggerEdit = nil } })) {
            TextField("куртка, обувь, ключи…", text: $triggerText)
            Button("Готово") { commitTrigger(exitIndex: index) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func triggerChip(_ trigger: String, at offset: Int, exitIndex: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                triggerText = trigger
                triggerEdit = TriggerEdit(index: offset)
            } label: {
                Label {
                    Text(trigger).lineLimit(2)
                } icon: {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.warning)
                }
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { _ = draft.exits[exitIndex].triggers.remove(at: offset) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Убрать «\(trigger)»")
        }
        .font(.system(.subheadline, design: .rounded, weight: .medium))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 34)
        .background(Theme.control, in: Capsule())
    }

    private func commitTrigger(exitIndex: Int) {
        let text = triggerText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { triggerEdit = nil }
        guard let edit = triggerEdit else { return }
        if let offset = edit.index, draft.exits[exitIndex].triggers.indices.contains(offset) {
            if text.isEmpty {
                draft.exits[exitIndex].triggers.remove(at: offset)
            } else {
                draft.exits[exitIndex].triggers[offset] = text
            }
        } else if !text.isEmpty {
            draft.exits[exitIndex].triggers.append(text)
        }
    }

    // MARK: - Coming back early

    private func entriesSection(_ index: Int) -> some View {
        let exit = draft.exits[index]
        let common = draft.usesCommonEarlyEntries(exit)
        let entries = draft.editableEarlyEntries(ofExitAt: index)
        return Section {
            ForEach(entries.indices, id: \.self) { offset in
                EntryEditorRow(entry: entryBinding(offset, exitIndex: index), isCommon: common)
            }
            .onDelete { offsets in
                withAnimation { draft.removeEarlyEntries(at: offsets, ofExitAt: index) }
            }
            Button {
                withAnimation { draft.addEarlyEntry(toExitAt: index) }
            } label: {
                Label("Своё условие", systemImage: "plus")
            }
            if !draft.commonEarlyEntries.isEmpty {
                if exit.earlyEntries.isEmpty {
                    Toggle(isOn: $draft.exits[index].usesCommonEarlyEntries) {
                        Text("Общие условия тренировки")
                    }
                    .tint(Theme.accent)
                } else {
                    Button("Вернуть общие условия") {
                        withAnimation { draft.restoreCommonEarlyEntries(ofExitAt: index) }
                    }
                }
            }
        } header: {
            HStack {
                Label("Ранний вход", systemImage: "figure.run")
                Spacer()
                if common { Text("общие").foregroundStyle(Theme.warning) }
            }
        } footer: {
            Text(common
                 ? "Эти условия тренер написал для всей тренировки. Изменения здесь касаются только этого выхода."
                 : "Когда вернуться раньше плана: что сделала собака и через сколько входить.")
        }
    }

    /// A condition of the exit; changing one of the common ones gives the exit its own copy first.
    private func entryBinding(_ offset: Int, exitIndex: Int) -> Binding<EarlyEntry> {
        Binding(
            get: {
                let entries = draft.editableEarlyEntries(ofExitAt: exitIndex)
                return entries.indices.contains(offset) ? entries[offset] : EarlyEntry(event: "")
            },
            set: { draft.setEarlyEntry($0, at: offset, ofExitAt: exitIndex) })
    }
}

/// One condition: the trainer's colour, what the dog does, after how long, and the trainer's words under it.
private struct EntryEditorRow: View {
    @Binding var entry: EarlyEntry
    var isCommon: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Цвет", selection: $entry.tone) {
                        Text("🟡 Жёлтый").tag(EarlyEntry.Tone.yellow)
                        Text("🟢 Зелёный").tag(EarlyEntry.Tone.green)
                        Text("Без цвета").tag(EarlyEntry.Tone.plain)
                    }
                } label: {
                    Circle().fill(entry.tone.color).frame(width: 12, height: 12)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Цвет условия")
                TextField("Встала и пошла", text: $entry.event)
                    .font(.system(.body, design: .rounded, weight: .medium))
                if isCommon {
                    Text("общее")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.warning.opacity(0.15), in: Capsule())
                }
                DurationButton(value: Binding(get: { entry.delay ?? 0 }, set: { entry.delay = $0 > 0 ? $0 : nil }),
                               title: String(localized: "Через сколько входить"), presets: DurationPresets.entryDelays,
                               zeroTitle: String(localized: "сразу"))
            }
            TextField("От начала движения, когда сняла фокус с двери…", text: Binding(
                get: { entry.detail ?? "" },
                set: { entry.detail = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }
}

/// Lays chips out in lines, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[item].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
