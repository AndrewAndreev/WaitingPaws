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
    /// The panel's left edge in the window, the window's width and how much of the toolbar the panel's buttons take
    /// from the window's edge: the camera's group in the toolbar stays on the camera's side of the panel's edge.
    /// The edge is kept while the panel is folded away (whatever reads it checks `clipMode`): the window closed and
    /// opened again from the Dock keeps this state, and the panel, back at the same place, reports no edge again.
    @State private var panelEdge: CGFloat?
    @State private var windowWidth: CGFloat = 0
    @State private var buttonsWidth: CGFloat?
    /// Where the camera's group ends in the toolbar (DEBUG checks it against the panel's edge).
    @State private var cameraGroupMaxX: CGFloat?
    /// Bumped when the first of the panel's buttons changes its size: the probe reads the toolbar again.
    @State private var toolbarToken = 0
    /// The panel's buttons in the toolbar show icons only (with titles they didn't fit over the panel); their width with
    /// titles is kept for each set of buttons, to know when they fit again.
    @State private var compactToolbar = false
    @State private var titledWidths: [String: CGFloat] = [:]

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
                            withAnimation(.smooth(duration: 0.35)) { ui.cameraOnly = true }
                        }
                        rightPanel
                            .frame(width: width)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { panelEdge = $0 }
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cameraHeight = $0 }
            if !clipMode {
                Divider()
                timeline
                    .frame(height: 232)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.35), value: clipMode)
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).width }) { windowWidth = $0 }
        .onChange(of: [panelEdge ?? -1, buttonsWidth ?? -1, windowWidth, clipMode ? 1 : 0]) { updateToolbarFit() }
        #if DEBUG
        .task(id: [panelEdge ?? -1, cameraGroupMaxX ?? -1, clipMode ? 1 : 0]) { await checkCameraGroup() }
        .onChange(of: [panelEdge ?? -1, windowWidth, buttonsWidth ?? -1, cameraGroupMaxX ?? -1], initial: true) {
            ConsoleToolbarAudit.latest = .init(edge: panelEdge, windowWidth: windowWidth, buttonsWidth: buttonsWidth,
                                               groupMaxX: cameraGroupMaxX)
        }
        #endif
        .onChange(of: toolbarSignature) { updateToolbarFit() }
        .background(Color.black)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        // No bar of its own: the picture and the panel run up under the toolbar, and the camera's group stays on the
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
            guard model.session?.phase.canFalseStart == true else { return .ignored }
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
            if CommandLine.arguments.contains("--demo-window-cycle") { ConsoleToolbarAudit.startOnce() }
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
            }
        }
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
        .sheet(item: $ui.editingSessionPlan, onDismiss: { focused = true }) { _ in
            MacPlanReviewSheet(plan: Binding(get: { ui.editingSessionPlan ?? TrainingPlan() }, set: { ui.editingSessionPlan = $0 }),
                               fixedExits: model.session?.fixedExitCount ?? 0,
                               onStart: { ui.saveSessionPlan(model) },
                               onDone: { ui.editingSessionPlan = nil })
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
        .sheet(isPresented: $ui.showSecondCameraPicker, onDismiss: { focused = true }) {
            MacCameraPickerSheet(target: .second) { model.showCamera(second: true) }
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
        if model.isRecordingClip { return String(localized: "запись без тренировки") }
        return ui.cameraOnly ? String(localized: "только камера") : String(localized: "новая тренировка")
    }

    // MARK: - Toolbar

    /// The panel's buttons keep their titles while they fit over the panel (see `ConsolePanelLayout`).
    private func updateToolbarFit() {
        guard !clipMode, let edge = panelEdge, let width = ConsolePanelLayout.plausible(buttonsWidth, window: windowWidth) else {
            // No panel: the whole toolbar is theirs.
            compactToolbar = false
            return
        }
        let key = toolbarSignature
        if !compactToolbar {
            titledWidths[key] = width
            if !ConsolePanelLayout.fits(buttonsWidth: width, edge: edge, window: windowWidth) { compactToolbar = true }
        } else if let titled = titledWidths[key] {
            // A couple of points to spare, so a width right at the limit doesn't flip back and forth.
            if ConsolePanelLayout.fits(buttonsWidth: titled + 2, edge: edge, window: windowWidth) { compactToolbar = false }
        } else {
            // Buttons not seen with titles yet: show them, and they are measured.
            compactToolbar = false
        }
    }

    #if DEBUG
    /// Logs the camera's group running over the panel's edge once the toolbar has settled (a layout pass or two
    /// may still show the old places), and after `--demo-panel-sweep` steps where it ended up.
    private func checkCameraGroup() async {
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, !clipMode, let edge = panelEdge, let groupMaxX = cameraGroupMaxX, groupMaxX > 0
        else { return }
        let gap = edge - groupMaxX
        let sweep = CommandLine.arguments.contains("--demo-panel-sweep")
        if gap < 1 || sweep {
            print("[toolbar] camera group ends \(Int(gap)) pt before the panel's edge (panel \(Int(windowWidth - edge)) pt"
                  + "\(compactToolbar ? ", icons only" : ""))\(gap < 1 ? " — RUNS OVER THE EDGE" : "")")
        }
    }

    /// `--demo-panel-sweep`: the panel's width through its range and back, folded away and opened again.
    private func sweepPanel() async {
        try? await Task.sleep(for: .seconds(2))
        for width in [340, 420, 520, 640, 720, 600, 464, 380] as [Double] {
            draggedPanelWidth = width
            try? await Task.sleep(for: .milliseconds(900))
        }
        ui.cameraOnly = true
        try? await Task.sleep(for: .milliseconds(900))
        ui.cameraOnly = false
        try? await Task.sleep(for: .milliseconds(900))
        print("[toolbar] sweep done")
    }
    #endif

    /// What changes the width of the panel's buttons.
    private var toolbarSignature: String {
        [model.isRecordingNow ? "rec" : "", model.session != nil ? "session" : "",
         model.syncHost.connectedDevices.map(\.name).joined(separator: ",")].joined(separator: "|")
    }

    /// Icon and title on every item while they fit (a bare icon in a row of similar capsules says too little), groups
    /// apart: camera · recording and sound · the linked iPhone · history and finishing.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.hasSecondCamera { CameraToolbarSwitcher() }
            CameraToolbarMenu(onReconnect: { model.videoSize = nil; reloadToken += 1 })
            if model.canPanTilt { PanTiltToolbarToggle() }
        }
        // As wide as the room the panel's buttons leave over the panel: the camera's group lands right before the
        // panel's edge, and follows it when the panel is resized. Without the panel, the usual gap.
        if clipMode {
            ToolbarSpacer(.fixed)
        } else {
            ToolbarItem {
                ToolbarNeighboursProbe(token: toolbarToken) { width, groupMaxX in
                    // Only real moves: an update with the same places must not start another round.
                    if abs((buttonsWidth ?? -100) - width) > 0.5 { buttonsWidth = width }
                    if let groupMaxX, abs((cameraGroupMaxX ?? -100) - groupMaxX) > 0.5 { cameraGroupMaxX = groupMaxX }
                }
                .frame(width: ConsolePanelLayout.spacerWidth(buttonsWidth: buttonsWidth, edge: panelEdge,
                                                              window: windowWidth), height: 1)
                .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup {
            // The first of the panel's buttons: «REC 9:59» → «REC 10:00» moves where they begin.
            RecordingToolbarButton(compact: compactToolbar)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in toolbarToken += 1 }
            Toggle(isOn: Binding(get: { model.settings.audioEnabled }, set: { model.settings.audioEnabled = $0 })) {
                Label("Звук", systemImage: model.settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .padding(.horizontal, ToolbarLook.padding)
                    .labelStyle(ToolbarFitLabelStyle(compact: compactToolbar))
            }
            .help(model.settings.audioEnabled ? "Выключить звук камеры в приложении (запись всегда со звуком)"
                                              : "Включить звук камеры в приложении (запись всегда со звуком)")
        }
        if let first = model.syncHost.connectedDevices.first {
            let devices = model.syncHost.connectedDevices
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Label(devices.map(\.name).joined(separator: ", "), systemImage: first.symbolName)
                    .foregroundStyle(MacPalette.blue)
                    .padding(.horizontal, ToolbarLook.padding + 6)
                    .labelStyle(ToolbarFitLabelStyle(compact: compactToolbar))
                    .help(devices.count == 1
                          ? String(localized: "\(first.modelTitle) «\(first.name)» видит камеру и ведёт эту тренировку")
                          : String(localized: "Камеру видят и ведут тренировку: \(devices.map(\.name).joined(separator: ", "))"))
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { openWindow(id: "history") } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
                    .labelStyle(ToolbarFitLabelStyle(compact: compactToolbar))
                    .padding(.horizontal, ToolbarLook.padding)
            }
            .help("История тренировок · ⌘Y")
            if model.session != nil {
                Button { ui.confirmFinish = true } label: {
                    // While recording, finishing stops the recording too: the button says so.
                    Label(model.isRecordingNow ? String(localized: "Завершить тренировку и запись") : String(localized: "Завершить"),
                          systemImage: "flag.checkered")
                        .labelStyle(ToolbarFitLabelStyle(compact: compactToolbar))
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
            Button(model.hasSecondCamera ? "Другая вторая камера…" : "Вторая камера…", systemImage: "rectangle.on.rectangle") {
                ui.showSecondCameraPicker = true
            }
            if model.hasSecondCamera {
                Button("Убрать вторую камеру", systemImage: "rectangle.badge.minus") { model.removeSecondCamera() }
            }
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

    /// «Прихожая · HD»; a long Mi Home name is cut in the middle by the toolbar. With a second camera the switcher
    /// names them, and the menu is the first camera's quality.
    private var title: String {
        if model.hasSecondCamera { return model.xiaomiQuality?.title ?? String(localized: "Камера") }
        let name = model.settings.cameraDisplayName.isEmpty ? String(localized: "Камера") : model.settings.cameraDisplayName
        guard let quality = model.xiaomiQuality else { return name }
        return "\(name) · \(quality.title)"
    }

    private var cameraOnline: Bool {
        model.settings.connectionMode == .external || model.embedded.status.isRunning
    }
}

/// «Прихожая · Комната» (⌘1 / ⌘2): which camera is on screen. Both keep playing; the recording is the first one's.
private struct CameraToolbarSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Камера", selection: Binding(get: { model.isShowingSecondCamera },
                                            set: { model.showCamera(second: $0) })) {
            Text(model.settings.cameraDisplayName.isEmpty ? String(localized: "Камера 1") : model.settings.cameraDisplayName)
                .tag(false)
            Text(model.activeSecondCameraName).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Какую камеру показывать · ⌘1 / ⌘2. Записывается первая")
    }
}

/// «Повернуть»: the turning mode — the pad over the picture and the arrow keys (Esc or «Готово» to end it).
private struct PanTiltToolbarToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(get: { model.panTilt.isActive },
                             set: { on in withAnimation(.smooth(duration: 0.25)) { on ? model.panTilt.start() : model.panTilt.stop() } })) {
            Label("Повернуть", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .padding(.horizontal, ToolbarLook.padding)
                .labelStyle(.titleAndIcon)
        }
        .help(model.panTilt.isActive ? "Закончить поворот камеры · Esc"
                                     : "Повернуть камеру: стрелки на картинке или на клавиатуре")
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

/// REC with the running time, or «Запись» to start one (⌘R).
private struct RecordingToolbarButton: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button { model.toggleRecording() } label: {
                if model.isRecordingNow {
                    RecBadge(text: DurationText.clock(model.recordingDuration(at: context.date)))
                        .padding(.horizontal, ToolbarLook.padding + 4)
                } else {
                    Label("Запись", systemImage: "record.circle")
                        .padding(.horizontal, ToolbarLook.padding)
                        .labelStyle(ToolbarFitLabelStyle(compact: compact))
                }
            }
            .help(model.isRecordingNow ? "Остановить запись · ⌘R" : "Записать видео · ⌘R")
            .disabled(!model.isRecordingNow && !model.settings.isConfigured)
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
        let groupMaxX = items[..<index].compactMap(frame).map(\.maxX).max()
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
        func hasProbe(_ view: NSView) -> Bool {
            view is ToolbarNeighboursProbe.ProbeView || view.subviews.contains(where: hasProbe)
        }
        return window.toolbar?.items.firstIndex { item in item.view.map(hasProbe) ?? false }
    }
}
#endif
#endif
