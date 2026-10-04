#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Пульт» — the training window: camera and the readout on top, the session timeline below.
/// Before the start the right panel offers the paste / repeat / record-only ways in and the timeline
/// shows the pasted plan, editable with the mouse; during the session it is the «план и факт» timeline.
/// Space = the next step, ⌫ = false start (handled here, not as menu key equivalents, so text fields keep them).
struct MacConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool
    @State private var reloadToken = 0

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MacCameraArea(reloadToken: reloadToken)
                Divider()
                rightPanel
                    .frame(width: 400)
            }
            .frame(maxHeight: .infinity)
            Divider()
            timeline
                .frame(height: 232)
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard model.session != nil || ui.pendingPlan != nil else { return .ignored }
            ui.primaryStep(model)
            return .handled
        }
        .onKeyPress(.delete) {
            guard model.session?.phase.isOutside == true else { return .ignored }
            ui.falseStart(model)
            return .handled
        }
        .onAppear { focused = true }
        .task(id: model.settings.streamName) { await model.refreshXiaomiQuality() }
        .sheet(isPresented: $ui.reviewingPlan, onDismiss: { focused = true }) {
            MacPlanReviewSheet(plan: pendingPlanBinding,
                               onStart: { ui.startPending(model) },
                               onDone: { ui.reviewingPlan = false })
                .environment(model)
        }
        .sheet(isPresented: $ui.showCameraPicker, onDismiss: { focused = true }) {
            MacCameraPickerSheet()
                .environment(model)
                .environment(ui)
        }
        .sheet(item: lastRecordBinding, onDismiss: { focused = true }) { record in
            MacSummarySheet(record: record,
                            onHistory: { model.lastRecord = nil; openWindow(id: "history") },
                            onClose: { model.lastRecord = nil })
                .environment(model)
        }
        .sheet(item: lastClipBinding, onDismiss: { focused = true }) { clip in
            MacClipSavedSheet(clip: clip,
                              onHistory: { model.lastClip = nil; openWindow(id: "history") },
                              onClose: { model.lastClip = nil })
                .environment(model)
        }
        .alert("Завершить тренировку?", isPresented: $ui.confirmFinish) {
            Button("Завершить и сохранить") { model.finishSession() }
            Button("Отменить без сохранения", role: .destructive) { model.abandonSession() }
            Button("Продолжить", role: .cancel) {}
        } message: {
            Text("Запись остановится, лог и видео сохранятся в истории.")
        }
        .alert(model.syncHost.pairingRequest.map { "Подключить «\($0.deviceName)»?" } ?? "",
               isPresented: Binding(get: { model.syncHost.pairingRequest != nil },
                                    set: { if !$0 { model.syncHost.answerPairing(allow: false) } })) {
            Button("Разрешить") { model.syncHost.answerPairing(allow: true) }
            Button("Отклонить", role: .cancel) { model.syncHost.answerPairing(allow: false) }
        } message: {
            Text("iPhone увидит камеру этого Mac и сможет вести тренировку: кнопки, запись, лог. Запись и лог сохраняются на Mac. Разрешение запоминается, его можно отозвать в настройках.")
        }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(MinimizedPanelHook(model: model, ui: ui))
    }

    // MARK: - Parts

    @ViewBuilder
    private var rightPanel: some View {
        if let session = model.session {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ConsoleReadout(live: live(session, at: context.date))
            }
        } else if model.isRecordingClip {
            ClipRecordingPanel()
        } else {
            NewTrainingPanel()
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if let session = model.session {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SessionTimelineView(model: live(session, at: context.date))
            }
        } else if ui.pendingPlan != nil {
            MacPlanTimelineEditor(plan: pendingPlanBinding, original: ui.pendingOriginal)
        } else {
            EmptyTimeline()
        }
    }

    private func live(_ session: TrainingSession, at now: Date) -> LiveSessionModel {
        LiveSessionModel(session: session, now: now,
                         recordingSince: model.isRecordingNow ? model.recorder.startedAt : nil)
    }

    private var pendingPlanBinding: Binding<TrainingPlan> {
        Binding(get: { ui.pendingPlan ?? TrainingPlan() }, set: { ui.pendingPlan = $0 })
    }

    private var lastRecordBinding: Binding<TrainingRecord?> {
        Binding(get: { model.session == nil ? model.lastRecord : nil }, set: { model.lastRecord = $0 })
    }

    private var lastClipBinding: Binding<RecordingClip?> {
        Binding(get: { model.lastClip }, set: { model.lastClip = $0 })
    }

    private var title: String {
        if let session = model.session { return session.plan.title }
        if let plan = ui.pendingPlan { return plan.title }
        return model.settings.cameraDisplayName.isEmpty ? "Waiting Paws" : model.settings.cameraDisplayName
    }

    private var subtitle: String {
        if let session = model.session {
            let trainers = session.plan.trainers.isEmpty ? "" : "\(session.plan.trainers) · "
            return trainers + "с \(MacFormat.time.string(from: session.startedAt))"
        }
        if let plan = ui.pendingPlan {
            return (plan.trainers.isEmpty ? "" : "\(plan.trainers) · ") + "перед стартом"
        }
        return model.isRecordingClip ? "запись без тренировки" : "новая тренировка"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem { CameraToolbarMenu(onReconnect: { model.videoSize = nil; reloadToken += 1 }) }
        ToolbarSpacer(.fixed)
        ToolbarItem { RecordingToolbarButton() }
        ToolbarItem {
            Toggle(isOn: Binding(get: { model.settings.audioEnabled }, set: { model.settings.audioEnabled = $0 })) {
                Label("Звук", systemImage: model.settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .help("Звук с камеры в приложении (запись всегда со звуком)")
        }
        if !model.syncHost.connectedDevices.isEmpty {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Label(model.syncHost.connectedDevices.joined(separator: ", "), systemImage: "iphone")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(MacPalette.blue)
                    .help("iPhone видит камеру и ведёт эту тренировку")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { openWindow(id: "history") } label: { Label("История", systemImage: "clock.arrow.circlepath") }
                .help("История тренировок · ⌘Y")
        }
        if model.session != nil {
            ToolbarItem {
                Button { ui.confirmFinish = true } label: { Label("Завершить", systemImage: "flag.checkered") }
                    .help("Завершить тренировку · ⌘.")
            }
        }
    }
}

/// Before anything is pasted: where the plan will appear.
private struct EmptyTimeline: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Здесь появится план на шкале времени")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Вставьте расписание от тренера — выходы и перерывы можно будет растянуть мышью перед стартом.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button { ui.pasteSchedule(model) } label: {
                ShortcutLabel(title: "Вставить расписание", symbol: "doc.on.clipboard", key: "⌘⇧V")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Camera name with status; choose camera, quality, reconnect.
private struct CameraToolbarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var onReconnect: () -> Void

    var body: some View {
        Menu {
            Button("Выбрать камеру…", systemImage: "video.badge.plus") { ui.showCameraPicker = true }
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            if let quality = model.xiaomiQuality {
                Divider()
                Picker("Качество", selection: Binding(
                    get: { quality },
                    set: { newValue in
                        Task {
                            await model.setXiaomiQuality(newValue)
                            onReconnect()
                        }
                    })) {
                    ForEach(AppModel.XiaomiQuality.allCases) { Text($0.title).tag($0) }
                }
                if let size = model.videoSize {
                    Text("Сейчас \(Int(size.width))×\(Int(size.height))")
                }
            }
        } label: {
            HStack(spacing: 6) {
                StatusDot(color: cameraOnline ? MacPalette.green : .secondary, size: 6)
                Text(model.settings.cameraDisplayName.isEmpty ? "Камера" : model.settings.cameraDisplayName)
                if let quality = model.xiaomiQuality {
                    Text(quality.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .help("Камера и качество")
    }

    private var cameraOnline: Bool {
        model.settings.connectionMode == .external || model.embedded.status.isRunning
    }
}

/// REC with the running time, or «Запись» to start one (⌘R).
private struct RecordingToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button { model.toggleRecording() } label: {
                if model.isRecordingNow {
                    RecBadge(text: DurationText.clock(model.recordingDuration(at: context.date)))
                } else {
                    Label("Запись", systemImage: "record.circle")
                }
            }
            .help(model.isRecordingNow ? "Остановить запись · ⌘R" : "Записать видео · ⌘R")
        }
    }
}
#endif
