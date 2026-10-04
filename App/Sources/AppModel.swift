import AVFoundation
import Foundation
import Observation
import SwiftUI
import WaitingPawsCore

/// Root application state: settings, the running session, recording and history.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let store = SessionStore(rootDirectory: SessionStore.defaultRoot)
    let recorder = StreamRecorder()
    let embedded = EmbeddedGo2RTC()
    let performance = PerformanceMonitor()
    #if os(macOS)
    /// Lets an iPhone on the same network watch the camera and drive the training running on this Mac.
    let syncHost = SyncHost()
    #else
    /// Finds Macs running Waiting Paws and mirrors a training running there.
    let syncClient = SyncClient()
    #endif

    private(set) var session: TrainingSession?
    private(set) var history: [TrainingRecord] = []
    /// The record of the session that has just finished (drives the summary card).
    var lastRecord: TrainingRecord?
    var errorMessage: String?
    /// Recordings that landed in Photos (file names).
    private(set) var photosSavedFileNames: Set<String> = []
    /// Photos save failures per file name, shown inline next to that file only.
    private(set) var photosSaveErrors: [String: String] = [:]

    private var currentRecordingURL: URL?
    private var tickTask: Task<Void, Never>?
    private var awakeActivity: NSObjectProtocol?

    init() {
        LogMirror.start(directory: SessionStore.defaultRoot.appendingPathComponent("Logs", isDirectory: true))
        reloadHistory()
        startEmbeddedIfNeeded()
        setUpSync()
        performance.startHangLogging()
        if settings.showPerformance || CommandLine.arguments.contains("--perf") { performance.start() }
        #if os(iOS)
        KeyboardPrewarmer.prewarm(after: 2)
        #endif
        #if DEBUG
        // `--demo-clip <seconds>` records without a training for that long (the standalone recording flow).
        if let index = CommandLine.arguments.firstIndex(of: "--demo-clip"), index + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[index + 1]) {
            startRecording()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.stopRecording(deleteFile: false)
            }
        }
        // `--demo-session` starts a session from a sample schedule right away (handy for previews and UI checks).
        if CommandLine.arguments.contains("--demo-session") {
            let plan = PlanParser.parse(Self.demoPlanText)
            startSession(with: plan)
            // `--demo-finish-after <seconds>` finishes the demo session later (exercises recording + Photos).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-finish-after"), index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    self?.finishSession()
                }
            }
            // `--demo-phase leaving|away|break|finish` fast-forwards the demo session to that phase.
            if let index = CommandLine.arguments.firstIndex(of: "--demo-phase"), index + 1 < CommandLine.arguments.count {
                let phase = CommandLine.arguments[index + 1]
                session?.startExit()
                if phase == "away" || phase == "break" { session?.markBehindDoor() }
                if phase == "break" || phase == "finish" { session?.endExit() }
                if phase == "finish" { finishSession() }
            }
        }
        #endif
    }

    #if DEBUG
    static let demoPlanText = """
    🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026
    ➡️ Все перерывы 2 минуты
    1 выход - 5 секунд
    2 выход - 10 секунд
    3 выход - 30 секунд ИЛИ до вставания
    """
    #endif

    var client: Go2RTCClient? {
        settings.server.map { Go2RTCClient(server: $0) }
    }

    /// Boots the in-process go2rtc when the embedded mode is selected.
    func startEmbeddedIfNeeded() {
        guard settings.connectionMode == .embedded else { return }
        #if os(macOS)
        let lanPassword = settings.shareWithIPhone ? settings.lanPassword : nil
        #else
        let lanPassword: String? = nil
        #endif
        Task { await embedded.start(lanPassword: lanPassword) }
    }

    /// Waits (up to ~8 s) until the embedded server answers; returns immediately for an external server.
    func waitForServer() async {
        guard settings.connectionMode == .embedded else { return }
        for _ in 0..<80 {
            switch embedded.status {
            case .running, .failed, .unavailable: return
            case .idle, .starting: try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Session

    func startSession(with plan: TrainingPlan) {
        var plan = plan
        plan.renumber()
        #if os(iOS)
        if syncClient.isConnected {
            // The Mac owns trainings while linked: it starts the session (and its recording) and mirrors it back.
            if !plan.rawText.isEmpty { settings.lastPlanText = plan.rawText }
            lastRecord = nil
            syncClient.send(.startSession(plan))
            return
        }
        #endif
        // A recording that broke off earlier must not end up attached to this session.
        if !recorder.isRecording { currentRecordingURL = nil }
        let session = TrainingSession(plan: plan)
        session.autoFinishAfterLastBreak = settings.autoFinishAfterLastBreak
        self.session = session
        lastRecord = nil
        if !plan.rawText.isEmpty { settings.lastPlanText = plan.rawText }
        if settings.autoRecord { startRecording() }
        keepAwake(true)
        startTicking()
    }

    func finishSession() {
        if isMirroringSession {
            session?.finish() // forwarded to the Mac
            return
        }
        stopRecording(deleteFile: false)
        session?.finish()
        completeSessionIfNeeded()
    }

    /// Drops the running session without saving anything (asked explicitly by the user).
    func abandonSession() {
        #if os(iOS)
        if isMirroringSession {
            syncClient.send(.abandonSession)
            return
        }
        #endif
        stopRecording(deleteFile: true)
        session = nil
        lastRecord = nil
        tickTask?.cancel()
        keepAwake(false)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.session?.tick()
                self.completeSessionIfNeeded()
                if self.session == nil { return }
            }
        }
    }

    private func completeSessionIfNeeded() {
        guard let session, session.isFinished else { return }
        stopRecording(deleteFile: false)
        let record = session.makeRecord(recordingFileName: currentRecordingURL?.lastPathComponent)
        do {
            try store.save(record)
        } catch {
            errorMessage = "Не удалось сохранить лог: \(error.localizedDescription)"
        }
        history.insert(record, at: 0)
        lastRecord = record
        self.session = nil
        currentRecordingURL = nil
        tickTask?.cancel()
        keepAwake(false)
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecordingNow { stopRecording(deleteFile: false) } else { startRecording() }
    }

    func startRecording() {
        #if os(iOS)
        if syncClient.isConnected {
            syncClient.send(.startRecording)
            return
        }
        #endif
        Task { await startRecordingWhenReady() }
    }

    private func startRecordingWhenReady() async {
        await waitForServer()
        guard let client, !settings.streamName.isEmpty else {
            errorMessage = "Камера не настроена"
            return
        }
        guard !recorder.isRecording else { return }
        let plan = session?.plan ?? TrainingPlan(title: "Запись")
        let fileURL = store.newRecordingURL(for: plan)
        do {
            try recorder.start(url: client.mp4URL(stream: settings.streamName),
                               authorization: client.server.authorizationHeader,
                               to: fileURL)
            currentRecordingURL = fileURL
            session?.noteRecording(started: true, fileName: fileURL.lastPathComponent)
            if session == nil {
                // A recording without a training replaces whatever summary card was shown.
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            }
            print("[rec] started \(fileURL.lastPathComponent)")
        } catch {
            errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
        }
    }

    func stopRecording(deleteFile: Bool) {
        #if os(iOS)
        if syncClient.isConnected {
            syncClient.send(.stopRecording)
            return
        }
        #endif
        guard recorder.isRecording || currentRecordingURL != nil else { return }
        // A session keeps the screen awake on its own; a recording without one releases it here.
        defer { if session == nil { keepAwake(false) } }
        let wasRecording = recorder.isRecording
        if wasRecording {
            recorder.stop()
            session?.noteRecording(started: false)
            print("[rec] stopped \(currentRecordingURL?.lastPathComponent ?? "?") bytes=\(recorder.bytesWritten) error=\(recorder.lastError ?? "none")")
        }
        // Nothing arrived (stopped right away, or the stream never delivered): drop the empty file quietly.
        if wasRecording, recorder.bytesWritten == 0, let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
            return
        }
        if deleteFile, let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        } else if wasRecording, let url = currentRecordingURL {
            if settings.saveToPhotos {
                saveToPhotos(url)
            } else {
                Task { await finalizeRecording(url) }
            }
            if session == nil {
                // Without a training nothing else will claim the file: it becomes a standalone recording.
                currentRecordingURL = nil
                lastClip = RecordingClip(url: url, date: recorder.startedAt ?? Date())
                reloadClips()
            }
        }
    }

    /// Recordings being remuxed right now (file names); sharing waits for them.
    private(set) var finalizingFileNames: Set<String> = []
    private var finalizeTasks: [String: Task<Void, Never>] = [:]

    /// Turns a finished recording into a regular MP4 with an audio track (see `RecordingFinalizer`).
    /// Cheap for files that are already done; concurrent calls for one file share the work.
    func finalizeRecording(_ url: URL) async {
        let name = url.lastPathComponent
        if let running = finalizeTasks[name] {
            await running.value
            return
        }
        finalizingFileNames.insert(name)
        let task = Task {
            do {
                if try await RecordingFinalizer.finalize(url) { print("[rec] finalized \(name)") }
            } catch {
                print("[rec] finalize failed \(name): \(error.localizedDescription)")
            }
            finalizingFileNames.remove(name)
            finalizeTasks[name] = nil
        }
        finalizeTasks[name] = task
        await task.value
    }

    /// Copies a recording into the Photos library in the background; errors surface in the alert.
    func saveToPhotos(_ url: URL) {
        let name = url.lastPathComponent
        photosSaveErrors[name] = nil
        Task {
            await finalizeRecording(url)
            do {
                try await PhotoLibrarySaver.save(videoAt: url)
                photosSavedFileNames.insert(name)
                print("[photos] saved \(name)")
            } catch {
                photosSaveErrors[name] = error.localizedDescription
                print("[photos] failed \(name): \(error.localizedDescription)")
            }
        }
    }

    func photosStatus(for fileName: String) -> (saved: Bool, error: String?) {
        (photosSavedFileNames.contains(fileName), photosSaveErrors[fileName])
    }

    // MARK: - Camera quality

    /// go2rtc `subtype` values. Without the parameter go2rtc already asks for level 2 ("hd"),
    /// which on the C302 is only 848×480; higher levels unlock the 2K stream on cameras that support it.
    enum XiaomiQuality: String, CaseIterable, Identifiable {
        case auto = "auto", sd = "1", hd = "2", uhd = "3"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Авто"
            case .sd: return "SD"
            case .hd: return "HD"
            case .uhd: return "2K"
            }
        }
    }

    /// Current `subtype` of the selected stream's xiaomi:// source, if it is a Xiaomi camera.
    private(set) var xiaomiQuality: XiaomiQuality?
    /// Resolution the player actually receives (reported by the web player), for the quality menu.
    var videoSize: CGSize?

    /// The selected stream's `xiaomi://` source. While the camera is live, `/api/streams` describes the
    /// running connection without the source URL, so the config file is read instead.
    private func xiaomiSource(client: Go2RTCClient) async -> String? {
        let name = settings.streamName
        if let stream = (try? await client.streams())?.first(where: { $0.name == name }),
           let source = stream.sources.first(where: { $0.hasPrefix("xiaomi://") }) {
            return source
        }
        return (try? await client.configuredSources(stream: name))?.first { $0.hasPrefix("xiaomi://") }
    }

    /// Reads the selected stream's source and remembers its quality (nil for non-Xiaomi streams).
    func refreshXiaomiQuality() async {
        await waitForServer()
        guard let client, let source = await xiaomiSource(client: client),
              let components = URLComponents(string: source) else {
            xiaomiQuality = nil
            return
        }
        let raw = components.queryItems?.first { $0.name == "subtype" }?.value
        switch raw {
        case nil, "hd": xiaomiQuality = .hd
        case "sd": xiaomiQuality = .sd
        default: xiaomiQuality = XiaomiQuality(rawValue: raw!) ?? .hd
        }
    }

    /// Re-registers the stream with `subtype=<quality>`; the player reconnects on the next reload.
    func setXiaomiQuality(_ quality: XiaomiQuality) async {
        guard let client else { return }
        guard let source = await xiaomiSource(client: client), var components = URLComponents(string: source) else {
            errorMessage = "Не удалось сменить качество: go2rtc не отдал адрес камеры"
            return
        }
        var items = (components.queryItems ?? []).filter { $0.name != "subtype" }
        items.append(URLQueryItem(name: "subtype", value: quality.rawValue))
        components.queryItems = items
        guard let updated = components.string else { return }
        do {
            try await client.addStream(name: settings.streamName, source: updated)
            xiaomiQuality = quality
            print("[camera] quality \(quality.rawValue): \(updated)")
        } catch {
            errorMessage = "Не удалось сменить качество: \(error.localizedDescription)"
        }
    }

    // MARK: - History

    /// Recordings made without a training (or kept after deleting only the log), newest first.
    private(set) var clips: [RecordingClip] = []
    /// The recording without a training that has just been stopped (drives its small card).
    var lastClip: RecordingClip?

    /// Recording right now without a training session.
    var isRecordingClip: Bool { recorder.isRecording && session == nil }

    func reloadHistory() {
        history = store.loadAll()
        reloadClips()
    }

    private func reloadClips() {
        let active = currentRecordingURL?.lastPathComponent
        clips = store.standaloneRecordings(besides: history)
            .filter { $0.lastPathComponent != active }
            .map { url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return RecordingClip(url: url, date: attributes?[.creationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ record: TrainingRecord, includingRecording: Bool) {
        store.delete(record, includingRecording: includingRecording)
        history.removeAll { $0.id == record.id }
        if lastRecord?.id == record.id { lastRecord = nil }
        // A video kept without its log shows up as a standalone recording.
        if !includingRecording { reloadClips() }
    }

    func delete(_ clip: RecordingClip) {
        try? FileManager.default.removeItem(at: clip.url)
        clips.removeAll { $0.id == clip.id }
        if lastClip?.id == clip.id { lastClip = nil }
    }

    /// Removes every saved session with its log and video, and every standalone recording (nothing is touched in Photos).
    func deleteAll() {
        for record in history { store.delete(record, includingRecording: true) }
        for clip in clips { try? FileManager.default.removeItem(at: clip.url) }
        history = []
        clips = []
        lastRecord = nil
        lastClip = nil
    }

    // MARK: - Screen

    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        if on, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                                   reason: "Training session in progress")
        } else if !on, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
        #endif
    }
}

/// A video recorded without a training session: no plan and no log.
// MARK: - iPhone ↔ Mac link

extension AppModel {
    /// The session on screen is a mirror of a training running on the linked Mac.
    var isMirroringSession: Bool { session?.commandHandler != nil }

    /// Whether this iPhone shows a Mac's camera and training right now.
    var isLinkedToMac: Bool {
        #if os(iOS)
        return syncClient.isConnected
        #else
        return false
        #endif
    }

    /// go2rtc the camera view and the recorder talk to: the linked Mac's, or our own.
    var activeServer: Go2RTCServer? {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.server }
        #endif
        return settings.server
    }

    var activeStreamName: String {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.streamName ?? "" }
        #endif
        return settings.streamName
    }

    var activeCameraName: String {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.cameraTitle ?? "Камера Mac" }
        #endif
        return settings.cameraDisplayName
    }

    /// MSE works through the Mac's API port alone (WebRTC would need its UDP ports open on the LAN).
    var activePlayerMode: PlayerMode {
        isLinkedToMac ? .mse : settings.playerMode
    }

    var isRecordingNow: Bool {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.recordingSince != nil }
        #endif
        return recorder.isRecording
    }

    func recordingDuration(at now: Date) -> TimeInterval {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.recordingSince.map { now.timeIntervalSince($0) } ?? 0 }
        #endif
        return recorder.duration(at: now)
    }

    func setUpSync() {
        #if os(macOS)
        syncHost.stateProvider = { [unowned self] in
            SyncState(session: session?.snapshot,
                      recordingSince: recorder.isRecording ? recorder.startedAt : nil,
                      cameraReady: settings.isConfigured && (settings.connectionMode == .external || embedded.status.isRunning),
                      cameraTitle: settings.cameraDisplayName,
                      streamName: settings.streamName,
                      lastRecord: lastRecord)
        }
        syncHost.commandHandler = { [unowned self] command in applyRemote(command) }
        syncHost.accessProvider = { [unowned self] in
            SyncHost.SyncWelcomeAccess(port: EmbeddedGo2RTC.apiPort, username: EmbeddedGo2RTC.lanUsername,
                                       password: embedded.lanEnabled ? settings.lanPassword : "")
        }
        if settings.shareWithIPhone { syncHost.start() }
        #else
        syncClient.onState = { [unowned self] state in applySyncState(state) }
        syncClient.startBrowsing()
        #if DEBUG
        // `--demo-remote-steps`: once linked, press "Начать выход" and then "За дверью" from the iPhone.
        if CommandLine.arguments.contains("--demo-remote-steps") {
            Task { [weak self] in
                while self?.isMirroringSession != true { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(3))
                self?.session?.startExit()
                try? await Task.sleep(for: .seconds(4))
                self?.session?.markBehindDoor()
                // `--demo-remote-finish`: then "Вернулись", recording on, and finish (exercises the summary + log).
                guard CommandLine.arguments.contains("--demo-remote-finish") else { return }
                try? await Task.sleep(for: .seconds(3))
                self?.session?.endExit()
                try? await Task.sleep(for: .seconds(1))
                self?.startRecording()
                try? await Task.sleep(for: .seconds(8))
                self?.finishSession()
            }
        }
        #endif
        #endif
    }

    #if os(macOS)
    /// A button press from a linked iPhone.
    private func applyRemote(_ command: SyncCommand) {
        switch command {
        case .session(let command):
            if command == .finish {
                finishSession()
            } else if let session {
                command.apply(to: session)
            }
        case .startSession(let plan):
            if session == nil { startSession(with: plan) }
        case .abandonSession:
            abandonSession()
        case .startRecording:
            if !recorder.isRecording { startRecording() }
        case .stopRecording:
            stopRecording(deleteFile: false)
        }
    }
    #endif

    #if os(iOS)
    /// Mirrors the Mac's session; keeps the log of a mirrored training when it ends.
    private func applySyncState(_ state: SyncState?) {
        guard let state else {
            if isMirroringSession {
                session = nil
                keepAwake(false)
            }
            return
        }
        if let snapshot = state.session {
            if let session, isMirroringSession, session.isSameSession(as: snapshot) {
                session.restore(snapshot)
            } else if session == nil || isMirroringSession {
                let mirror = TrainingSession(snapshot: snapshot)
                mirror.commandHandler = { [weak self] command in self?.syncClient.send(.session(command)) }
                session = mirror
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            }
        } else if isMirroringSession {
            session = nil
            keepAwake(false)
            // The Mac saved the record together with the video; keep the log here too (the video stays on the Mac).
            if var record = state.lastRecord, !history.contains(where: { $0.id == record.id }) {
                record.recordingFileName = nil
                try? store.save(record)
                history.insert(record, at: 0)
                lastRecord = record
            }
        }
    }
    #endif
}

struct RecordingClip: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: String { url.lastPathComponent }

    func loadDuration() async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}
