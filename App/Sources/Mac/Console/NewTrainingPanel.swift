#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel before a session: the pasted plan with «Начать», the paste zone, record only.
struct NewTrainingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Новая тренировка").font(.title2.weight(.semibold))
                if let plan = model.pendingPlan {
                    todayCard(plan)
                    PasteZone(compact: true)
                } else {
                    PasteZone(compact: false)
                }
                Divider()
                Button { model.startRecording() } label: {
                    ShortcutLabel(title: String(localized: "Только запись"), symbol: "record.circle", key: "⌘R", expand: true)
                }
                .controlSize(.large)
                .disabled(!model.settings.isConfigured)
                Text("Видео без расписания и лога — например, посмотреть, что собака делает одна.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func todayCard(_ plan: TrainingPlan) -> some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("СЕГОДНЯ")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Показать разбор") { ui.reviewingPlan = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Как прочитан текст тренера")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title).font(.title3.weight(.semibold))
                Text(summary(plan))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { ui.startPending(model) } label: {
                ShortcutLabel(title: model.startTitle, symbol: "play.fill", key: "⌘↩", prominent: true, expand: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(MacPalette.pinkDeep)
            .controlSize(.large)
            .padding(.top, 2)
            HStack {
                if model.settings.isConfigured {
                    Toggle("Записывать видео", isOn: $settings.autoRecord)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Убрать") { model.setPending(nil) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07)))
        }
    }

    private func summary(_ plan: TrainingPlan) -> String {
        var parts: [String] = []
        if !plan.trainers.isEmpty { parts.append(plan.trainers) }
        parts.append(pluralText(plan.exits.count, ru: ("выход", "выхода", "выходов"), en: ("exit", "exits")))
        parts.append("≈ \(DurationText.short((plan.estimatedDuration / 60).rounded() * 60))")
        parts.append(String(localized: "конец ≈ \(MacFormat.time.string(from: Date().addingTimeInterval(plan.estimatedDuration)))"))
        return parts.joined(separator: " · ")
    }
}

/// Dashed drop zone: paste the trainer's message (⌘⇧V) or drop text onto it.
private struct PasteZone: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var compact: Bool
    @State private var targeted = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(MacPalette.pink)
                    Text("Другое расписание").font(.callout)
                    Spacer()
                    Button { ui.pasteSchedule(model) } label: { ShortcutLabel(title: String(localized: "Вставить"), symbol: "doc.on.clipboard", key: "⌘⇧V") }
                }
                .padding(12)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(MacPalette.pink)
                    Text("Вставьте расписание от тренера").font(.headline)
                    Text("Текст из Telegram или WhatsApp — выходы, перерывы и заметки разберутся сами.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { ui.pasteSchedule(model) } label: {
                        ShortcutLabel(title: String(localized: "Вставить"), symbol: "doc.on.clipboard", key: "⌘⇧V", prominent: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MacPalette.pinkDeep)
                    .controlSize(.large)
                    .padding(.top, 2)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(targeted ? AnyShapeStyle(MacPalette.pink) : AnyShapeStyle(.tertiary))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first else { return false }
            let plan = PlanParser.parse(text)
            guard plan.isValid else { return false }
            model.setPending(plan)
            ui.reviewingPlan = true
            return true
        } isTargeted: { targeted = $0 }
    }
}

#endif
