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
        // Recording without a training: nothing to read or plan, the picture takes the whole window and the
        // clock floats over it. The camera stays the first child either way, so the player is not recreated.
        let clipMode = model.isRecordingClip
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MacCameraArea(reloadToken: reloadToken)
                    .overlay {
                        if clipMode {
                            ClipRecordingHUD()
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                if !clipMode {
                    Divider()
                    rightPanel
                        .frame(width: 400)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            if !clipMode {
                Divider()
                timeline
                    .frame(height: 232)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.35), value: clipMode)
        .background(Color.black)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        // A solid bar: by default the black picture and the grey panel run up under the toolbar and its
        // capsules straddle the seam between them.
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard model.session != nil || model.pendingPlan != nil else { return .ignored }
            ui.primaryStep(model)
            return .handled
        }
        .onKeyPress(.delete) {
            guard model.session?.phase.isOutside == true else { return .ignored }
            ui.falseStart(model)
            return .handled
        }
        .onAppear { focused = true }
        // A training started from a linked iPhone: the review of its schedule is over here too.
        .onChange(of: model.session != nil) { _, running in if running { ui.reviewingPlan = false } }
        .task(id: model.settings.streamName) {
            await model.refreshXiaomiQuality()
            await model.refreshCameraModes()
        }
        .sheet(isPresented: $ui.reviewingPlan, onDismiss: { focused = true }) {
            MacPlanReviewSheet(plan: pendingPlanBinding,
                               onStart: { ui.startPending(model) },
                               onDone: { ui.reviewingPlan = false })
                .environment(model)
        }
        .sheet(isPresented: $ui.showXiaomiSignIn, onDismiss: { focused = true }) {
            SetupXiaomiSignInSheet(onSignedIn: { _ in
                ui.showXiaomiSignIn = false
                // Straight to the account's cameras.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ui.showCameraPicker = true }
            })
            .environment(model)
            .environment(ui)
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
        } else if model.pendingPlan != nil {
            MacPlanTimelineEditor(plan: pendingPlanBinding, original: model.pendingOriginal)
        } else {
            EmptyTimeline()
        }
    }

    private func live(_ session: TrainingSession, at now: Date) -> LiveSessionModel {
        LiveSessionModel(session: session, now: now,
                         recordingSince: model.isRecordingNow ? model.recordingStartedAt : nil)
    }

    private var pendingPlanBinding: Binding<TrainingPlan> {
        Binding(get: { model.pendingPlan ?? TrainingPlan() }, set: { model.pendingPlan = $0 })
    }

    private var lastRecordBinding: Binding<TrainingRecord?> {
        Binding(get: { model.session == nil ? model.lastRecord : nil }, set: { model.lastRecord = $0 })
    }

    private var lastClipBinding: Binding<RecordingClip?> {
        Binding(get: { model.lastClip }, set: { model.lastClip = $0 })
    }

    private var title: String {
        if let session = model.session { return session.plan.title }
        if let plan = model.pendingPlan { return plan.title }
        return model.settings.cameraDisplayName.isEmpty ? "Waiting Paws" : model.settings.cameraDisplayName
    }

    private var subtitle: String {
        if let session = model.session {
            let trainers = session.plan.trainers.isEmpty ? "" : "\(session.plan.trainers) · "
            return trainers + String(localized: "с \(MacFormat.time.string(from: session.startedAt))")
        }
        if let plan = model.pendingPlan {
            return (plan.trainers.isEmpty ? "" : "\(plan.trainers) · ") + String(localized: "перед стартом")
        }
        return model.isRecordingClip ? String(localized: "запись без тренировки") : String(localized: "новая тренировка")
    }

    // MARK: - Toolbar

    /// Icon and title on every item (a bare icon in a row of similar capsules says too little), groups apart:
    /// camera · recording and sound · the linked iPhone · history and finishing.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem { CameraToolbarMenu(onReconnect: { model.videoSize = nil; reloadToken += 1 }) }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            RecordingToolbarButton()
            Toggle(isOn: Binding(get: { model.settings.audioEnabled }, set: { model.settings.audioEnabled = $0 })) {
                Label("Звук", systemImage: model.settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .padding(.horizontal, ToolbarLook.padding)
                    .labelStyle(.titleAndIcon)
            }
            .help(model.settings.audioEnabled ? "Выключить звук камеры в приложении (запись всегда со звуком)"
                                              : "Включить звук камеры в приложении (запись всегда со звуком)")
        }
        if !model.syncHost.connectedDevices.isEmpty {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Label(model.syncHost.connectedDevices.joined(separator: ", "), systemImage: "iphone")
                    .foregroundStyle(MacPalette.blue)
                    .padding(.horizontal, ToolbarLook.padding + 6)
                    .labelStyle(.titleAndIcon)
                    .help("iPhone видит камеру и ведёт эту тренировку")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { openWindow(id: "history") } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, ToolbarLook.padding)
            }
            .help("История тренировок · ⌘Y")
            if model.session != nil {
                Button { ui.confirmFinish = true } label: {
                    Label("Завершить", systemImage: "flag.checkered")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, ToolbarLook.padding)
                }
                .help("Завершить тренировку · ⌘.")
            }
        }
    }
}

/// Before anything is pasted: where the plan will appear.
private struct EmptyTimeline: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Здесь появится план на шкале времени")
                .font(.headline)
                .foregroundStyle(.secondary)
            // The paste itself lives in the panel on the right: one place for it.
            Text("После вставки расписания выходы и перерывы можно растянуть мышью перед стартом.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Toolbar items breathe a little more than the system default.
private enum ToolbarLook {
    static let padding: CGFloat = 4
}

/// Camera name with status; choose camera, quality, reconnect.
private struct CameraToolbarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var onReconnect: () -> Void

    var body: some View {
        Menu {
            Button("Выбрать камеру…", systemImage: "video.badge.plus") { ui.showCameraPicker = true }
            Button(model.settings.xiaomiAccountID.isEmpty ? "Войти в Xiaomi…" : "Войти в другой аккаунт Xiaomi…",
                   systemImage: "person.crop.circle.badge.plus") { ui.showXiaomiSignIn = true }
            Divider()
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            if let quality = model.xiaomiQuality {
                Divider()
                Picker("Качество", selection: Binding(
                    get: { quality },
                    set: { newValue in
                        Task { await model.setXiaomiQuality(newValue) }
                    })) {
                    ForEach(AppModel.XiaomiQuality.allCases) { Text(model.qualityTitle($0)).tag($0) }
                }
                Text("Записи — в этом же качестве")
                if let size = model.videoSize {
                    Text("Сейчас \(Int(size.width))×\(Int(size.height))")
                }
            }
            if model.cameraModes.hasOptions {
                Divider()
                CameraModeMenuItems()
            }
        } label: {
            // A toolbar menu keeps only one title from its label (no extra views, tight icon spacing),
            // so the status icon, name and quality are one Text.
            Text("\(Image(systemName: cameraOnline ? "video.fill" : "video.slash"))\u{2002}\(title)")
                .padding(.horizontal, ToolbarLook.padding)
        }
        .help(cameraOnline ? "Камера, качество и режим съёмки" : "Камера не на связи — выбрать или переподключить")
    }

    /// «Прихожая · HD»; a long Mi Home name is cut in the middle by the toolbar.
    private var title: String {
        let name = model.settings.cameraDisplayName.isEmpty ? String(localized: "Камера") : model.settings.cameraDisplayName
        guard let quality = model.xiaomiQuality else { return name }
        return "\(name) · \(quality.title)"
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
                        .padding(.horizontal, ToolbarLook.padding + 4)
                } else {
                    Label("Запись", systemImage: "record.circle")
                        .padding(.horizontal, ToolbarLook.padding)
                        .labelStyle(.titleAndIcon)
                }
            }
            .help(model.isRecordingNow ? "Остановить запись · ⌘R" : "Записать видео · ⌘R")
            .disabled(!model.isRecordingNow && !model.settings.isConfigured)
        }
    }
}
#endif
