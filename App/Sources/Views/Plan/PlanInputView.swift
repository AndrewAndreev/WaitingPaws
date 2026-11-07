import SwiftUI
import WaitingPawsCore

/// Sheet: paste the schedule text → parse → review and edit → start.
struct PlanInputView: View {
    @Environment(\.dismiss) private var dismiss
    var initialText: String
    var onStart: (TrainingPlan) -> Void

    @State private var text = ""
    @State private var plan: TrainingPlan?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if text.isEmpty {
                        Text("🐹 Тренировка на понедельник - Аня/Марк - 05.10.2026\n➡️ Все перерывы 2 минуты\n1 выход - 5 секунд\n2 выход - 10 секунд\n…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 10) {
                    BigButton(title: String(localized: "Из буфера"), systemImage: "doc.on.clipboard", style: .secondary, height: 44) {
                        if let pasted = Pasteboard.string, !pasted.isEmpty { text = pasted }
                    }
                    BigButton(title: String(localized: "Разобрать"), systemImage: "wand.and.stars", height: 44) {
                        plan = PlanParser.parse(text)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .navigationTitle("Расписание")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .navigationDestination(item: $plan) { parsed in
                PlanEditorView(plan: parsed) { finalPlan in
                    onStart(finalPlan)
                    dismiss()
                }
            }
        }
        .onAppear {
            #if DEBUG
            print("[perf] PlanInputView appear at", PerformanceMonitor.timeFormatter.string(from: Date()))
            #endif
            text = initialText
            #if DEBUG
            if CommandLine.arguments.contains("--demo-parse"), !text.isEmpty {
                plan = PlanParser.parse(text)
            }
            #endif
        }
    }
}
