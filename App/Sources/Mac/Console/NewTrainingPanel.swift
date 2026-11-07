#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel before a session: one button «Вставить расписание» (the trainer's text may also be dropped on the
/// panel), or the pasted plan with «Начать тренировку» and the trainer's text under it, each exit line with its number
/// (the pointer over a line lights its block on the timeline, and a block its lines); at the bottom «Без тренировки ▾».
/// As on the iPhone there is one way
/// to record here: whether a training is recorded is set where it starts («Записывать видео»); «Без тренировки ▾»
/// holds video alone (⌘R) and the camera alone (⇧⌘F). The toolbar's REC shows up only once something records, or
/// during a training.
struct NewTrainingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @State private var dropTargeted = false
    /// The trainer's text under the card: open unless folded (the same choice as during the training).
    @AppStorage(MacTrainerTextFold.key) private var trainerTextOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новая тренировка").font(.title2.weight(.semibold))
            if let plan = model.pendingPlan {
                todayCard(plan)
                if !plan.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    trainerText(plan)
                }
            } else {
                Button { ui.pasteSchedule(model) } label: {
                    ShortcutLabel(title: String(localized: "Вставить расписание"), symbol: "doc.on.clipboard",
                                  key: "⌘⇧V", prominent: true, expand: true)
                }
                .buttonStyle(MacStartButtonStyle(expand: true))
            }
            Divider()
            withoutTraining
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // The trainer's text dropped anywhere on the panel; a dashed rim while it is over it.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MacPalette.pink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first else { return false }
            let plan = PlanParser.parse(text)
            guard plan.isValid else { return false }
            model.setPending(plan)
            ui.reviewingPlan = true
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// «Без тренировки ▾»: «Записать видео · ⌘R» (video alone, into the history) and «Только камера · ⇧⌘F» (the
    /// picture on the whole window, nothing recorded). The keys are in the words: the menu bar's items own them.
    private var withoutTraining: some View {
        Menu {
            Button { model.startRecording() } label: {
                Label(String(localized: "Записать видео · ⌘R"), systemImage: "record.circle")
            }
            Button { ui.cameraOnly = true } label: {
                Label(String(localized: "Только камера · ⇧⌘F"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
        } label: {
            Label("Без тренировки", systemImage: "video")
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .controlSize(.large)
        // As wide as the panel's other rows.
        .frame(maxWidth: .infinity)
        .disabled(!model.settings.isConfigured)
        .help("Записать видео или смотреть камеру на всё окно — без расписания и лога")
    }

    /// «Текст тренера ⌃» and the text: an exit line with its number, the lines under it a stem; the pointer over a
    /// line lights its block on the timeline, a block under the pointer lights its lines here.
    private func trainerText(_ plan: TrainingPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MacTrainerTextFold(open: $trainerTextOpen)
            if trainerTextOpen {
                let lines = MacSourceLine.lines(plan.rawText)
                let link = MacPlanTextLink(plan: plan, lines: lines)
                let lit = MacSourceLine.ids(of: ui.planPointer, in: lines, ordinals: link.ordinals)
                MacTrainerTextView(link: link, lit: lit, fontSize: 12.5, focus: lit.min(),
                                   onHover: { line in ui.planPointer = line?.pointer(exitID: link.exitIDs) })
                    .frame(maxHeight: .infinity)
                    .background(MacTrainerTextFold.box)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: trainerTextOpen ? .infinity : nil, alignment: .top)
        #if DEBUG
        .onAppear {
            // `--demo-pointer N`: the pointer over exit N (its lines lit here, its block on the timeline).
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--demo-pointer"), i + 1 < args.count, let n = Int(args[i + 1]),
               let exit = plan.exits.first(where: { $0.number == n }) {
                ui.planPointer = .exit(exit.id)
            }
            // `--demo-plan-edit`: exit 6 changed to 2 мин 30 с, exit 2 without its «куртка» (struck through in the text).
            if args.contains("--demo-plan-edit"), var edited = model.pendingPlan, edited.exits.count > 5 {
                edited.exits[5].duration = 150
                edited.exits[1].triggers = []
                model.pendingPlan = edited
            }
        }
        #endif
    }

    private func todayCard(_ plan: TrainingPlan) -> some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title).font(.title3.weight(.semibold))
                    Text(summary(plan))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                // The rest of what can be done with the plan, out of the way of «Начать тренировку».
                Menu {
                    Button("Показать разбор", systemImage: "checklist") { ui.reviewingPlan = true }
                    Button("Другое расписание", systemImage: "doc.on.clipboard") { ui.pasteSchedule(model) }
                    Divider()
                    Button("Убрать", systemImage: "xmark", role: .destructive) { model.setPending(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ещё")
            }
            Button { ui.startPending(model) } label: {
                ShortcutLabel(title: String(localized: "Начать тренировку"), symbol: "play.fill", key: "⌘↩", prominent: true, expand: true)
            }
            .buttonStyle(MacStartButtonStyle(expand: true))
            .padding(.top, 2)
            if model.settings.isConfigured {
                Toggle("Записывать видео", isOn: $settings.autoRecord)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07)))
        }
    }

    /// «Аня/Марк · ≈ 25 мин · конец ≈ 21:13», one line: the exits are counted on the timeline under it.
    private func summary(_ plan: TrainingPlan) -> String {
        var parts: [String] = []
        if !plan.trainers.isEmpty { parts.append(plan.trainers) }
        parts.append("≈ \(DurationText.short((plan.estimatedDuration / 60).rounded() * 60))")
        parts.append(String(localized: "конец ≈ \(MacFormat.time.string(from: Date().addingTimeInterval(plan.estimatedDuration)))"))
        return parts.joined(separator: " · ")
    }
}

/// The start of a training («Начать тренировку и запись»), here and in the plan's review: pink with white words,
/// drawn by itself. `.borderedProminent` turns grey in a window that isn't key — in every screenshot too, where it
/// read as no more than «Готово» beside it (GPT, round 8) — as the summary's «Отправить тренеру…» does.
struct MacStartButtonStyle: ButtonStyle {
    var expand = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 14)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: 32)
            .background(MacPalette.pinkDeep.opacity(isEnabled ? 1 : 0.4), in: shape)
            .overlay { if configuration.isPressed { shape.fill(.black.opacity(0.18)) } }
            .contentShape(shape)
    }
}

#endif
