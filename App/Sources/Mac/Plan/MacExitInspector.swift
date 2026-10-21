#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Under the exits' table: the selected exit's triggers, conditions for coming back early and note, side by side.
/// Changing one of the training's common conditions gives the exit its own copy (the other exits keep theirs).
struct MacExitInspector: View {
    @Binding var plan: TrainingPlan
    let exitID: UUID

    @State private var newTrigger = ""
    @FocusState private var triggerFocused: Bool

    private var index: Int? { plan.exits.firstIndex { $0.id == exitID } }

    var body: some View {
        if let index {
            HStack(alignment: .top, spacing: 14) {
                triggers(index)
                    .frame(minWidth: 130, idealWidth: 190, maxWidth: 220, alignment: .leading)
                entries(index)
                    .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                note(index)
                    .frame(minWidth: 130, idealWidth: 190, maxWidth: 220, alignment: .leading)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(_ text: String, symbol: String, tint: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fontWeight(.semibold)
            if let trailing {
                Text(trailing).foregroundStyle(MacPalette.orange).font(.system(size: 11, weight: .medium))
            }
        }
    }

    // MARK: Triggers

    private func triggers(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            title(String(localized: "Триггеры"), symbol: "bolt.fill", tint: MacPalette.orange)
                .help(String(localized: "Что взять или сделать, выходя: куртка, обувь, звякнуть ключами"))
            FlowLayout(spacing: 5) {
                ForEach(Array(plan.exits[index].triggers.enumerated()), id: \.offset) { offset, trigger in
                    HStack(spacing: 4) {
                        Text(trigger).lineLimit(2)
                        Button {
                            plan.exits[index].triggers.remove(at: offset)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help("Убрать «\(trigger)»")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
                }
            }
            TextField("Добавить…", text: $newTrigger)
                .textFieldStyle(.roundedBorder)
                .focused($triggerFocused)
                .onSubmit {
                    let text = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    plan.exits[index].triggers.append(text)
                    newTrigger = ""
                    triggerFocused = true
                }
        }
    }

    // MARK: Coming back early

    private func entries(_ index: Int) -> some View {
        let exit = plan.exits[index]
        let common = plan.usesCommonEarlyEntries(exit)
        let entries = plan.editableEarlyEntries(ofExitAt: index)
        return VStack(alignment: .leading, spacing: 6) {
            title(String(localized: "Ранний вход"), symbol: "figure.run", tint: MacPalette.blue,
                  trailing: common ? String(localized: "общие") : nil)
            ForEach(entries.indices, id: \.self) { offset in
                MacEntryRow(entry: Binding(
                    get: {
                        let shown = plan.editableEarlyEntries(ofExitAt: index)
                        return shown.indices.contains(offset) ? shown[offset] : EarlyEntry(event: "")
                    },
                    set: { plan.setEarlyEntry($0, at: offset, ofExitAt: index) }),
                            onRemove: { plan.removeEarlyEntries(at: [offset], ofExitAt: index) })
            }
            Button("Своё условие", systemImage: "plus") { plan.addEarlyEntry(toExitAt: index) }
                .buttonStyle(.borderless)
            HStack(spacing: 12) {
                Toggle("До вставания — сразу", isOn: $plan.exits[index].untilStanding)
                    .toggleStyle(.checkbox)
                    .help("«ИЛИ до вставания»: собака встала — сразу возвращаться")
                if !plan.commonEarlyEntries.isEmpty {
                    if exit.earlyEntries.isEmpty {
                        Toggle("Общие условия", isOn: $plan.exits[index].usesCommonEarlyEntries)
                            .toggleStyle(.checkbox)
                            .help("Условия, которые тренер написал для всей тренировки")
                    } else {
                        Button("Вернуть общие") { plan.restoreCommonEarlyEntries(ofExitAt: index) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Note

    private func note(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            title(String(localized: "Заметка"), symbol: "text.bubble", tint: .secondary)
            TextField("Своя заметка к выходу", text: Binding(
                get: { plan.exits[index].note ?? "" },
                set: { plan.exits[index].note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
        }
    }
}

/// One condition: the trainer's colour, what the dog does, after how long, the trainer's words; ✕ removes it.
private struct MacEntryRow: View {
    @Binding var entry: EarlyEntry
    var onRemove: () -> Void
    @State private var editingDelay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Menu {
                    Picker("Цвет", selection: $entry.tone) {
                        Text("🟡 Жёлтый").tag(EarlyEntry.Tone.yellow)
                        Text("🟢 Зелёный").tag(EarlyEntry.Tone.green)
                        Text("Без цвета").tag(EarlyEntry.Tone.plain)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Circle().fill(entry.tone.color).frame(width: 9, height: 9)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Цвет условия, как у тренера")
                TextField("Встала и пошла", text: $entry.event)
                    .textFieldStyle(.roundedBorder)
                Button {
                    editingDelay = true
                } label: {
                    Text(entry.delayDescription).monospacedDigit()
                }
                .help("Через сколько входить")
                .popover(isPresented: $editingDelay, arrowEdge: .bottom) {
                    MacDurationEditor(value: Binding(get: { entry.delay ?? 0 }, set: { entry.delay = ($0 ?? 0) > 0 ? $0 : nil }),
                                      title: String(localized: "Через сколько входить"),
                                      presets: DurationPresets.entryDelays.filter { $0 > 0 },
                                      tint: MacPalette.blue) { editingDelay = false }
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Убрать условие")
            }
            TextField("От начала движения, когда сняла фокус с двери…", text: Binding(
                get: { entry.detail ?? "" },
                set: { entry.detail = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 21)
        }
    }
}
#endif
