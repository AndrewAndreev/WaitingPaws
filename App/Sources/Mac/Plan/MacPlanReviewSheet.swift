#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Расписание разобрано» — placeholder; the real one (B1: trainer's text ↔ table) lands separately.
/// Shown as a sheet over the «Пульт» right after a paste.
struct MacPlanReviewSheet: View {
    @Binding var plan: TrainingPlan
    /// «Начать тренировку ⌘↩».
    var onStart: () -> Void
    /// «Готово»: keep the plan on the «Пульт» without starting.
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Расписание разобрано: \(plan.exits.count) выходов").font(.headline)
            HStack {
                Button("Готово", action: onDone).keyboardShortcut(.cancelAction)
                Button("Начать тренировку", action: onStart).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 300)
    }
}
#endif
