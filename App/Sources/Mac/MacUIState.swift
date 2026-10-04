#if os(macOS)
import Foundation
import Observation
import SwiftUI
import WaitingPawsCore

/// Window-level state of the Mac app that menus, toolbar and panels share.
@MainActor
@Observable
final class MacUIState {
    /// Parsed schedule waiting for «Начать тренировку» (the «Сегодня» card and the plan timeline).
    var pendingPlan: TrainingPlan?
    /// The plan as the trainer sent it, for «Как у тренера» after edits on the timeline.
    var pendingOriginal: TrainingPlan?
    /// «Расписание разобрано» sheet after a paste.
    var reviewingPlan = false
    var showCameraPicker = false
    /// Xiaomi sign-in from the camera menu (e.g. after starting with a plain go2rtc stream).
    var showXiaomiSignIn = false
    var confirmFinish = false
    var confirmAbandon = false
    /// Zoom of the camera picture in the training window (gestures and the View menu).
    let cameraZoom = ZoomState()

    init() {
        #if DEBUG
        // `--demo-plan`: a parsed schedule waiting on the «Пульт» (no paste needed); `--demo-review` also opens the sheet.
        if CommandLine.arguments.contains("--demo-plan") || CommandLine.arguments.contains("--demo-review") {
            setPending(PlanParser.parse(DemoData.planText))
            reviewingPlan = CommandLine.arguments.contains("--demo-review")
        }
        #endif
    }

    func setPending(_ plan: TrainingPlan) {
        pendingPlan = plan
        pendingOriginal = plan
    }

    /// ⌘⇧V: parse the trainer's message from the clipboard and show how it was read.
    func pasteSchedule(_ model: AppModel) {
        guard let text = Pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.errorMessage = "В буфере обмена нет текста. Скопируйте сообщение тренера и попробуйте снова."
            return
        }
        let plan = PlanParser.parse(text)
        guard plan.isValid else {
            model.errorMessage = "В скопированном тексте не нашлось ни одного выхода («1 выход - 30 секунд»)."
            return
        }
        setPending(plan)
        reviewingPlan = true
    }

    /// ⌘⇧R: the previous schedule again.
    func repeatLast(_ model: AppModel) {
        let plan = PlanParser.parse(model.settings.lastPlanText)
        guard plan.isValid else { return }
        setPending(plan)
        reviewingPlan = true
    }

    /// ⌘↩
    func startPending(_ model: AppModel) {
        guard var plan = pendingPlan, model.session == nil else { return }
        plan.renumber()
        model.startSession(with: plan)
        pendingPlan = nil
        pendingOriginal = nil
        reviewingPlan = false
    }

    /// Space: the one obvious next step of the running session.
    func primaryStep(_ model: AppModel) {
        guard let session = model.session else {
            startPending(model)
            return
        }
        switch session.phase {
        case .ready: session.startExit()
        case .leaving: session.markBehindDoor()
        case .away: session.endExit()
        case .breakTime(_, _, _, let next):
            if next != nil { session.startExit() } else { model.finishSession() }
        case .finished: break
        }
    }

    /// ⌫: false start while leaving or behind the door.
    func falseStart(_ model: AppModel) {
        guard let session = model.session, session.phase.isOutside else { return }
        session.resetExit()
    }

    func primaryStepTitle(_ model: AppModel) -> String {
        guard let session = model.session else { return "Начать тренировку" }
        switch session.phase {
        case .ready: return "Начать выход \(session.currentExit?.number ?? 1)"
        case .leaving: return "За дверью"
        case .away: return "Вернулись"
        case .breakTime(_, _, _, let next):
            return next.map { "Начать выход \(session.plan.exits[$0].number)" } ?? "Завершить"
        case .finished: return "Готово"
        }
    }
}

/// Menu bar commands of the Mac app («Тренировка» menu).
struct MacCommands: Commands {
    let model: AppModel
    let ui: MacUIState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .toolbar) {
            Button("Увеличить") { withAnimation(.spring(response: 0.3)) { ui.cameraZoom.zoom(by: ZoomState.step) } }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(ui.cameraZoom.scale >= ZoomState.maxScale)
            Button("Уменьшить") {
                withAnimation(.spring(response: 0.3)) {
                    ui.cameraZoom.zoom(by: 1 / ZoomState.step)
                    ui.cameraZoom.settle()
                }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!ui.cameraZoom.isZoomed)
            Button("Без увеличения") { withAnimation(.spring(response: 0.3)) { ui.cameraZoom.reset() } }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!ui.cameraZoom.isZoomed)
            Divider()
        }
        CommandMenu("Тренировка") {
            Button("Вставить расписание") { ui.pasteSchedule(model) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.session != nil)
            Button("Повторить прошлое") { ui.repeatLast(model) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.session != nil || model.settings.lastPlanText.isEmpty)
            Button("Начать тренировку") { ui.startPending(model) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(ui.pendingPlan == nil || model.session != nil)
            Divider()
            // Space and ⌫ work in the training window itself (a menu key equivalent would steal them from text fields).
            Button(ui.primaryStepTitle(model) + " (Пробел)") { ui.primaryStep(model) }
                .disabled(model.session == nil)
            Button("Фальстарт (⌫)") { ui.falseStart(model) }
                .disabled(!(model.session?.phase.isOutside ?? false))
            Divider()
            Button(model.isRecordingNow ? "Остановить запись" : "Начать запись") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Завершить тренировку…") { ui.confirmFinish = true }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.session == nil)
            Divider()
            Button("История") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: .command)
        }
    }
}
#endif
