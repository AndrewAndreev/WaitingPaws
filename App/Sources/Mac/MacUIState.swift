#if os(macOS)
import Foundation
import Observation
import SwiftUI
import WaitingPawsCore

/// Window-level state of the Mac app that menus, toolbar and panels share.
@MainActor
@Observable
final class MacUIState {
    /// «Расписание разобрано» sheet after a paste (the waiting schedule itself is `AppModel.pendingPlan`).
    var reviewingPlan = false
    var showCameraPicker = false
    /// «Вторая камера…»: the picker for the camera only to look at.
    var showSecondCameraPicker = false
    /// Xiaomi sign-in from the camera menu (e.g. after starting with a plain go2rtc stream).
    var showXiaomiSignIn = false
    var confirmFinish = false
    var confirmAbandon = false
    /// «Остановить запись?»: a stop by mistake (⌘R, REC in the toolbar) cut many recordings short.
    var confirmStopRecording = false
    /// A copy of the running session's schedule open for edits («Изменить расписание…»).
    var editingSessionPlan: TrainingPlan?
    /// «Только камера» (the panel's «Без тренировки ▾», ⇧⌘F): before a training, the picture on the whole window
    /// without recording (someone else records, or the dog is just being watched). A training brings the panels back.
    var cameraOnly = false
    /// Zoom of the camera picture in the training window (gestures and the View menu).
    let cameraZoom = ZoomState()
    /// Before the start: what the pointer is over, a block on the plan's timeline or a line of the trainer's text on
    /// the panel; the other one lights.
    var planPointer: MacPlanPointer?
    /// Bumped when the trainer's window for «Фальстарт» outside closes (`watchFalseStartWindow`): nothing observable
    /// changes at that moment, and the menu item has to grey out.
    private var falseStartWindowsClosed = 0

    init() {
        #if DEBUG
        // `--demo-review` opens the sheet over the `--demo-plan` schedule (see AppModel).
        reviewingPlan = CommandLine.arguments.contains("--demo-review")
        // `--demo-confirm-stop` (with a recording): «Остановить запись?» as after ⌘R.
        if CommandLine.arguments.contains("--demo-confirm-stop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.confirmStopRecording = true }
        }
        #endif
    }

    /// ⌘R and REC: a start right away, a stop after the question.
    func toggleRecording(_ model: AppModel) {
        if model.isRecordingNow { confirmStopRecording = true } else { model.toggleRecording() }
    }

    /// ⌘⇧V: parse the trainer's message from the clipboard and show how it was read.
    func pasteSchedule(_ model: AppModel) {
        guard let text = Pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.errorMessage = String(localized: "В буфере обмена нет текста. Скопируйте сообщение тренера и попробуйте снова.")
            return
        }
        let plan = PlanParser.parse(text)
        guard plan.isValid else {
            model.errorMessage = String(localized: "В скопированном тексте не нашлось ни одного выхода («1 выход - 30 секунд»).")
            return
        }
        model.setPending(plan)
        reviewingPlan = true
        cameraOnly = false
    }

    /// ⇧⌘F, Esc: the picture on the whole window and back (only before a training).
    func toggleCameraOnly(_ model: AppModel) {
        guard model.session == nil else { return }
        cameraOnly.toggle()
    }

    /// ⌘↩
    func startPending(_ model: AppModel) {
        guard var plan = model.pendingPlan, model.session == nil else { return }
        plan.renumber()
        model.startSession(with: plan)
        model.setPending(nil)
        reviewingPlan = false
    }

    /// ⌘E: the running session's schedule in the same sheet as after a paste, «Сохранить» applies it.
    func editSessionPlan(_ model: AppModel) {
        guard let session = model.session, !session.isFinished else { return }
        editingSessionPlan = session.plan
    }

    func saveSessionPlan(_ model: AppModel) {
        guard let plan = editingSessionPlan, let session = model.session else { return }
        if session.updatePlan(plan) {
            editingSessionPlan = nil
        } else {
            model.errorMessage = String(localized: "Прошедшие выходы и текущий нельзя удалить или переставить.")
        }
    }

    /// Space: the one obvious next step of the running session — «Вышли», «Вернулись» (or «Завершить» in the last break).
    func primaryStep(_ model: AppModel) {
        guard let session = model.session else {
            startPending(model)
            return
        }
        switch session.phase {
        case .away: session.endExit()
        case .breakTime(_, _, _, nil): model.finishSession()
        case .ready, .leaving, .breakTime: session.markBehindDoor()
        case .finished: break
        }
    }

    /// ⌫: false start — outside while the trainer's window lasts, or in a break when the dog went to the door before
    /// «Вышли».
    func falseStart(_ model: AppModel) {
        guard canFalseStart(model), model.session != nil else { return }
        model.falseStart()
    }

    /// «Фальстарт» counts now, as the readout shows its button (`ReadoutContent.showsFalseStart`).
    func canFalseStart(_ model: AppModel) -> Bool {
        _ = falseStartWindowsClosed
        guard let session = model.session else { return false }
        return ReadoutContent(session: session).showsFalseStart(at: Date())
    }

    /// Waits out the trainer's window of the exit in progress, then wakes whatever reads `canFalseStart` (the menu).
    func watchFalseStartWindow(_ model: AppModel) async {
        guard let session = model.session, let left = ReadoutContent(session: session).falseStartLeft(at: Date()),
              left > 0 else { return }
        // A hair past the end, so `canFalseStart` already reads false then.
        do { try await Task.sleep(for: .seconds(left + 0.1)) } catch { return }
        falseStartWindowsClosed += 1
    }

    /// The pasted schedule's timeline editor is on screen: ⌘= / ⌘− / ⌘0 zoom it there (`MacPlanTimelineEditor`), so
    /// the camera's zoom items give those keys up meanwhile (both took them, and only one of them reacted).
    func showsPlanEditor(_ model: AppModel) -> Bool {
        model.session == nil && model.pendingPlan != nil && !model.isRecordingClip && !cameraOnly
    }

    func primaryStepTitle(_ model: AppModel) -> String {
        guard let session = model.session else { return model.startTitle }
        switch session.phase {
        case .away: return String(localized: "Вернулись")
        case .breakTime(_, _, _, nil): return String(localized: "Завершить")
        case .ready, .leaving, .breakTime: return String(localized: "Вышли")
        case .finished: return String(localized: "Готово")
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
            let zoomKeys = !ui.showsPlanEditor(model)
            Button("Увеличить") { withAnimation(.spring(response: 0.3)) { ui.cameraZoom.zoom(by: ZoomState.step) } }
                .keyboardShortcut(zoomKeys ? KeyboardShortcut("=", modifiers: .command) : nil)
                .disabled(ui.cameraZoom.scale >= ZoomState.maxScale)
            Button("Уменьшить") {
                withAnimation(.spring(response: 0.3)) {
                    ui.cameraZoom.zoom(by: 1 / ZoomState.step)
                    ui.cameraZoom.settle()
                }
            }
            .keyboardShortcut(zoomKeys ? KeyboardShortcut("-", modifiers: .command) : nil)
            .disabled(!ui.cameraZoom.isZoomed)
            Button("Без увеличения") { withAnimation(.spring(response: 0.3)) { ui.cameraZoom.reset() } }
                .keyboardShortcut(zoomKeys ? KeyboardShortcut("0", modifiers: .command) : nil)
                .disabled(!ui.cameraZoom.isZoomed)
            Divider()
            Button(model.settings.cameraDisplayName.isEmpty ? String(localized: "Первая камера") : model.settings.cameraDisplayName) {
                model.showCamera(second: false)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(!model.hasSecondCamera)
            Button(model.hasSecondCamera ? model.activeSecondCameraName : String(localized: "Вторая камера")) {
                model.showCamera(second: true)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(!model.hasSecondCamera)
            Divider()
            Button(model.panTilt.isActive ? "Закончить поворот камеры" : "Повернуть камеру") {
                withAnimation(.smooth(duration: 0.25)) { model.panTilt.toggle() }
            }
            .disabled(!model.canPanTilt)
            Button(ui.cameraOnly ? "Показать панели" : "Только камера") {
                withAnimation(.smooth(duration: 0.35)) { ui.toggleCameraOnly(model) }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.session != nil || model.isRecordingClip || (!ui.cameraOnly && !model.settings.isConfigured))
            Divider()
        }
        CommandMenu("Тренировка") {
            Button("Вставить расписание") { ui.pasteSchedule(model) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.session != nil)
            Button(model.startTitle) { ui.startPending(model) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.pendingPlan == nil || model.session != nil)
            Divider()
            // Space and ⌫ work in the training window itself (a menu key equivalent would steal them from text fields).
            Button(String(localized: "\(ui.primaryStepTitle(model)) (Пробел)")) { ui.primaryStep(model) }
                .disabled(model.session == nil)
            Button("Фальстарт (⌫)") { ui.falseStart(model) }
                .disabled(!ui.canFalseStart(model))
            // The panel's capsule beside «Осталось», all through the break a false start led to.
            Button("Отменить фальстарт") { withAnimation(.smooth(duration: 0.25)) { model.undoFalseStart() } }
                .disabled(model.falseStartUndo == nil)
            Divider()
            // Before a training ⌘R is the panel's «Без тренировки ▾ → Записать видео»; in one it records the training.
            Button(model.isRecordingNow ? String(localized: "Остановить запись…")
                   : model.session == nil ? String(localized: "Записать без тренировки") : String(localized: "Начать запись")) {
                ui.toggleRecording(model)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.isRecordingNow && !model.settings.isConfigured)
            Button("Изменить расписание…") { ui.editSessionPlan(model) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.session == nil)
            Button(model.finishTitle + "…") { ui.confirmFinish = true }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.session == nil)
            Divider()
            Button("История") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: .command)
        }
    }
}
#endif
