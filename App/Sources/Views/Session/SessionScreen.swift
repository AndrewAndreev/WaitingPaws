import SwiftUI
import WaitingPawsCore

/// The main screen: camera in the background, training HUD on top.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPlanInput = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showCameraPicker = false
    @State private var showSecondCameraPicker = false
    /// «Подключить камеру…» after starting without one: the first-launch setup as a sheet.
    @State private var showCameraSetup = false
    @State private var confirmFinish = false
    @State private var confirmAbandon = false
    @State private var reloadToken = 0
    /// The schedule waiting on the linked Mac, opened for edits.
    @State private var editingPending: TrainingPlan?
    /// The running training's schedule, opened for edits.
    @State private var editingSessionPlan: TrainingPlan?
    /// «Только камера»: before a training, the picture on the whole screen without recording (someone else records,
    /// or the dog is just being watched). A training brings the cards back.
    @State private var cameraOnly = false
    /// The trainer's text in a drawer over the training screen (the camera stays as it is).
    @State private var showTrainerText = false
    /// The exit's details open above the card (`SessionHUD`).
    @State private var showDetails = false
    /// «Остановить запись?»: a stop by mistake cut many recordings short.
    @State private var confirmStopRecording = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let compact = !wide && geometry.size.height < 900
            // Recording without a training (here or on the linked Mac), or «Только камера»: the picture takes the
            // screen, the clock (or the way to record or back) floats over it. The camera keeps its place in each
            // layout, so the player is not recreated.
            let clipMode = model.isRecordingClip || (cameraOnly && model.session == nil)
            // One layout for both orientations, switched with `AnyLayout`: the camera stays the same view when the
            // phone turns. In two `if wide` branches it was a new one each time, and its new player connected to the
            // camera again.
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 10))
            let edge: CGFloat = clipMode ? 0 : 12
            // Display Zoom on a small iPhone (320 pt), a phone on its side: the bar is under ~330 pt.
            let narrowBar = (wide ? min(420, geometry.size.width * 0.45) : geometry.size.width - 24) < 326
            // A drawer is open (the trainer's text, the exit's details): one layer under it over the rest of the
            // screen closes it on a tap and presses nothing. It dims the bar and the card, not the camera.
            let veiled = (showTrainerText || showDetails) && model.session != nil && !clipMode
            layout {
                if !wide {
                    topBar(narrow: narrowBar)
                        .padding(.horizontal, 12)
                        .overlay {
                            if veiled {
                                ModalVeil(onClose: closeDrawers)
                                    .padding(.top, -geometry.safeAreaInsets.top)
                                    .padding(.bottom, -5)
                            }
                        }
                    if model.performance.isRunning {
                        performanceBar.padding(.horizontal, 12)
                            .overlay { if veiled { ModalVeil(onClose: closeDrawers).padding(.vertical, -5) } }
                    }
                }
                cameraArea
                    .overlay(alignment: .top) {
                        if wide && clipMode { topBar(narrow: narrowBar).padding(12).transition(.opacity) }
                    }
                    .overlay(alignment: .bottom) { clipOverlay(clipMode) }
                    .overlay(alignment: .bottomTrailing) { cameraCorner(clipMode) }
                    .padding(.horizontal, wide ? 0 : edge)
                    // Over the gaps to the bar and the card too: a tap there closes the drawer as well.
                    .overlay { if veiled { ModalVeil(dims: false, onClose: closeDrawers).padding(.vertical, wide ? 0 : -10) } }
                if !clipMode {
                    if wide {
                        VStack(spacing: 12) {
                            topBar(narrow: narrowBar)
                                .overlay { if veiled { ModalVeil(onClose: closeDrawers).padding(-6) } }
                            if model.performance.isRunning { performanceBar }
                            Spacer(minLength: 0)
                            bottomContent(compact: false)
                        }
                        .frame(width: min(420, geometry.size.width * 0.45))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        bottomContent(compact: compact)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(wide ? EdgeInsets(top: edge, leading: edge, bottom: edge, trailing: edge)
                          : EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: clipMode)
            .overlay(alignment: wide ? .bottomTrailing : .bottom) {
                if showTrainerText, let session = model.session, !clipMode {
                    TrainerTextDrawer(session: session, available: geometry.size.height,
                                      bottomInset: geometry.safeAreaInsets.bottom,
                                      onFinish: { confirmFinish = true },
                                      onClose: { withAnimation(.smooth(duration: 0.3)) { showTrainerText = false } })
                        .frame(maxWidth: wide ? min(420, geometry.size.width * 0.45) : 560)
                        .padding(.horizontal, wide ? 12 : 0)
                        // Down to the screen's edge, under the home indicator.
                        .padding(.bottom, -geometry.safeAreaInsets.bottom)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .modifier(LinkNoticeOverlay())
        #endif
        .task(id: model.settings.streamName) { await model.refreshXiaomiQuality() }
        .task(id: model.settings.secondStreamName) { await model.refreshSecondCameraSource() }
        // Camera modes also through a linked Mac: they live in the camera.
        .task(id: model.cameraModesKey) {
            model.panTilt.stop()
            await model.refreshCameraModes()
        }
        .onChange(of: model.canPanTilt) { _, can in if !can { model.panTilt.stop() } }
        // A finger still on an arrow when the app goes away would never lift.
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.panTilt.stop() } }
        .onChange(of: model.session != nil) { _, running in
            if running {
                cameraOnly = false
            } else {
                showTrainerText = false
                showDetails = false
                // Ended elsewhere (on the linked Mac, or the last break ran out): these would act on no training, and
                // «Отменить без сохранения» would delete a recording started after it.
                confirmFinish = false
                confirmAbandon = false
                editingSessionPlan = nil
            }
        }
        .onChange(of: model.isReconnecting) { _, reconnecting in
            // While the link is being restored their «Завершить» / «Отменить без сохранения» would reach no one.
            if reconnecting {
                confirmFinish = false
                confirmAbandon = false
                confirmStopRecording = false
            }
        }
        .onChange(of: model.settings.isConfigured) { _, configured in
            if configured { showCameraSetup = false }
        }
        .onAppear {
            #if DEBUG
            // `--demo-screen plan|camera|camera-setup|settings|history|session-plan` opens a sheet right away (UI checks
            // without tapping).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-screen"), index + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[index + 1] {
                case "plan": showPlanInput = true
                case "plan-twice":
                    showPlanInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showPlanInput = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showPlanInput = true }
                case "camera": showCameraPicker = true
                case "camera-setup": showCameraSetup = true
                case "settings", "settings-sync": showSettings = true
                case "history", "history-last": showHistory = true
                case "session-plan":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { editingSessionPlan = model.session?.plan }
                default: break
                }
            }
            // `--demo-camera-only`: «Только камера»; `--demo-pan-tilt` (with `--demo-camera-modes`): the turning mode on;
            // `--demo-trainer-text`: the trainer's text open over the running training.
            if CommandLine.arguments.contains("--demo-camera-only") { cameraOnly = true }
            // `--demo-confirm-stop` (with `--demo-recording`): «Остановить запись?» as after a press on REC.
            if CommandLine.arguments.contains("--demo-confirm-stop") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { confirmStopRecording = model.isRecordingNow }
            }
            // `--demo-details`: the exit's details open above the card.
            if CommandLine.arguments.contains("--demo-details") { showDetails = true }
            if CommandLine.arguments.contains("--demo-trainer-text") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showTrainerText = true }
            }
            if CommandLine.arguments.contains("--demo-pan-tilt") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.panTilt.start() }
            }
            #endif
        }
        .sheet(isPresented: $showPlanInput) {
            PlanInputView(initialText: Self.demoPlanText) { plan in
                model.startSession(with: plan)
            }
            .environment(model)
            .sheetFrame()
        }
        .sheet(item: $editingPending) { plan in
            NavigationStack {
                PlanEditorView(plan: plan) { final in
                    model.startSession(with: final)
                    editingPending = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { editingPending = nil } }
                }
            }
            .environment(model)
            .sheetFrame()
        }
        .sheet(item: $editingSessionPlan) { plan in
            NavigationStack {
                PlanEditorView(plan: plan, fixedExits: model.session?.fixedExitCount ?? 0) { final in
                    if model.isReconnecting {
                        // The edit would not reach the Mac, and its next state would undo it here: it stays in the
                        // editor until the link is back.
                        model.errorMessage = String(localized: "Нет связи с \(model.linkedHostKind) — переподключаемся…")
                    } else if model.session?.updatePlan(final) == true {
                        editingSessionPlan = nil
                    } else {
                        model.errorMessage = String(localized: "Прошедшие выходы и текущий нельзя удалить или переставить.")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { editingSessionPlan = nil } }
                }
            }
            .environment(model)
            .sheetFrame()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView().environment(model).sheetFrame(width: 720, height: 640)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(model).sheetFrame()
        }
        .sheet(isPresented: $showCameraSetup) {
            OnboardingFlow(onClose: { showCameraSetup = false })
                .environment(model)
                .sheetFrame(width: 520, height: 640)
        }
        .sheet(isPresented: $showCameraPicker) {
            NavigationStack {
                CameraPickerView(showsClose: true) { _ in
                    showCameraPicker = false
                }
            }
            .environment(model)
            .sheetFrame(width: 520, height: 560)
        }
        .sheet(isPresented: $showSecondCameraPicker) {
            NavigationStack {
                CameraPickerView(showsClose: true, target: .second) { _ in
                    showSecondCameraPicker = false
                    model.showCamera(second: true)
                }
            }
            .environment(model)
            .sheetFrame(width: 520, height: 560)
        }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Завершить тренировку?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Завершить и сохранить") { model.finishSession() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Запись остановится, лог и видео будут сохранены.")
        }
        .confirmationDialog("Отменить тренировку?", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("Отменить без сохранения", role: .destructive) { model.abandonSession() }
            Button("Продолжить", role: .cancel) {}
        }
        .confirmationDialog("Остановить запись?", isPresented: $confirmStopRecording, titleVisibility: .visible) {
            Button("Остановить запись", role: .destructive) { model.stopRecording(deleteFile: false) }
            Button("Продолжить запись", role: .cancel) {}
        } message: {
            if model.session != nil {
                Text("Тренировка продолжится без видео. То, что уже записано, сохранится.")
            } else if model.isLinkedToMac {
                Text("Видео сохранится на \(model.linkedHostKind).")
            } else {
                Text("Видео сохранится в истории.")
            }
        }
        // Stopped elsewhere (on the linked Mac, by «Завершить»): nothing left to stop.
        .onChange(of: model.isRecordingNow) { _, recording in if !recording { confirmStopRecording = false } }
    }

    /// A tap on the layer under the trainer's text or the exit's details.
    private func closeDrawers() {
        withAnimation(.smooth(duration: 0.3)) {
            showTrainerText = false
            showDetails = false
        }
    }

    /// The paste screen opens empty. DEBUG `--demo-parse` with `-demoPlanText <text>`: that text, already parsed
    /// (screenshots).
    private static var demoPlanText: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "demoPlanText") ?? ""
        #else
        return ""
        #endif
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraArea: some View {
        if hasNoCamera {
            // Not inside the zoom view: its content takes no touches, and «Подключить камеру…» needs them.
            NoCameraView(onConnect: { showCameraSetup = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZoomableView { camera }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay { if model.panTilt.isActive && model.canPanTilt { PanTiltFrame().transition(.opacity) } }
        }
    }

    @ViewBuilder
    private func clipOverlay(_ clipMode: Bool) -> some View {
        if clipMode {
            Group {
                if model.isRecordingClip {
                    ClipRecordingOverlay(onStop: { confirmStopRecording = true })
                } else {
                    CameraOnlyOverlay(onRecord: { model.startRecording() },
                                      onClose: { cameraOnly = false })
                }
            }
            .frame(maxWidth: 520)
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The picture's bottom-right corner: «повернуть камеру» and «на весь экран» — or, while turning, the pad. Above
    /// the floating panel when the picture takes the screen.
    @ViewBuilder
    private func cameraCorner(_ clipMode: Bool) -> some View {
        let turning = model.panTilt.isActive && model.canPanTilt
        let canExpand = !clipMode && model.session == nil && !hasNoCamera
        Group {
            if turning {
                PanTiltPad(diameter: 132)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            } else if model.canPanTilt || canExpand {
                HStack(spacing: 8) {
                    if model.canPanTilt {
                        CornerButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                                     label: String(localized: "Повернуть камеру")) {
                            withAnimation(.smooth(duration: 0.25)) { model.panTilt.start() }
                        }
                    }
                    if canExpand {
                        CornerButton(systemImage: "arrow.up.left.and.arrow.down.right",
                                     label: String(localized: "Только камера")) {
                            cameraOnly = true
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        // Clear of the clock / «Только камера» panel (~64 pt) at the bottom.
        .padding(.bottom, clipMode ? 72 : 0)
        .animation(.smooth(duration: 0.25), value: turning)
    }

    @ViewBuilder
    private var camera: some View {
        #if DEBUG && os(iOS)
        // `--demo-camera=<path>`: a still picture instead of the stream (UI checks in the simulator); the second
        // camera is the same picture mirrored.
        if let image = DemoData.cameraImage {
            ZStack {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .opacity(model.isShowingSecondCamera ? 0 : 1)
                if model.hasSecondCamera {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .opacity(model.isShowingSecondCamera ? 1 : 0)
                }
            }
        } else {
            liveCamera
        }
        #else
        liveCamera
        #endif
    }

    /// Started without a camera (and not watching a Mac's): the timer works, the camera can be added.
    private var hasNoCamera: Bool {
        !model.isLinkedToMac && !model.settings.isConfigured
    }

    @ViewBuilder
    private var liveCamera: some View {
        if !model.isLinkedToMac, model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.activeServer, !model.activeStreamName.isEmpty {
            // Both cameras play all the time: the switcher only shows one, so switching never reconnects.
            ZStack {
                CameraStreamView(server: server,
                                 stream: model.activeStreamName,
                                 mode: model.activePlayerMode,
                                 audioEnabled: model.settings.audioEnabled && !model.isShowingSecondCamera,
                                 reloadToken: reloadToken + model.activePlayerGeneration,
                                 onVideoSize: { size in model.videoSize = size },
                                 onDelay: { model.performance.notePlayerDelay(buffer: $0, network: $1) })
                    .opacity(model.isShowingSecondCamera ? 0 : 1)
                    .allowsHitTesting(!model.isShowingSecondCamera)
                if model.hasSecondCamera {
                    CameraStreamView(server: server,
                                     stream: model.activeSecondStreamName,
                                     mode: model.activePlayerMode,
                                     audioEnabled: model.settings.audioEnabled && model.isShowingSecondCamera,
                                     reloadToken: reloadToken + model.activeSecondPlayerGeneration,
                                     onVideoSize: { size in model.secondVideoSize = size },
                                     onDelay: { _, _ in })
                        .opacity(model.isShowingSecondCamera ? 1 : 0)
                        .allowsHitTesting(model.isShowingSecondCamera)
                }
            }
        } else if model.isLinkedCameraNotShared {
            CameraPlaceholder(text: String(localized: "Видео с камеры показывается только на \(model.linkedHostKind)"))
        } else {
            CameraPlaceholder(text: model.isLinkedToMac ? String(localized: "На \(model.linkedHostKind) не выбрана камера") : String(localized: "Камера не выбрана"))
        }
    }

    // MARK: - Top bar

    /// What fits folds in turn: the cameras' names first, then «Mac» to its icon, then «REC» to the clock; on the
    /// narrowest bars (Display Zoom) the trainer's text goes into •••. Never wider than the screen: a wider bar pushed
    /// the whole screen, camera and card, past its right edge.
    private func topBar(narrow: Bool) -> some View {
        HStack(spacing: 8) {
            if hasNoCamera {
                Button { showCameraSetup = true } label: {
                    Pill(text: String(localized: "Без камеры"), systemImage: "video.slash", tint: .white.opacity(0.85))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                if model.hasSecondCamera {
                    CameraSwitcher(onReconnect: { model.videoSize = nil; model.secondVideoSize = nil; reloadToken += 1 },
                                   onPickCamera: { showCameraPicker = true },
                                   onPickSecondCamera: { showSecondCameraPicker = true })
                } else {
                    CameraMenu(onReconnect: { model.videoSize = nil; model.secondVideoSize = nil; reloadToken += 1 }, onPickCamera: { showCameraPicker = true },
                               onPickSecondCamera: { showSecondCameraPicker = true })
                }
                RecordingPill(onStop: { confirmStopRecording = true })
                    .disabled(model.isReconnecting)
                    // Folds last: the cameras' names and «Mac» go first.
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            LinkPill(foldsToIcon: true)
                .layoutPriority(-0.5)
            let hasTrainerText = model.session.map { !$0.plan.rawText.isEmpty } ?? false
            if hasTrainerText, !narrow {
                IconButton(systemImage: showTrainerText ? "doc.text.fill" : "doc.text",
                           tint: showTrainerText ? Theme.accent : .white) {
                    withAnimation(.smooth(duration: 0.3)) { showDetails = false; showTrainerText.toggle() }
                }
                .accessibilityLabel("Текст тренера")
            }
            if model.session != nil {
                SessionMenu(onTrainerText: hasTrainerText && narrow ? {
                                withAnimation(.smooth(duration: 0.3)) { showDetails = false; showTrainerText.toggle() }
                            } : nil,
                            onEditPlan: {
                                if let session = model.session, !session.isFinished { editingSessionPlan = session.plan }
                            },
                            onFinish: { confirmFinish = true },
                            onAbandon: { confirmAbandon = true })
                .disabled(model.isReconnecting)
            } else {
                IconButton(systemImage: "clock.arrow.circlepath", label: String(localized: "История")) { showHistory = true }
                IconButton(systemImage: "gearshape", label: String(localized: "Настройки")) { showSettings = true }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// Only rendered while the diagnostics overlay is on; it observes the sampler on its own.
    @ViewBuilder
    private var performanceBar: some View {
        PerformanceBar()
    }

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle, .starting: return String(localized: "Запускаем go2rtc…")
        case .failed(let message): return message
        case .unavailable: return String(localized: "Встроенный go2rtc не собран")
        case .running: return ""
        }
    }

    // MARK: - Bottom

    @ViewBuilder
    private func bottomContent(compact: Bool) -> some View {
        if let session = model.session {
            SessionHUD(session: session, compact: compact, expanded: $showDetails, onFinish: { confirmFinish = true })
                // A Mac's training while its link is being restored: presses could not reach it.
                .disabled(model.isReconnecting)
                .frame(maxWidth: 560)
        } else if let record = model.lastRecord {
            SummaryCard(record: record, onClose: { model.lastRecord = nil }, onHistory: { showHistory = true })
                .frame(maxWidth: 560)
        } else if let clip = model.lastClip {
            ClipSavedCard(clip: clip, onClose: { model.lastClip = nil }, onHistory: { showHistory = true })
                .frame(maxWidth: 560)
        } else {
            #if os(iOS)
            MacLinkCard()
                .frame(maxWidth: 560)
            #endif
            if let pending = model.macPendingPlan {
                #if os(iOS)
                MacPendingPlanCard(plan: pending, onEdit: { editingPending = pending }, onPaste: { showPlanInput = true })
                    .frame(maxWidth: 560)
                #endif
            } else {
                PlanEntryCard(
                    canRecord: !hasNoCamera,
                    onPaste: { showPlanInput = true },
                    onRecordOnly: { model.startRecording() })
                .frame(maxWidth: 560)
            }
        }
    }
}

/// Card shown before a session: paste the schedule, or record without one.
struct PlanEntryCard: View {
    @Environment(AppModel.self) private var model
    /// A camera is there (own or the linked Mac's): video can be recorded.
    var canRecord = true
    var onPaste: () -> Void
    /// Video only: no plan, no log.
    var onRecordOnly: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Новая тренировка")
                    .font(Theme.display(22, weight: .bold))
                Text("Вставьте расписание от тренера и проверьте выходы.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                if canRecord {
                    Toggle(isOn: $settings.autoRecord) {
                        Label("Записывать видео", systemImage: "record.circle")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                    }
                    .tint(Theme.accent)
                }
                BigButton(title: String(localized: "Вставить расписание"), systemImage: "doc.on.clipboard", action: onPaste)
                if canRecord {
                    BigButton(title: String(localized: "Только запись"), systemImage: "record.circle",
                              style: .secondary, height: 44, action: onRecordOnly)
                }
            }
        }
    }
}


/// Camera name pill with its menu. Separate view so per-second updates elsewhere do not rebuild an open menu.
/// As a segment of `CameraSwitcher` it is the selected camera's name. The camera modes are the shown camera's;
/// so is the quality (of the picture and of the recording).
private struct CameraMenu: View {
    @Environment(AppModel.self) private var model
    var onReconnect: () -> Void
    var onPickCamera: () -> Void
    var onPickSecondCamera: () -> Void
    /// In the switcher: the selected segment's look instead of the pill.
    var segment: String? = nil

    var body: some View {
        Menu {
            if model.isLinkedToMac {
                Text("Камеру и качество выбирают на \(model.linkedHostKind)")
            } else {
                Button("Выбрать камеру…", systemImage: "video.badge.plus", action: onPickCamera)
                Button(model.hasSecondCamera ? "Другая вторая камера…" : "Вторая камера…", systemImage: "rectangle.on.rectangle",
                       action: onPickSecondCamera)
                if model.hasSecondCamera {
                    Button("Убрать вторую камеру", systemImage: "rectangle.badge.minus", role: .destructive) {
                        model.removeSecondCamera()
                    }
                }
                #if os(iOS)
                // Always here, unlike the «Рядом Mac» card (closed, or pushed out by a summary).
                if model.session == nil {
                    HostChoiceMenu()
                }
                #endif
            }
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            // The quality of the camera on screen, the one recorded.
            let second = model.isShowingSecondCamera
            if !model.isLinkedToMac, let quality = second ? model.secondXiaomiQuality : model.xiaomiQuality {
                Menu {
                    Picker("Качество", selection: Binding(
                        get: { quality },
                        set: { newValue in
                            Task { await model.setXiaomiQuality(newValue, second: second) }
                        })) {
                        ForEach(AppModel.XiaomiQuality.allCases) { q in
                            Text(model.qualityTitle(q, source: second ? model.secondXiaomiSource : nil)).tag(q)
                        }
                    }
                    Text("Записи — в этом же качестве")
                    if let size = second ? model.secondVideoSize : model.videoSize {
                        Divider()
                        Button("Сейчас \(Int(size.width))×\(Int(size.height))", systemImage: "info.circle") {}
                            .disabled(true)
                    }
                } label: {
                    Label("Качество · \(quality.title)", systemImage: "sparkles.tv")
                }
            }
            CameraModeMenuItems()
            Toggle("Звук", systemImage: "speaker.wave.2", isOn: Binding(
                get: { model.settings.audioEnabled },
                set: { model.settings.audioEnabled = $0 }))
        } label: {
            if let segment {
                CameraSegmentLabel(title: segment, selected: true)
            } else {
                // The whole name, or just the icon when the bar is busy (REC, «Mac»): «Xi…» says nothing.
                ViewThatFits(in: .horizontal) {
                    Pill(text: model.activeCameraName, systemImage: "video.fill")
                    Image(systemName: "video.fill")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 34)
                        .background(Theme.control, in: Capsule())
                }
                .accessibilityLabel(model.activeCameraName)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .layoutPriority(segment == nil ? -1 : 0)
    }
}

/// «Прихожая · Комната»: which camera is on screen. The other one keeps playing (the green dot) and a tap brings it;
/// a tap on the one on screen opens its menu. The one on screen is recorded (and shown on a linked Mac too).
private struct CameraSwitcher: View {
    @Environment(AppModel.self) private var model
    var onReconnect: () -> Void
    var onPickCamera: () -> Void
    var onPickSecondCamera: () -> Void

    var body: some View {
        let names = CameraShortNames.make(model.activeCameraName, model.activeSecondCameraName)
        let shown = model.isShowingSecondCamera
        // What fits: both names; the shown one's name and the other's number; both numbers. The bar's width doesn't
        // change by the second (REC keeps its width), so the choice holds.
        ViewThatFits(in: .horizontal) {
            row(names.0, names.1)
            row(shown ? "1" : names.0, shown ? names.1 : "2")
            row("1", "2")
        }
        .layoutPriority(-1)
    }

    private func row(_ first: String, _ second: String) -> some View {
        HStack(spacing: 2) {
            segment(second: false, title: first)
            segment(second: true, title: second)
        }
        .padding(2)
        .background(Theme.control, in: Capsule())
    }

    @ViewBuilder
    private func segment(second: Bool, title: String) -> some View {
        if model.isShowingSecondCamera == second {
            CameraMenu(onReconnect: onReconnect, onPickCamera: onPickCamera, onPickSecondCamera: onPickSecondCamera,
                       segment: title)
        } else {
            Button {
                withAnimation(.smooth(duration: 0.2)) { model.showCamera(second: second) }
            } label: {
                CameraSegmentLabel(title: title, selected: false)
            }
            .buttonStyle(.plain)
            // The Mac's link is being restored: the switch could not reach it, and the Mac would go on recording the
            // other camera.
            .disabled(model.isReconnecting)
            .accessibilityLabel(String(localized: "Показать камеру «\(title)»"))
        }
    }
}

private struct CameraSegmentLabel: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if selected {
                Image(systemName: "video.fill").font(.system(size: 11, weight: .semibold))
            } else {
                // Still connected: switching back is instant.
                Circle().fill(Color(red: 0.43, green: 0.91, blue: 0.63)).frame(width: 6, height: 6)
            }
            Text(title).lineLimit(1)
        }
        .fixedSize()
        .font(.system(.subheadline, design: .rounded, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? .white : .white.opacity(0.6))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(selected ? Color.white.opacity(0.16) : .clear, in: Capsule())
        .contentShape(Capsule())
    }
}

/// ••• during a training. Its own view: the screen's updates don't rebuild an open menu (it used to blink).
private struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    /// The trainer's text when the bar has no room for its button.
    var onTrainerText: (() -> Void)? = nil
    var onEditPlan: () -> Void
    var onFinish: () -> Void
    var onAbandon: () -> Void

    var body: some View {
        Menu {
            if let onTrainerText {
                Button("Текст тренера", systemImage: "doc.text", action: onTrainerText)
            }
            Button("Изменить расписание", systemImage: "slider.horizontal.3", action: onEditPlan)
            Button(model.finishTitle, systemImage: "flag.checkered", action: onFinish)
            Button("Отменить без сохранения", systemImage: "xmark.circle", role: .destructive, action: onAbandon)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.control, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Тренировка")
    }
}

/// REC indicator / toggle; the one-second clock lives inside this view only. Where the bar has no room it folds to the
/// clock alone («⏺ 23:22»), or to the icon when nothing is recorded.
private struct RecordingPill: View {
    @Environment(AppModel.self) private var model
    /// A stop asks first (`SessionScreen`); a start doesn't.
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button {
                if model.isRecordingNow { onStop() } else { model.toggleRecording() }
            } label: {
                ViewThatFits(in: .horizontal) {
                    label(at: context.date, short: false)
                    label(at: context.date, short: true)
                }
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    @ViewBuilder
    private func label(at date: Date, short: Bool) -> some View {
        if model.isRecordingNow {
            // Digits of one width and room for «REC 00:00»: the bar is not laid out anew every second.
            let clock = DurationText.clock(model.recordingDuration(at: date))
            let prefix = short ? "" : "REC "
            ZStack {
                Pill(text: prefix + (clock.count > 5 ? "0:00:00" : "00:00"), systemImage: "record.circle.fill").hidden()
                Pill(text: prefix + clock, systemImage: "record.circle.fill", tint: Theme.danger)
            }
            .monospacedDigit()
        } else if !model.isLinkedToMac, model.recorder.lastError != nil {
            Pill(text: String(localized: "Запись не идёт"), systemImage: "exclamationmark.triangle.fill", tint: Theme.warning,
                 iconOnly: short)
        } else {
            Pill(text: String(localized: "Запись"), systemImage: "record.circle", tint: .white.opacity(0.85), iconOnly: short)
        }
    }
}

/// Diagnostics strip (iPhone: under the top bar; Mac: over the picture): the video's delay first, then the app's load.
/// Observes `PerformanceMonitor.sample` so only this view refreshes each second.
struct PerformanceBar: View {
    @Environment(AppModel.self) private var model
    /// iPhone: as wide as the screen; Mac: as wide as its text, in a corner of the picture.
    var fillsWidth = true

    var body: some View {
        let s = model.performance.sample
        VStack(alignment: .leading, spacing: 3) {
            if let delay = s.videoDelayText {
                Text(delay)
                    .fontWeight(.semibold)
                    .foregroundStyle([Color.white, Theme.warning, Theme.danger][s.videoDelayLevel])
            }
            HStack(spacing: 10) {
                Text(String(format: "CPU %.0f%% · main %.0f%%", s.cpuTotal, s.cpuMain))
                Text("\(s.memoryMB, specifier: "%.0f") МБ")
                Text("UI +\(s.maxHangMs, specifier: "%.0f") мс")
                    .foregroundStyle(s.maxHangMs > 250 ? Theme.danger : (s.maxHangMs > 80 ? Theme.warning : .white))
                Text(pluralText(s.threads, ru: ("поток", "потока", "потоков"), en: ("thread", "threads")))
            }
            .opacity(0.8)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .font(.system(fillsWidth ? .caption2 : .caption, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel.opacity(fillsWidth ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Instead of the camera when the app runs without one: what still works and how to add a camera.
struct NoCameraView: View {
    var onConnect: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                Text("Без камеры")
                    .font(Theme.display(20, weight: .bold))
                Text("Таймеры, расписание и лог работают. С камерой вы увидите собаку, пока вы за дверью, и сможете записывать видео.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button(action: onConnect) {
                    Label("Подключить камеру…", systemImage: "video.badge.plus")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(24)
        }
    }
}

/// A round button in a corner of the picture: dark and translucent so the picture shows round it.
private struct CornerButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// «Только камера»: nothing is recorded; record from here or bring the cards back. Same panel as the recording clock.
struct CameraOnlyOverlay: View {
    var onRecord: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Только камера")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text("Без записи и тренировки")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(action: onRecord) {
                Image(systemName: "record.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 48, height: 48)
                    .background(Theme.control, in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Начать запись")
            Button(action: onClose) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Theme.control, in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Вернуть карточки")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        // Translucent but no blur: a backdrop blur over live video costs the iPhone too much (see GlassCard).
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
