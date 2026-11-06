import SwiftUI
import WaitingPawsCore

/// The main screen: camera in the background, training HUD on top.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// The system's text size, before the top bar caps its own at xxxLarge.
    @Environment(\.dynamicTypeSize) private var typeSize

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
    /// «Остановить запись?»: a stop by mistake cut many recordings short.
    @State private var confirmStopRecording = false
    /// Each camera's zoom: the owner frames the picture, it is remembered per camera (`AppSettings.cameraFraming`).
    @State private var firstZoom = ZoomState(remembers: true)
    @State private var secondZoom = ZoomState(remembers: true)
    /// What each camera's player is doing: shown over the part of the picture on screen, unzoomed.
    @State private var firstStatus = CameraStatus()
    @State private var secondStatus = CameraStatus()

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
            // The trainer's text is open: one layer under it over the rest of the screen closes it on a tap and presses
            // nothing. It dims the bar and the card, not the camera.
            let veiled = showTrainerText && model.session != nil && !clipMode
            // Upright, the camera takes the whole area between the bar and the card: the picture fits in it (in the
            // middle, nothing cropped) and the owner zooms it in to fill it (`ZoomableView`). The card is one height
            // in every phase — at every text size (`SessionReadout`) — so the picture stays put through a whole
            // training; only the trainer's text moves it: the area is then the picture's own height under the bar,
            // above the drawer.
            let pictureHeight = (geometry.size.width - 2 * edge) / cameraAspect
            let fillsArea = !wide && !clipMode && !hasNoCamera
            let underBar = fillsArea && showTrainerText
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
                cameraArea(clipMode: clipMode)
                    .overlay(alignment: .top) {
                        if wide && clipMode { topBar(narrow: narrowBar).padding(12).transition(.opacity) }
                    }
                    .overlay(alignment: .bottom) { clipOverlay(clipMode) }
                    // Otherwise on the picture itself (`cameraArea`).
                    .overlay(alignment: .bottomTrailing) { if clipMode { cameraCorner(clipMode) } }
                    .padding(.horizontal, wide ? 0 : edge)
                    // Over the gaps to the bar and the card too: a tap there closes the drawer as well.
                    .overlay { if veiled { ModalVeil(dims: false, onClose: closeDrawers).padding(.vertical, wide ? 0 : -10) } }
                    .frame(maxHeight: underBar ? pictureHeight : .infinity)
                    // Upright, the card is laid out first and the camera takes what is left.
                    .layoutPriority(fillsArea && !underBar ? -1 : 1)
                if underBar {
                    Spacer(minLength: 0)
                        .overlay { if veiled { ModalVeil(dims: false, onClose: closeDrawers) } }
                }
                if !clipMode {
                    if wide {
                        VStack(spacing: 12) {
                            topBar(narrow: narrowBar)
                                .overlay { if veiled { ModalVeil(onClose: closeDrawers).padding(-6) } }
                            if model.performance.isRunning { performanceBar }
                            Spacer(minLength: 0)
                            // Offered the column's height first: the card fits it, scrolling its middle if it must
                            // (`SessionReadout`); smaller numbers on a short screen (a small iPhone on its side).
                            bottomContent(compact: geometry.size.height < 500)
                                .layoutPriority(1)
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
            if CommandLine.arguments.contains("--demo-trainer-text") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showTrainerText = true }
            }
            if CommandLine.arguments.contains("--demo-pan-tilt") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.panTilt.start() }
            }
            #if os(iOS)
            if DemoData.cameraImage != nil { applyDemoCamera() }
            #endif
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

    /// A tap on the layer under the trainer's text.
    private func closeDrawers() {
        withAnimation(.smooth(duration: 0.3)) { showTrainerText = false }
    }

    #if DEBUG && os(iOS)
    /// The demo picture plays (no player reports it). `--demo-stream=stalled|reconnecting|failed`: the shown camera's
    /// frame stopped 12 s ago, `connecting`: no frame yet. `--demo-zoom=<scale>[@x,y]` (or `fill`): the shown camera
    /// framed so — and remembered, as a pinch would leave it (relaunch without it to see it kept); `in`: as after a press
    /// on «Приблизить». One argument each, as on the Mac.
    private func applyDemoCamera() {
        let argument = { (prefix: String) in
            CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        let second = model.isShowingSecondCamera
        firstStatus.demo(.playing, age: nil)
        secondStatus.demo(.playing, age: nil)
        let status = second ? secondStatus : firstStatus
        switch argument("--demo-stream=") {
        case "stalled": status.demo(.stalled, age: 12)
        case "reconnecting": status.demo(.connecting, age: 12)
        case "failed": status.demo(.failed(String(localized: "нет ответа")), age: 12)
        case "connecting": status.demo(.connecting, age: nil)
        default: break
        }
        guard let raw = argument("--demo-zoom=") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let zoom = second ? secondZoom : firstZoom
            // `in`: a press on «Приблизить».
            if raw == "in" { return zoom.toggleZoomIn() }
            let parts = raw.split(separator: "@")
            let point = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            let scale = parts.first == "fill" ? zoom.fillScale : CGFloat(Double(parts.first ?? "") ?? 2)
            zoom.frame(scale: scale, x: point.count == 2 ? point[0] : 0.5, y: point.count == 2 ? point[1] : 0.5)
        }
    }
    #endif

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

    /// The picture in the area it has: pinch, drag and double tap frame it, per camera (both cameras keep their own
    /// framing, across launches). Over the part of it on screen, unzoomed: the stream's state, the turning frame and,
    /// outside «Только камера», the corner buttons.
    @ViewBuilder
    private func cameraArea(clipMode: Bool) -> some View {
        if hasNoCamera {
            // Not inside the zoom view: its content takes no touches, and «Подключить камеру…» needs them.
            NoCameraView(onConnect: { showCameraSetup = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let second = model.isShowingSecondCamera
            // In a training the way back to the whole picture is the corner's `CameraZoomButton`, not a pill at the top.
            ZoomableView(zoom: second ? secondZoom : firstZoom, aspect: cameraAspect,
                         showsZoomPill: !(model.session != nil && !clipMode)) {
                camera
            } chrome: {
                if showsStreamStatus {
                    // «Нет кадра 18 с» alone: REC in the bar says the recording goes on.
                    CameraStatusOverlay(status: second ? secondStatus : firstStatus, showsRecording: false)
                }
                if model.panTilt.isActive && model.canPanTilt { PanTiltFrame().transition(.opacity) }
                if !clipMode {
                    cameraCorner(clipMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .modifier(RememberedFraming(zoom: firstZoom, camera: model.activeStreamName, settings: model.settings))
            .modifier(RememberedFraming(zoom: secondZoom, camera: model.activeSecondStreamName, settings: model.settings))
        }
    }

    /// The live player is on screen (not a placeholder): its state is worth showing.
    private var showsStreamStatus: Bool {
        #if DEBUG && os(iOS)
        if DemoData.cameraImage != nil { return true }
        #endif
        if !model.isLinkedToMac, model.settings.connectionMode == .embedded, !model.embedded.status.isRunning { return false }
        return model.activeServer != nil && !model.activeStreamName.isEmpty
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

    /// The picture's bottom-right corner: ✥ «Повернуть камеру» and ⤢ «Только камера» before a training (and after it),
    /// 🔍 «Приблизить» ↔ «Весь кадр» during one — signs alone, their words for VoiceOver and the Large Content Viewer
    /// (`CameraCornerButton`): words there lay over the dog — or, while turning, the pad. Above the floating panel when
    /// the picture takes the screen. The buttons are 40 pt with 2 pt of touch round them (44 pt), 12 pt from the
    /// picture's edges.
    private func cameraCorner(_ clipMode: Bool) -> some View {
        cameraCornerButtons(clipMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    @ViewBuilder
    private func cameraCornerButtons(_ clipMode: Bool) -> some View {
        let turning = model.panTilt.isActive && model.canPanTilt
        let canExpand = !clipMode && model.session == nil && !hasNoCamera
        // In a training: closer (the camera's remembered framing) or all of the picture — always there.
        let framing = !clipMode && model.session != nil && !hasNoCamera
        Group {
            if turning {
                PanTiltPad(diameter: 132)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            } else if model.canPanTilt || canExpand || framing {
                HStack(spacing: 4) {
                    if model.canPanTilt {
                        CameraCornerButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                                           title: String(localized: "Повернуть камеру"), showsTitle: false) {
                            withAnimation(.smooth(duration: 0.25)) { model.panTilt.start() }
                        }
                    }
                    if canExpand {
                        CameraCornerButton(systemImage: "arrow.up.left.and.arrow.down.right",
                                           title: String(localized: "Только камера"), showsTitle: false) {
                            cameraOnly = true
                        }
                    }
                    if framing {
                        CameraZoomButton(zoom: model.isShowingSecondCamera ? secondZoom : firstZoom, showsTitle: false)
                    }
                }
                .transition(.opacity)
                // The buttons' touch reaches 2 pt past what is drawn.
                .padding(-2)
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
                demoPicture(image)
                    .opacity(model.isShowingSecondCamera ? 0 : 1)
                if model.hasSecondCamera {
                    demoPicture(image)
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

    #if DEBUG && os(iOS)
    /// The demo still letterboxed in the area on black, as the live player shows it.
    private func demoPicture(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    /// Width over height of the picture shown (16:9 until the stream says).
    private var cameraAspect: CGFloat {
        #if DEBUG && os(iOS)
        if let image = DemoData.cameraImage, image.size.height > 0 { return image.size.width / image.size.height }
        #endif
        let size = model.isShowingSecondCamera ? model.secondVideoSize : model.videoSize
        guard let size, size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
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
                                 status: firstStatus,
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
                                     status: secondStatus,
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

    /// What fits folds in turn. One camera: its name first, then «Mac» to its icon, then «REC» to the clock. Two
    /// cameras: «Mac» first, then the other camera's name to the switch sign, the shown one's to the camera sign, then
    /// «REC». On the narrowest bars (Display Zoom) the trainer's text goes into •••. Never wider than the screen: a wider bar pushed
    /// the whole screen, camera and card, past its right edge. As a system bar, its chips grow with the text up to
    /// xxxLarge and no further; at the accessibility sizes a long press shows each one in the Large Content Viewer
    /// (design council, round 9: in AX type «REC 1:29» was the screen's largest words and the camera lost its name).
    private func topBar(narrow: Bool) -> some View {
        HStack(spacing: 8) {
            if hasNoCamera {
                Button { showCameraSetup = true } label: {
                    Pill(text: String(localized: "Без камеры"), systemImage: "video.slash", tint: .white.opacity(0.85))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                // At the accessibility sizes the camera keeps its name ahead of «REC», which folds to its clock (Opus,
                // round 9: the name went first and «REC 1:29» was left the bar's largest words).
                let camerasFirst = typeSize.isAccessibilitySize
                if model.hasSecondCamera {
                    CameraSwitcher(statuses: (firstStatus, secondStatus),
                                   onReconnect: { model.videoSize = nil; model.secondVideoSize = nil; reloadToken += 1 },
                                   onPickCamera: { showCameraPicker = true },
                                   onPickSecondCamera: { showSecondCameraPicker = true })
                    .layoutPriority(camerasFirst ? 2 : 0.5)
                } else {
                    // The dot says whether the picture comes, as the other camera's does in the switcher and each
                    // camera's in the picker (Fable, round 9).
                    CameraMenu(onReconnect: { model.videoSize = nil; model.secondVideoSize = nil; reloadToken += 1 }, onPickCamera: { showCameraPicker = true },
                               onPickSecondCamera: { showSecondCameraPicker = true },
                               status: showsStreamStatus ? (model.isShowingSecondCamera ? secondStatus : firstStatus) : nil)
                    .layoutPriority(camerasFirst ? 2 : -1)
                }
                if showsRecordingPill {
                    RecordingPill(onStop: { confirmStopRecording = true })
                        .disabled(model.isReconnecting)
                        // Folds last: the cameras' names and «Mac» go first.
                        .layoutPriority(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 4)
            LinkPill(foldsToIcon: true)
                .accessibilityShowsLargeContentViewer()
                .layoutPriority(-0.5)
            let hasTrainerText = model.session.map { !$0.plan.rawText.isEmpty } ?? false
            if hasTrainerText, !narrow {
                IconButton(systemImage: showTrainerText ? "doc.text.fill" : "doc.text",
                           tint: showTrainerText ? Theme.accent : .white) {
                    withAnimation(.smooth(duration: 0.3)) { showTrainerText.toggle() }
                }
                .accessibilityLabel("Текст тренера")
                .accessibilityShowsLargeContentViewer {
                    Label("Текст тренера", systemImage: "doc.text")
                }
            }
            if model.session != nil {
                SessionMenu(onTrainerText: hasTrainerText && narrow ? {
                                withAnimation(.smooth(duration: 0.3)) { showTrainerText.toggle() }
                            } : nil,
                            onEditPlan: {
                                if let session = model.session, !session.isFinished { editingSessionPlan = session.plan }
                            },
                            onFinish: { confirmFinish = true },
                            onAbandon: { confirmAbandon = true })
                .disabled(model.isReconnecting)
            } else {
                IconButton(systemImage: "clock.arrow.circlepath", label: String(localized: "История")) { showHistory = true }
                    .accessibilityShowsLargeContentViewer {
                        Label("История", systemImage: "clock.arrow.circlepath")
                    }
                IconButton(systemImage: "gearshape", label: String(localized: "Настройки")) { showSettings = true }
                    .accessibilityShowsLargeContentViewer {
                        Label("Настройки", systemImage: "gearshape")
                    }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The bar's REC: while something is recorded (its clock, a press stops it); in a training also before that — the
    /// way to start the recording later, the start having set it; and after a recording broke off. Before a training
    /// the main screen has one way to record, the card's «Записать без тренировки» (or ⦿ in «Только камера»): an idle
    /// «⦿ Запись» up here was a third recording control beside it.
    private var showsRecordingPill: Bool {
        if model.isRecordingNow || model.session != nil { return true }
        return !model.isLinkedToMac && model.recorder.lastError != nil
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
            SessionHUD(session: session, compact: compact, onFinish: { confirmFinish = true })
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

/// Card shown before a session: paste the schedule, or record without one. Its one recording control is that second
/// way: whether a training is recorded is set where it starts — «Записывать видео» over «Начать тренировку и запись» in
/// the plan's review (and in Settings) — and the bar's REC shows only once something records.
struct PlanEntryCard: View {
    /// A camera is there (own or the linked Mac's): video can be recorded.
    var canRecord = true
    var onPaste: () -> Void
    /// Video only: no plan, no log.
    var onRecordOnly: () -> Void

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Новая тренировка")
                    .font(Theme.display(22, weight: .bold))
                BigButton(title: String(localized: "Вставить расписание"), systemImage: "doc.on.clipboard", action: onPaste)
                if canRecord {
                    BigButton(title: String(localized: "Записать без тренировки"), systemImage: "record.circle",
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
    /// The segment as the camera sign alone (the bar has no room for the name).
    var segmentIconOnly = false
    /// The pill's player, for its dot; nil where no live picture is shown (a placeholder, the Mac's camera not shared).
    var status: CameraStatus? = nil

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
                CameraSegmentLabel(title: segment, selected: true, iconOnly: segmentIconOnly)
                    .accessibilityLabel(segment)
            } else {
                // The whole name, or just the icon when the bar is busy (REC, «Mac»): «Xi…» says nothing.
                ViewThatFits(in: .horizontal) {
                    chip(iconOnly: false)
                    chip(iconOnly: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.activeCameraName)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer {
            Label(segment ?? model.activeCameraName, systemImage: "video.fill")
        }
        .layoutPriority(segment == nil ? -1 : 0)
    }

    /// «▶︎ Прихожая ●», as `Pill`; the sign and the dot alone where the name doesn't fit.
    private func chip(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "video.fill")
            if !iconOnly {
                Text(model.activeCameraName).lineLimit(1)
            }
            if let status { CameraLiveDot(status: status) }
        }
        .fixedSize()
        .font(.system(.footnote, design: .rounded, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, iconOnly ? 11 : 12)
        .padding(.vertical, 8)
        .frame(minWidth: 36)
        .background(Theme.control, in: Capsule())
    }
}

/// The shown camera's state as the dot by its name: green while the picture comes, grey while connecting, orange while
/// it stands still, red when the camera doesn't answer. Its own view: the menu around it isn't rebuilt when it changes.
/// VoiceOver hears the state from the picture's own overlay (`CameraStatusOverlay`).
private struct CameraLiveDot: View {
    let status: CameraStatus

    var body: some View {
        let color: Color = switch status.phase {
        case .playing: CameraSegmentLabel.liveGreen
        case .connecting, .waitingForPicture: .white.opacity(0.35)
        case .stalled: Theme.warning
        case .failed: Theme.danger
        }
        Circle().fill(color)
            .frame(width: 6, height: 6)
            .animation(.easeOut(duration: 0.2), value: status.phase)
            .accessibilityHidden(true)
    }
}

/// «Прихожая · ● ▶︎»: which camera is on screen, by its name, and the other one by a small camera sign — its name read
/// as a second button (design council, round 13), a «2» as a count (round 15); VoiceOver hears its name. The other one keeps playing (the green dot while its
/// picture moves) and a tap brings it; a tap on the one on screen opens its menu. The one on screen is recorded (and
/// shown on a linked Mac too).
private struct CameraSwitcher: View {
    @Environment(AppModel.self) private var model
    /// The two players' states: the other camera's dot.
    var statuses: (CameraStatus, CameraStatus)
    var onReconnect: () -> Void
    var onPickCamera: () -> Void
    var onPickSecondCamera: () -> Void

    var body: some View {
        let names = CameraShortNames.make(model.activeCameraName, model.activeSecondCameraName)
        // What fits: the shown one's name, else its camera sign; the other one's number with its dot. The bar's width
        // doesn't change by the second (REC keeps its width), so the choice holds.
        ViewThatFits(in: .horizontal) {
            row(names.0, names.1, shownAsSign: false)
            row(names.0, names.1, shownAsSign: true)
        }
        // Before the spacer (which would take the room) and «Mac»: which camera a tap brings is worth more than the
        // word «Mac» by its icon.
        .layoutPriority(0.5)
    }

    /// The cameras keep their places; the one on screen is the lit segment.
    private func row(_ first: String, _ second: String, shownAsSign: Bool) -> some View {
        HStack(spacing: 2) {
            segment(second: false, title: first, sign: shownAsSign)
            segment(second: true, title: second, sign: shownAsSign)
        }
        .padding(2)
        .background(Theme.control, in: Capsule())
    }

    @ViewBuilder
    private func segment(second: Bool, title: String, sign: Bool) -> some View {
        if model.isShowingSecondCamera == second {
            CameraMenu(onReconnect: onReconnect, onPickCamera: onPickCamera, onPickSecondCamera: onPickSecondCamera,
                       segment: title, segmentIconOnly: sign)
        } else {
            let status = second ? statuses.1 : statuses.0
            Button {
                withAnimation(.smooth(duration: 0.2)) { model.showCamera(second: second) }
            } label: {
                CameraSegmentLabel(title: title, selected: false, live: status.phase == .playing, signOnly: true)
            }
            .buttonStyle(.plain)
            // The Mac's link is being restored: the switch could not reach it, and the Mac would go on recording the
            // other camera.
            .disabled(model.isReconnecting)
            .accessibilityLabel(String(localized: "Показать камеру «\(title)»"))
            .accessibilityShowsLargeContentViewer {
                Label(title, systemImage: "arrow.triangle.2.circlepath.camera")
            }
        }
    }
}

private struct CameraSegmentLabel: View {
    /// The dot of a camera whose picture moves.
    static let liveGreen = Color(red: 0.43, green: 0.91, blue: 0.63)

    let title: String
    let selected: Bool
    /// Only the sign: the camera (the one on screen) or «switch camera» (the other one).
    var iconOnly = false
    /// The other camera's picture moves: switching to it is instant.
    var live = true
    /// The other camera as its dot and a small camera sign, without its name (VoiceOver has the name).
    var signOnly = false

    var body: some View {
        HStack(spacing: 4) {
            if selected {
                Image(systemName: "video.fill").font(.system(size: 11, weight: .semibold))
            } else if iconOnly {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 13, weight: .semibold))
            } else {
                Circle().fill(live ? Self.liveGreen : .white.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
            if signOnly {
                Image(systemName: "video.fill").font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            } else if !iconOnly {
                Text(title).lineLimit(1)
            }
        }
        .fixedSize()
        // The pills' size (REC, «Mac»): both names fit beside «REC 1:28» on the larger iPhones.
        .font(.system(.footnote, design: .rounded, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? .white : .white.opacity(0.6))
        .padding(.horizontal, 8)
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
        .accessibilityShowsLargeContentViewer {
            Label("Тренировка", systemImage: "ellipsis")
        }
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
            .accessibilityShowsLargeContentViewer {
                largeContent(at: context.date)
            }
        }
    }

    /// The Large Content Viewer's words: the whole of what the pill says, whatever it folded to.
    private func largeContent(at date: Date) -> Label<Text, Image> {
        if model.isRecordingNow {
            return Label { Text(verbatim: "REC " + DurationText.clock(model.recordingDuration(at: date))) } icon: {
                Image(systemName: "record.circle.fill")
            }
        } else if !model.isLinkedToMac, model.recorder.lastError != nil {
            return Label("Запись не идёт", systemImage: "exclamationmark.triangle.fill")
        }
        return Label("Запись", systemImage: "record.circle")
    }

    @ViewBuilder
    private func label(at date: Date, short: Bool) -> some View {
        if model.isRecordingNow {
            // «● REC» without its clock: the card's number is the one time on the screen (design council, round 14).
            // VoiceOver and the Large Content Viewer still say how long.
            Pill(text: "REC", systemImage: "record.circle.fill", tint: Theme.danger, iconOnly: short)
                .accessibilityLabel(Text(verbatim: "REC " + DurationText.clock(model.recordingDuration(at: date))))
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
