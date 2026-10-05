import SwiftUI
import WaitingPawsCore

/// The main screen: camera in the background, training HUD on top.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model

    @State private var showPlanInput = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showCameraPicker = false
    /// «Подключить камеру…» after starting without one: the first-launch setup as a sheet.
    @State private var showCameraSetup = false
    @State private var confirmFinish = false
    @State private var confirmAbandon = false
    @State private var reloadToken = 0
    /// The schedule waiting on the linked Mac, opened for edits.
    @State private var editingPending: TrainingPlan?

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let compact = !wide && geometry.size.height < 900
            // Recording without a training (here or on the linked Mac): the picture takes the screen, the clock
            // floats over it. The camera keeps its place in each layout, so the player is not recreated.
            let clipMode = model.isRecordingClip
            Group {
                if wide {
                    HStack(spacing: 12) {
                        cameraArea
                            .overlay(alignment: .top) {
                                if clipMode { topBar.padding(12).transition(.opacity) }
                            }
                            .overlay(alignment: .bottom) { clipOverlay(clipMode) }
                        if !clipMode {
                            VStack(spacing: 12) {
                                topBar
                                if model.performance.isRunning { performanceBar }
                                Spacer(minLength: 0)
                                bottomContent(compact: false)
                            }
                            .frame(width: min(420, geometry.size.width * 0.45))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(clipMode ? 0 : 12)
                } else {
                    VStack(spacing: 10) {
                        topBar
                            .padding(.horizontal, 12)
                        if model.performance.isRunning { performanceBar.padding(.horizontal, 12) }
                        cameraArea
                            .overlay(alignment: .bottom) { clipOverlay(clipMode) }
                            .padding(.horizontal, clipMode ? 0 : 12)
                        if !clipMode {
                            bottomContent(compact: compact)
                                .padding(.horizontal, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: clipMode)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .modifier(LinkNoticeOverlay())
        #endif
        .task(id: model.settings.streamName) { await model.refreshXiaomiQuality() }
        // Camera modes also through a linked Mac: they live in the camera.
        .task(id: model.cameraModesKey) { await model.refreshCameraModes() }
        .onChange(of: model.settings.isConfigured) { _, configured in
            if configured { showCameraSetup = false }
        }
        .onAppear {
            #if DEBUG
            // `--demo-screen plan|camera|settings|history` opens a sheet right away (UI checks without tapping).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-screen"), index + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[index + 1] {
                case "plan": showPlanInput = true
                case "plan-twice":
                    showPlanInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showPlanInput = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showPlanInput = true }
                case "camera": showCameraPicker = true
                case "settings": showSettings = true
                case "history", "history-last": showHistory = true
                default: break
                }
            }
            #endif
        }
        .sheet(isPresented: $showPlanInput) {
            PlanInputView(initialText: model.settings.lastPlanText) { plan in
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
                CameraPickerView(accountID: model.settings.xiaomiAccountID.isEmpty ? nil : model.settings.xiaomiAccountID,
                                 region: model.settings.xiaomiRegion) { _ in
                    showCameraPicker = false
                }
            }
            .environment(model)
            .sheetFrame(width: 520, height: 560)
        }
        #if os(macOS)
        .alert(model.syncHost.pairingRequest.map { String(localized: "Подключить «\($0.deviceName)»?") } ?? "",
               isPresented: Binding(get: { model.syncHost.pairingRequest != nil },
                                    set: { if !$0 { model.syncHost.answerPairing(allow: false) } })) {
            Button("Разрешить") { model.syncHost.answerPairing(allow: true) }
            Button("Отклонить", role: .cancel) { model.syncHost.answerPairing(allow: false) }
        } message: {
            Text("iPhone увидит камеру этого Mac и сможет вести тренировку: кнопки, запись, лог. Запись и лог сохраняются на Mac. Разрешение запоминается, его можно отозвать в настройках.")
        }
        #endif
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
    }

    // MARK: - Camera

    private var cameraArea: some View {
        ZoomableView { camera }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }

    @ViewBuilder
    private func clipOverlay(_ clipMode: Bool) -> some View {
        if clipMode {
            ClipRecordingOverlay()
                .frame(maxWidth: 520)
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var camera: some View {
        #if DEBUG && os(iOS)
        // `--demo-camera=<path>`: a still picture instead of the stream (UI checks in the simulator).
        if let image = DemoData.cameraImage {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
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
        if hasNoCamera {
            NoCameraView(onConnect: { showCameraSetup = true })
        } else if !model.isLinkedToMac, model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.activeServer, !model.activeStreamName.isEmpty {
            CameraStreamView(server: server,
                             stream: model.activeStreamName,
                             mode: model.activePlayerMode,
                             audioEnabled: model.settings.audioEnabled,
                             reloadToken: reloadToken + model.activePlayerGeneration,
                             onVideoSize: { size in model.videoSize = size },
                             onDelay: { model.performance.notePlayerDelay(buffer: $0, network: $1) })
        } else {
            CameraPlaceholder(text: model.isLinkedToMac ? String(localized: "На Mac не выбрана камера") : String(localized: "Камера не выбрана"))
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if hasNoCamera {
                Button { showCameraSetup = true } label: {
                    Pill(text: String(localized: "Без камеры"), systemImage: "video.slash", tint: .white.opacity(0.85))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                CameraMenu(onReconnect: { model.videoSize = nil; reloadToken += 1 }, onPickCamera: { showCameraPicker = true })
                RecordingPill()
            }
            Spacer()
            LinkPill()
            if model.session != nil {
                Menu {
                    Button("Завершить тренировку", systemImage: "flag.checkered") { confirmFinish = true }
                    Button("Отменить без сохранения", systemImage: "xmark.circle", role: .destructive) { confirmAbandon = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.control, in: Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            } else {
                IconButton(systemImage: "clock.arrow.circlepath") { showHistory = true }
                IconButton(systemImage: "gearshape") { showSettings = true }
            }
        }
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
                    hasLastPlan: model.lastPlan != nil,
                    canRecord: !hasNoCamera,
                    onPaste: { showPlanInput = true },
                    onRepeat: {
                        if let plan = model.lastPlan { model.startSession(with: plan) } else { showPlanInput = true }
                    },
                    onRecordOnly: { model.startRecording() })
                .frame(maxWidth: 560)
            }
        }
    }
}

/// Card shown before a session: paste the schedule or repeat the previous one.
struct PlanEntryCard: View {
    @Environment(AppModel.self) private var model
    var hasLastPlan: Bool
    /// A camera is there (own or the linked Mac's): video can be recorded.
    var canRecord = true
    var onPaste: () -> Void
    var onRepeat: () -> Void
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
                if hasLastPlan || canRecord {
                    HStack(spacing: 8) {
                        if hasLastPlan {
                            BigButton(title: String(localized: "Повторить прошлое"), systemImage: "arrow.counterclockwise",
                                      style: .secondary, height: 44, action: onRepeat)
                        }
                        if canRecord {
                            BigButton(title: String(localized: "Только запись"), systemImage: "record.circle",
                                      style: .secondary, height: 44, action: onRecordOnly)
                        }
                    }
                }
            }
        }
    }
}


/// Camera name pill with its menu. Separate view so per-second updates elsewhere do not rebuild an open menu.
private struct CameraMenu: View {
    @Environment(AppModel.self) private var model
    var onReconnect: () -> Void
    var onPickCamera: () -> Void

    var body: some View {
        Menu {
            if model.isLinkedToMac {
                Text("Камеру и качество выбирают на Mac")
            } else {
                Button("Выбрать камеру…", systemImage: "video.badge.plus", action: onPickCamera)
                #if os(iOS)
                // Always here, unlike the «Рядом Mac» card (closed, or pushed out by a summary).
                if model.session == nil, let mac = model.syncClient.bestMac {
                    Button("Синхронизировать с «\(mac.info.name)»", systemImage: "laptopcomputer") {
                        model.syncClient.connect(to: mac)
                    }
                }
                #endif
            }
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            if !model.isLinkedToMac, let quality = model.xiaomiQuality {
                Menu {
                    Picker("Качество", selection: Binding(
                        get: { quality },
                        set: { newValue in
                            Task { await model.setXiaomiQuality(newValue) }
                        })) {
                        ForEach(AppModel.XiaomiQuality.allCases) { q in Text(model.qualityTitle(q)).tag(q) }
                    }
                    Text("Записи — в этом же качестве")
                    if let size = model.videoSize {
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        .layoutPriority(-1)
    }
}

/// REC indicator / toggle; the one-second clock lives inside this view only.
private struct RecordingPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button {
                model.toggleRecording()
            } label: {
                if model.isRecordingNow {
                    Pill(text: "REC " + DurationText.clock(model.recordingDuration(at: context.date)),
                         systemImage: "record.circle.fill", tint: Theme.danger)
                } else if !model.isLinkedToMac, model.recorder.lastError != nil {
                    Pill(text: String(localized: "Запись не идёт"), systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                } else {
                    Pill(text: String(localized: "Запись"), systemImage: "record.circle", tint: .white.opacity(0.85))
                }
            }
            .buttonStyle(PressableButtonStyle())
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
