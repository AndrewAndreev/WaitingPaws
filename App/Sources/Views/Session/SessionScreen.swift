import SwiftUI
import WaitingPawsCore

/// The main screen: camera in the background, training HUD on top.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model

    @State private var showPlanInput = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showCameraPicker = false
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
        .task(id: "\(model.activeStreamName)|\(model.isLinkedToMac)") { await model.refreshCameraModes() }
        .onAppear {
            #if DEBUG
            // `--demo-screen plan|camera` opens a sheet right away (UI checks without tapping).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-screen"), index + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[index + 1] {
                case "plan": showPlanInput = true
                case "plan-twice":
                    showPlanInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showPlanInput = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showPlanInput = true }
                case "camera": showCameraPicker = true
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
        .alert(model.syncHost.pairingRequest.map { "Подключить «\($0.deviceName)»?" } ?? "",
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

    @ViewBuilder
    private var liveCamera: some View {
        if !model.isLinkedToMac, model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.activeServer, !model.activeStreamName.isEmpty {
            CameraStreamView(server: server,
                             stream: model.activeStreamName,
                             mode: model.activePlayerMode,
                             audioEnabled: model.settings.audioEnabled,
                             reloadToken: reloadToken,
                             onVideoSize: { size in model.videoSize = size })
        } else {
            CameraPlaceholder(text: model.isLinkedToMac ? "На Mac не выбрана камера" : "Камера не выбрана")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            CameraMenu(onReconnect: { model.videoSize = nil; reloadToken += 1 }, onPickCamera: { showCameraPicker = true })
            RecordingPill()
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
        case .idle, .starting: return "Запускаем go2rtc…"
        case .failed(let message): return message
        case .unavailable: return "Встроенный go2rtc не собран"
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
                Toggle(isOn: $settings.autoRecord) {
                    Label("Записывать видео", systemImage: "record.circle")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .tint(Theme.accent)
                BigButton(title: "Вставить расписание", systemImage: "doc.on.clipboard", action: onPaste)
                HStack(spacing: 8) {
                    if hasLastPlan {
                        BigButton(title: "Повторить прошлое", systemImage: "arrow.counterclockwise",
                                  style: .secondary, height: 44, action: onRepeat)
                    }
                    BigButton(title: "Только запись", systemImage: "record.circle",
                              style: .secondary, height: 44, action: onRecordOnly)
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
            }
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            if !model.isLinkedToMac, let quality = model.xiaomiQuality {
                Menu {
                    Picker("Качество", selection: Binding(
                        get: { quality },
                        set: { newValue in
                            Task {
                                await model.setXiaomiQuality(newValue)
                                onReconnect()
                            }
                        })) {
                        ForEach(AppModel.XiaomiQuality.allCases) { q in Text(q.title).tag(q) }
                    }
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
                    Pill(text: "Запись не идёт", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                } else {
                    Pill(text: "Запись", systemImage: "record.circle", tint: .white.opacity(0.85))
                }
            }
            .buttonStyle(PressableButtonStyle())
        }
    }
}

/// Diagnostics strip; observes `PerformanceMonitor.sample` so only this view refreshes each second.
private struct PerformanceBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.performance.sample
        HStack(spacing: 10) {
            Text(String(format: "CPU %.0f%% · main %.0f%%", s.cpuTotal, s.cpuMain))
            Text(String(format: "%.0f МБ", s.memoryMB))
            Text(String(format: "UI +%.0f мс", s.maxHangMs))
                .foregroundStyle(s.maxHangMs > 250 ? Theme.danger : (s.maxHangMs > 80 ? Theme.warning : .white))
            Text("\(s.threads) потоков")
            Spacer()
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel, in: Capsule())
    }
}
