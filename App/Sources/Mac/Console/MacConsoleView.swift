#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Пульт» — the training window: camera and the readout on top, the session timeline below.
/// Before the start the right panel offers the paste / repeat / record-only ways in and the timeline
/// shows the pasted plan, editable with the mouse; during the session it is the «план и факт» timeline.
/// Space = the next step («Вышли» / «Вернулись»), ⌫ = false start (handled here, not as menu key equivalents, so
/// text fields keep them).
struct MacConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool
    @State private var reloadToken = 0
    @AppStorage("mac.clipHUDPosition") private var hudPosition: ClipRecordingHUD.HUDPosition = .bottom
    /// The panel on the right, resized by its edge (see `ConsolePanelLayout`): the width it was dragged to, nil until
    /// then — on every launch the panel leaves the camera just the picture's width.
    @State private var draggedPanelWidth: Double?
    /// Height of the camera's row, what the picture's width follows from.
    @State private var cameraHeight: CGFloat = 0
    /// The panel's left edge in the window and the window's width: the camera's island in the toolbar stays on the
    /// camera's side of the panel's edge, the panel's groups over the panel. The edge is kept while the panel is folded
    /// away (whatever reads it checks `clipMode`): the window closed and opened again from the Dock keeps this state,
    /// and the panel, back at the same place, reports no edge again.
    @State private var panelEdge: CGFloat?
    @State private var windowWidth: CGFloat = 0
    /// Where the toolbar's items are (read from AppKit): the toolbar's own gaps, and the camera's island for DEBUG.
    @State private var places: ToolbarPlaces?
    /// Bumped when the panel's groups change: the probe reads the toolbar again.
    @State private var toolbarToken = 0
    /// How many of the panel's words are dropped (`PanelButtons.words`, in order) to fit over the panel.
    @State private var foldLevel = 0
    /// The session's capsule's toolbar item and the window's buttons beside it; the camera's island's left end and width.
    @State private var lights: WindowLights?
    @State private var islandMinX: CGFloat?
    @State private var islandWidth: CGFloat = 0
    /// The island's way to its new place when the panel folds away or comes back: the toolbar moves it at once, the
    /// island slides there with the panel's edge (`slideIsland`).
    @State private var islandSlide: CGFloat = 0

    /// Recording without a training, or «Только камера» before one: nothing to read or plan, the picture takes the
    /// whole window and a panel floats over it (the clock, or the way to record or back).
    private var clipMode: Bool { model.isRecordingClip || (ui.cameraOnly && model.session == nil) }

    var body: some View {
        @Bindable var ui = ui
        // The camera stays the first child in every layout, so the player is not recreated.
        let clipMode = clipMode
        let turning = model.panTilt.isActive && model.canPanTilt
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MacCameraArea(reloadToken: reloadToken)
                    .overlay { if turning { PanTiltFrame().transition(.opacity) } }
                    .overlay {
                        if clipMode {
                            ClipRecordingHUD()
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    // Away from the floating panel when it sits in the same corner.
                    .overlay(alignment: clipMode && hudPosition == .bottomTrailing ? .bottomLeading : .bottomTrailing) {
                        if turning {
                            PanTiltPad(diameter: 156)
                                .padding(24)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                if !clipMode {
                    // The camera just as wide as the picture by default; the edge drags wider for a timer read from
                    // across the room, or past the narrowest to «Только камера» (back with «Панели», Esc or ⇧⌘F).
                    let range = ConsolePanelLayout.widthRange(window: windowWidth)
                    let width = panelWidth(in: range)
                    HStack(spacing: 0) {
                        TrainingPanelEdge(width: Binding(get: { Double(width) }, set: { draggedPanelWidth = $0 }),
                                          range: range, canFold: model.session == nil && model.settings.isConfigured) {
                            withAnimation(ConsolePanelLayout.foldAnimation) { ui.cameraOnly = true }
                        }
                        rightPanel
                            .frame(width: width)
                    }
                    // Not while it slides away: the place it leaves for is off the window.
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { if !self.clipMode { panelEdge = $0 } }
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cameraHeight = $0 }
            // Before anything is pasted there is nothing to lay out in time: the camera takes the room, and the
            // timeline comes up with the plan.
            if !clipMode, model.session != nil || model.pendingPlan != nil {
                Divider()
                timeline
                    .frame(height: 232)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(ConsolePanelLayout.foldAnimation, value: clipMode)
        .animation(.smooth(duration: 0.35), value: model.session == nil && model.pendingPlan == nil)
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).width }) { windowWidth = $0 }
        .onChange(of: [panelEdge ?? -1, windowWidth, clipMode ? 1 : 0, places?.buttonsGaps ?? -1]) { updateToolbarFit() }
        .onChange(of: clipMode) { _, folded in slideIsland(folded: folded) }
        #if DEBUG
        .task(id: [panelEdge ?? -1, places?.groupMaxX ?? -1, clipMode ? 1 : 0, windowWidth]) { await checkCameraGroup() }
        .onChange(of: [panelEdge ?? -1, windowWidth, places?.buttonsWidth ?? -1, places?.groupMaxX ?? -1], initial: true) {
            ConsoleToolbarAudit.latest = .init(edge: panelEdge, windowWidth: windowWidth, buttonsWidth: places?.buttonsWidth,
                                               groupMaxX: places?.groupMaxX)
        }
        #endif
        .onChange(of: panelButtons) {
            // REC, a linked iPhone, the training came or went: the probe reads the toolbar again.
            toolbarToken += 1
            updateToolbarFit()
        }
        .background(Color.black)
        // For the Window menu, Mission Control and VoiceOver; on screen the session's capsule says it.
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .toolbar(removing: .title)
        // No bar of its own: the picture and the panel run up under the toolbar, and the camera's island stays on the
        // camera's side of the seam between them (see `ConsolePanelLayout`). Hidden, not automatic: automatic is a
        // solid bar (a hard scroll-edge pocket) until the player's web view is laid out again — folding the panel, or
        // the window back from the Dock.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard model.session != nil || model.pendingPlan != nil else { return .ignored }
            ui.primaryStep(model)
            return .handled
        }
        .onKeyPress(.delete) {
            guard ui.canFalseStart(model) else { return .ignored }
            ui.falseStart(model)
            return .handled
        }
        // Arrows turn the camera only while the turning mode is on (never by accident).
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .up]) { press in
            guard model.panTilt.isActive, let direction = PanTiltDirection(key: press.key) else { return .ignored }
            if press.phase == .up {
                model.panTilt.release(direction)
            } else {
                model.panTilt.press(direction, target: model.panTiltTarget)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if model.panTilt.isActive {
                withAnimation(.smooth(duration: 0.25)) { model.panTilt.stop() }
                return .handled
            }
            if ui.cameraOnly, model.session == nil, !model.isRecordingClip {
                ui.cameraOnly = false
                return .handled
            }
            return .ignored
        }
        .onChange(of: model.panTilt.isActive) { _, active in if active { focused = true } }
        .onChange(of: model.canPanTilt) { _, can in if !can { model.panTilt.stop() } }
        .onAppear {
            focused = true
            #if DEBUG
            // `--demo-edit-plan`: the running session's schedule open for edits (UI checks).
            if CommandLine.arguments.contains("--demo-edit-plan") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ui.editSessionPlan(model) }
            }
            // `--demo-camera-only`: «Только камера»; `--demo-pan-tilt` (with `--demo-camera-modes`): the turning mode on.
            if CommandLine.arguments.contains("--demo-camera-only") { ui.cameraOnly = true }
            if CommandLine.arguments.contains("--demo-pan-tilt") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.panTilt.start() }
            }
            if CommandLine.arguments.contains("--demo-panel-sweep") { Task { await sweepPanel() } }
            if CommandLine.arguments.contains("--demo-fold-cycle") { Task { await foldCycle() } }
            if CommandLine.arguments.contains("--demo-window-cycle") { ConsoleToolbarAudit.startOnce() }
            // `--demo-full-screen=<seconds>`: the window in full screen for that long (the header's checks there).
            if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-full-screen=") })?.dropFirst(19),
               let seconds = Double(raw) {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    let window = NSApp.windows.first { $0.isVisible && $0.toolbar != nil }
                    window?.toggleFullScreen(nil)
                    try? await Task.sleep(for: .seconds(seconds))
                    window?.toggleFullScreen(nil)
                }
            }
            // `--demo-window-size <width>x<height>`: the window at that size (the panel in a tall or short window).
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--demo-window-size"), i + 1 < args.count {
                let size = args[i + 1].split(separator: "x").compactMap { Double($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) else { return }
                    window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: size[0], height: size[1])), display: true)
                }
            }
            #endif
        }
        // A training started from a linked iPhone: the review of its schedule is over here too.
        .onChange(of: model.session != nil) { _, running in
            if running {
                ui.reviewingPlan = false
                // The training needs its readout and timeline.
                ui.cameraOnly = false
            } else {
                // Ended elsewhere (finished on the iPhone, the last break ran out): these would act on no training,
                // and «Отменить без сохранения» would delete a recording started after it.
                ui.confirmFinish = false
                ui.editingSessionPlan = nil
            }
        }
        // The menu's «Фальстарт» greys out when the trainer's window outside closes.
        .task(id: model.session?.phase) { await ui.watchFalseStartWindow(model) }
        .task(id: model.settings.streamName) { await model.refreshXiaomiQuality() }
        // The modes and turning of the camera on screen (the second one's too, after the switcher).
        .task(id: model.cameraModesKey) {
            model.panTilt.stop()
            await model.refreshCameraModes()
        }
        .task(id: model.settings.secondStreamName) { await model.refreshSecondCameraSource() }
        .sheet(isPresented: $ui.reviewingPlan, onDismiss: { focused = true }) {
            MacPlanReviewSheet(plan: pendingPlanBinding,
                               onStart: { ui.startPending(model) },
                               onDone: { ui.reviewingPlan = false })
                .environment(model)
        }
        .sheet(item: $ui.editingSessionPlan, onDismiss: { focused = true }) { _ in
            MacPlanReviewSheet(plan: Binding(get: { ui.editingSessionPlan ?? TrainingPlan() }, set: { ui.editingSessionPlan = $0 })
                                .keepingCommonEntriesScope,
                               fixedExits: model.session?.fixedExitCount ?? 0,
                               onStart: { ui.saveSessionPlan(model) },
                               onDone: { ui.editingSessionPlan = nil })
                .environment(model)
        }
        #if !WP_NO_XIAOMI
        .sheet(isPresented: $ui.showXiaomiSignIn, onDismiss: { focused = true }) {
            SetupXiaomiSignInSheet(onSignedIn: { _ in
                ui.showXiaomiSignIn = false
                // Straight to the account's cameras.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ui.showCameraPicker = true }
            })
            .environment(model)
            .environment(ui)
        }
        #endif
        .sheet(isPresented: $ui.showSecondCameraPicker, onDismiss: { focused = true }) {
            MacCameraPickerSheet(target: .second) { model.showCamera(second: true) }
        }
        .sheet(isPresented: $ui.showCameraPicker, onDismiss: { focused = true }) {
            MacCameraPickerSheet()
                .environment(model)
                .environment(ui)
        }
        .sheet(item: lastRecordBinding, onDismiss: { focused = true }) { record in
            MacSummarySheet(record: record, onClose: { model.lastRecord = nil })
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
        // Return keeps the recording going: a stop needs its own click.
        .alert("Остановить запись?", isPresented: $ui.confirmStopRecording) {
            Button("Продолжить запись", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Остановить запись", role: .destructive) { model.stopRecording(deleteFile: false) }
        } message: {
            Text(model.session != nil ? "Тренировка продолжится без видео. То, что уже записано, сохранится." : "Видео сохранится в истории.")
        }
        // Stopped elsewhere (from the iPhone, by «Завершить»): nothing left to stop.
        .onChange(of: model.isRecordingNow) { _, recording in if !recording { ui.confirmStopRecording = false } }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(MinimizedPanelHook(model: model, ui: ui))
    }

    // MARK: - Parts

    /// The dragged width, or the one that leaves the camera the picture's width; within what the window allows.
    private func panelWidth(in range: ClosedRange<CGFloat>) -> CGFloat {
        let width = draggedPanelWidth.map { CGFloat($0) }
            ?? ConsolePanelLayout.fittedWidth(window: windowWidth, cameraHeight: cameraHeight, video: model.videoSize)
        return min(max(width, range.lowerBound), range.upperBound)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let session = model.session {
            ConsoleReadout(session: session)
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
            MacPlanTimelineEditor(plan: pendingPlanBinding, original: model.pendingOriginal,
                                  pointer: Binding(get: { ui.planPointer }, set: { ui.planPointer = $0 }))
        }
    }

    private func live(_ session: TrainingSession, at now: Date) -> LiveSessionModel {
        LiveSessionModel(session: session, now: now,
                         recordingSince: model.isRecordingNow ? model.recordingStartedAt : nil)
    }

    /// The table, the inspector and the timeline write through it: an added exit or a new time keeps «к длинным».
    private var pendingPlanBinding: Binding<TrainingPlan> {
        Binding(get: { model.pendingPlan ?? TrainingPlan() }, set: { model.pendingPlan = $0 }).keepingCommonEntriesScope
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
            // The trainers alone: that it hasn't started, the panel's «Начать тренировку» says.
            return plan.trainers
        }
        if model.isRecordingClip { return String(localized: "запись без тренировки") }
        return ui.cameraOnly ? String(localized: "только камера") : String(localized: "новая тренировка")
    }

    // MARK: - Header

    /// Who the window is about, in the session's capsule.
    private var identity: SessionIdentity {
        if let session = model.session {
            var title = session.plan.title
            #if DEBUG
            // `--demo-title=<text>`: a training's long title (the capsule short of room).
            if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-title=") })?.dropFirst(13) { title = String(raw) }
            #endif
            return SessionIdentity(avatar: .training, title: title, subtitle: subtitle)
        }
        if let plan = model.pendingPlan {
            let notStarted = String(localized: "не начата")
            return SessionIdentity(avatar: .plan, title: plan.title,
                                   subtitle: plan.trainers.isEmpty ? notStarted : "\(plan.trainers) · \(notStarted)")
        }
        let camera = model.shownCameraShortName
        if model.isRecordingClip {
            return SessionIdentity(avatar: .recording, title: camera, subtitle: String(localized: "запись"),
                                   recordingSince: model.recordingStartedAt ?? .now)
        }
        let online = model.cameraOnScreenIsOnline
        var line = online ? String(localized: "на связи") : String(localized: "не на связи")
        if online, let quality = model.shownXiaomiQuality, quality != .auto { line += " · \(quality.title)" }
        return SessionIdentity(avatar: .camera(online: online), title: camera, subtitle: line)
    }

    /// What the panel's groups hold.
    private var panelButtons: PanelButtons {
        let devices = model.syncHost.connectedDevices
        return PanelButtons(recording: model.isRecordingNow, session: model.session != nil,
                            devices: devices.isEmpty ? nil : devices.map(\.name).joined(separator: ", "))
    }

    private var groupCount: Int { panelButtons.devices == nil ? 2 : 3 }

    /// How much of the toolbar the panel's groups take from the window's edge at `level`.
    private func buttonsWidth(level: Int) -> CGFloat {
        panelButtons.width(level: level)
            + (places?.buttonsGaps ?? ConsolePanelLayout.defaultButtonsGaps(groups: groupCount))
    }

    /// The panel's groups keep their words while they fit over the panel (see `ConsolePanelLayout`); without the panel
    /// all of them.
    private func updateToolbarFit() {
        guard !clipMode, let edge = panelEdge, windowWidth > 0 else {
            foldLevel = 0
            return
        }
        let level = ConsolePanelLayout.foldLevel(
            current: min(foldLevel, panelButtons.words.count), buttons: panelButtons,
            gaps: places?.buttonsGaps ?? ConsolePanelLayout.defaultButtonsGaps(groups: groupCount),
            edge: edge, window: windowWidth)
        if level != foldLevel { foldLevel = level }
    }

    /// How wide the session's capsule may get: up to the camera's island, the toolbar's own gap (8 pt) and a little
    /// more between them. Until the toolbar is read, where its item usually is: a capsule laid out too wide at first
    /// crowds the toolbar, and AppKit pushes the island over the panel's edge.
    private var capsuleRoom: CGFloat {
        let itemMinX = lights?.itemMinX ?? 96
        let island: CGFloat = if !clipMode, let edge = panelEdge {
            edge - ConsolePanelLayout.edgeInset - islandWidth
        } else {
            islandMinX ?? windowWidth - buttonsWidth(level: 0) - ConsolePanelLayout.defaultItemGap
                - ConsolePanelLayout.clipModePad - islandWidth
        }
        return island - 18 - itemMinX
    }

    /// The panel folded away or came back: the toolbar has moved the camera's island at once (next to the panel's
    /// groups, or back before the panel's edge); it slides from its old place to the new one along the panel's own
    /// curve, staying just before the edge sweeping by, over the picture all the way.
    private func slideIsland(folded: Bool) {
        guard windowWidth > 0 else { return }
        // Where the panel's edge is or will be (coming back, the panel isn't laid out yet).
        let edge = windowWidth - ConsolePanelLayout.edgeWidth - panelWidth(in: ConsolePanelLayout.widthRange(window: windowWidth))
        let atEdge = edge - ConsolePanelLayout.edgeInset
        let byGroups = windowWidth - buttonsWidth(level: 0) - (places?.itemGap ?? ConsolePanelLayout.defaultItemGap)
            - ConsolePanelLayout.clipModePad
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { islandSlide = folded ? atEdge - byGroups : byGroups - atEdge }
        DispatchQueue.main.async {
            withAnimation(ConsolePanelLayout.foldAnimation) { islandSlide = 0 }
        }
    }

    /// The panel's group number `index` floats over the camera without the panel; its shadow comes and goes as the
    /// panel's edge passes under it.
    private func sweep(_ index: Int) -> Animation {
        let groups = places?.groups ?? []
        guard let edge = panelEdge, groups.indices.contains(index) else { return .easeInOut(duration: 0.2) }
        let group = groups[index]
        return HeaderShadowSweep.animation(groupMidX: (group.lowerBound + group.upperBound) / 2, edge: edge,
                                           window: windowWidth, floating: clipMode)
    }

    #if DEBUG
    /// Logs the camera's island running over the panel's edge once the toolbar has settled (a layout pass or two
    /// may still show the old places), and after `--demo-panel-sweep` steps where it ended up.
    private func checkCameraGroup() async {
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, !clipMode, let edge = panelEdge, let groupMaxX = places?.groupMaxX, groupMaxX > 0
        else { return }
        let gap = edge - groupMaxX
        let sweep = CommandLine.arguments.contains("--demo-panel-sweep")
        if gap < 1 || sweep || CommandLine.arguments.contains("--demo-toolbar-log") {
            let modelWidth = panelButtons.width(level: foldLevel)
            print("[toolbar] camera group ends \(Int(gap)) pt before the panel's edge (panel \(Int(windowWidth - edge)) pt, "
                  + "\(foldLevel) words dropped; groups \(Int(modelWidth)) pt + gaps \(places.map { String(format: "%.1f", $0.buttonsGaps) } ?? "?"), "
                  + "item gap \(places?.itemGap.map { String(format: "%.1f", $0) } ?? "?"))\(gap < 1 ? " — RUNS OVER THE EDGE" : "")")
        }
    }

    /// `--demo-fold-cycle`: the panel folded away and back, twice (the header's shadows on video, with `--demo-slow`).
    private func foldCycle() async {
        let fold = Int(900 * ConsolePanelLayout.slowMotion) + 600
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<2 {
            ui.cameraOnly = true
            try? await Task.sleep(for: .milliseconds(fold))
            ui.cameraOnly = false
            try? await Task.sleep(for: .milliseconds(fold))
        }
    }

    /// `--demo-panel-sweep`: the panel's width through its range and back, folded away and opened again.
    private func sweepPanel() async {
        try? await Task.sleep(for: .seconds(2))
        for width in [340, 420, 520, 640, 720, 600, 464, 380] as [Double] {
            draggedPanelWidth = width
            try? await Task.sleep(for: .milliseconds(900))
        }
        let fold = Int(900 * ConsolePanelLayout.slowMotion) + 400
        ui.cameraOnly = true
        try? await Task.sleep(for: .milliseconds(fold))
        ui.cameraOnly = false
        try? await Task.sleep(for: .milliseconds(fold))
        print("[toolbar] sweep done")
    }
    #endif

    /// The session's capsule at the window's buttons; the camera's island right before the panel's edge; the panel's
    /// groups over the panel at the window's edge: recording and sound · the linked iPhone · history and finishing.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SessionCapsule(identity: identity, lights: lights, room: capsuleRoom) { read in
                if read != lights { lights = read }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem {
            // The island, then a clear room as wide as the panel's groups leave over the panel: the island lands right
            // before the panel's edge and follows it when the panel is resized. Without the panel, the usual gap.
            HStack(spacing: 0) {
                CameraIsland(onReconnect: { model.videoSize = nil; model.secondVideoSize = nil; reloadToken += 1 })
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { islandWidth = $0 }
                    .offset(x: islandSlide)
                    .background {
                        ToolbarNeighboursProbe(token: toolbarToken) { read in
                            var read = read
                            // Without the panel the room after the island is fixed: the gap read is the toolbar's alone.
                            if clipMode, let gap = places?.itemGap { read.itemGap = gap }
                            // Only real moves: an update with the same places must not start another round.
                            if read != places { places = read }
                        }
                    }
                    .background(WindowLightsProbe { read in
                        if abs((islandMinX ?? -100) - read.itemMinX) > 0.5 { islandMinX = read.itemMinX }
                    })
                Color.clear
                    .frame(width: clipMode ? ConsolePanelLayout.clipModePad : ConsolePanelLayout.islandPad(
                        buttonsWidth: buttonsWidth(level: foldLevel),
                        itemGap: places?.itemGap ?? ConsolePanelLayout.defaultItemGap,
                        edge: panelEdge, window: windowWidth), height: 1)
                    .accessibilityHidden(true)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        let folded = clipMode ? [] : panelButtons.folded(foldLevel)
        let floating: Double = clipMode ? 1 : 0
        ToolbarItem {
            RecordSoundGroup(folded: folded, floating: floating, sweep: sweep(0))
        }
        .sharedBackgroundVisibility(.hidden)
        if panelButtons.devices != nil {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                LinkedDeviceGroup(folded: folded, floating: floating, sweep: sweep(1))
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            HistoryFinishGroup(folded: folded, floating: floating, sweep: sweep(groupCount - 1))
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension PanTiltDirection {
    init?(key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        default: return nil
        }
    }
}

#if DEBUG
/// `--demo-window-cycle [dock,zoom,dockzoom,full,close]`: the window to the Dock and back, zoomed and back, in full
/// screen and back, closed and opened again from the Dock (the log asks for the reopen: `open` the running app). After
/// each step the toolbar is read from AppKit here, not through the probe, against the panel's edge.
@MainActor
enum ConsoleToolbarAudit {
    struct Values {
        var edge: CGFloat?
        var windowWidth: CGFloat
        var buttonsWidth: CGFloat?
        var groupMaxX: CGFloat?
    }

    /// What the console window shows now (reported by `MacConsoleView`).
    static var latest = Values(edge: nil, windowWidth: 0, buttonsWidth: nil, groupMaxX: nil)
    private static var started = false

    static func startOnce() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(4))
        let arguments = CommandLine.arguments
        let chosen = arguments.firstIndex(of: "--demo-window-cycle").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .map { Set($0.split(separator: ",").map(String.init)) } ?? ["dock", "zoom", "dockzoom", "full", "close"]
        audit(after: "launch")
        let dock: [(String, Double, (NSWindow) -> Void)] = [("miniaturize", 1.5, { $0.miniaturize(nil) }),
                                                            ("deminiaturize", 2.5, { $0.deminiaturize(nil) })]
        var steps: [(String, Double, (NSWindow) -> Void)] = []
        if chosen.contains("dock") { steps += dock }
        if chosen.contains("zoom") { steps += [("zoom", 2.5, { $0.zoom(nil) }), ("unzoom", 2.5, { $0.zoom(nil) })] }
        if chosen.contains("dockzoom") { steps += [("zoom", 2.5, { $0.zoom(nil) })] + dock + [("unzoom", 2.5, { $0.zoom(nil) })] }
        if chosen.contains("full") {
            steps += [("fullscreen", 3.5, { $0.toggleFullScreen(nil) }), ("windowed", 3.5, { $0.toggleFullScreen(nil) })]
        }
        for (name, wait, step) in steps {
            guard let window = consoleWindow() else { break }
            step(window)
            try? await Task.sleep(for: .seconds(wait))
            audit(after: name)
        }
        if chosen.contains("close"), let window = consoleWindow() {
            window.performClose(nil)
            try? await Task.sleep(for: .seconds(1.5))
            print("[cycle] closed: reopen the app now")
            for _ in 0..<80 where consoleWindow() == nil { try? await Task.sleep(for: .milliseconds(250)) }
            for wait in [0.5, 1.0, 2.0, 4.0] {
                try? await Task.sleep(for: .seconds(wait))
                audit(after: "reopen +\(wait)s")
            }
        }
        print("[cycle] done")
    }

    private static func consoleWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && probeIndex(in: $0) != nil }
            ?? NSApp.windows.first { probeIndex(in: $0) != nil }
    }

    private static func audit(after step: String) {
        guard let window = consoleWindow(), let items = window.toolbar?.items, let index = probeIndex(in: window) else {
            print("[cycle] after \(step): no console window")
            return
        }
        // Screen coordinates back to the window's: in full screen the toolbar lives in a window of its own.
        func frame(_ item: NSToolbarItem) -> CGRect? {
            guard let view = item.view, let host = view.window else { return nil }
            return host.convertToScreen(view.convert(view.bounds, to: nil)).offsetBy(dx: -window.frame.minX, dy: 0)
        }
        let groupMaxX = probeView(in: window).flatMap { view in
            view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)).maxX - window.frame.minX }
        }
        let buttonsMinX = items[(index + 1)...].compactMap(frame).map(\.minX).min()
        let hosts = Set(items.compactMap { $0.view?.window.map { "\(type(of: $0))" } }).sorted()
        func number(_ value: CGFloat?) -> String { value.map { String(Int($0.rounded())) } ?? "nil" }
        let state = latest
        let gap = (state.edge ?? 0) - (groupMaxX ?? 0)
        print("[cycle] after \(step): window \(number(window.frame.width)) (view \(number(state.windowWidth))), "
              + "edge \(number(state.edge)), AppKit: buttons take \(number(buttonsMinX.map { window.frame.width - $0 })), "
              + "camera group to \(number(groupMaxX)); probe: buttons take \(number(state.buttonsWidth)), "
              + "camera group to \(number(state.groupMaxX)); toolbar in \(hosts.joined(separator: ", "))"
              + (gap < 1 ? " — RUNS OVER THE EDGE" : ""))
    }

    private static func probeIndex(in window: NSWindow) -> Int? {
        window.toolbar?.items.firstIndex { item in item.view.flatMap(findProbe) != nil }
    }

    private static func probeView(in window: NSWindow) -> NSView? {
        window.toolbar?.items.lazy.compactMap { $0.view.flatMap(findProbe) }.first
    }

    private static func findProbe(_ view: NSView) -> NSView? {
        view is ToolbarNeighboursProbe.ProbeView ? view : view.subviews.lazy.compactMap(findProbe).first
    }
}
#endif
#endif
