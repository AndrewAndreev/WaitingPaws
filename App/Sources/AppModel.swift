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
    let store = SessionStore(rootDirectory: AppModel.storeRoot)
    /// Writes the recording's current part. A new one takes over when the other camera is put on screen.
    private(set) var recorder = StreamRecorder()
    let embedded = EmbeddedGo2RTC()
    let performance = PerformanceMonitor()
    /// Night mode and the other settings of the Mi Home camera on screen.
    let cameraModes = CameraModesModel()
    /// Turning the camera on screen (pan/tilt), a mode switched on from the live view.
    let panTilt = CameraPanTilt()
    #if os(macOS)
    /// Parsed schedule waiting for «Начать тренировку» (the «Сегодня» card and the plan timeline). A linked
    /// iPhone sees it and sets it too: a schedule pasted on either device shows up on both.
    var pendingPlan: TrainingPlan?
    /// The plan as the trainer sent it, for «Как у тренера» after edits on the timeline.
    var pendingOriginal: TrainingPlan?
    #endif
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
    #if os(iOS)
    /// A short note under the Mac link pill («Синхронизировано с …», «Видео сохранено на Mac»); fades by itself.
    var linkNotice: LinkNotice?
    @ObservationIgnored private var lastSyncState: SyncState?
    #endif
    /// Recordings that landed in Photos (file names).
    private(set) var photosSavedFileNames: Set<String> = []
    /// Photos save failures per file name, shown inline next to that file only.
    private(set) var photosSaveErrors: [String: String] = [:]

    /// Bumped when every player must reconnect (go2rtc's API came back after the app was suspended).
    var playerGeneration = 0
    /// Bumped when only the second camera's player must reconnect (its quality changed).
    private(set) var secondPlayerGeneration = 0
    /// The switcher put the second camera on screen (`isShowingSecondCamera` says whether there is one).
    private(set) var showsSecondCamera = false
    /// The second camera's `xiaomi://` source, once read (its quality; sent to a linked iPhone).
    private(set) var secondXiaomiSource: String?
    /// The selected camera's `xiaomi://` source, once read (quality, camera settings on a linked iPhone).
    private(set) var currentXiaomiSource: String?

    private var currentRecordingURL: URL?
    /// The stream the current part is written from: the camera that was on screen when it began.
    @ObservationIgnored private var recordingStream: String?
    /// The other camera put on screen while recording: its part is written already, and takes over with its first
    /// keyframe (the old camera keeps writing until then, so the joined video has no hole at the switch).
    @ObservationIgnored private var incomingPart: (recorder: StreamRecorder, segment: RecordingSegment, stream: String)?
    /// The recording in progress in parts: the first is `currentRecordingURL`; a new part starts whenever the camera
    /// stream broke off (go2rtc lost the camera) and came back. Joined into the first file when the recording stops.
    private var recordingSegments: [RecordingSegment] = []
    /// The camera stream broke off mid-recording: the recording goes on in a new part as soon as it is back.
    private(set) var recordingResuming = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var lastRequestedPart = 0
    private var tickTask: Task<Void, Never>?
    private var awakeActivity: NSObjectProtocol?
    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var recordingCutByBackground = false
    #endif

    init() {
        LogMirror.start(directory: Self.logsDirectory)
        reloadHistory()
        startEmbeddedIfNeeded()
        setUpSync()
        startStreamDiagnostics()
        #if DEBUG
        // `--demo-history`: sample trainings in the history list (in memory, nothing is written).
        if CommandLine.arguments.contains("--demo-history") { history = DemoData.history() }
        #if os(iOS)
        // `--demo-mac-link`, `--demo-mac-recording`: linked to a Mac (no network), idle or recording without a training.
        // `--demo-mac-recording-ends`: …and the Mac stops it 3 s later.
        let args = CommandLine.arguments
        // `--demo-mac-pending`: linked, with a schedule waiting on the Mac.
        if args.contains("--demo-mac-link") || args.contains("--demo-mac-recording") || args.contains("--demo-mac-recording-ends")
            || args.contains("--demo-mac-pending") {
            syncClient.onState = { [unowned self] state in applySyncState(state) }
            syncClient.demoLink(recording: args.contains("--demo-mac-recording") || args.contains("--demo-mac-recording-ends"),
                                stopAfter: args.contains("--demo-mac-recording-ends") ? 3 : nil,
                                pendingPlan: args.contains("--demo-mac-pending") ? PlanParser.parse(DemoData.planText) : nil)
        }
        // `--demo-mac-session`: linked to a Mac running the sample training (no network); `--demo-mac-lag <seconds>`
        // holds every command and every state from the Mac that long (a weak Wi-Fi: presses must show at once).
        if args.contains("--demo-mac-session") {
            let lag = args.firstIndex(of: "--demo-mac-lag").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            syncClient.onState = { [unowned self] state in applySyncState(state) }
            syncClient.demoSession(PlanParser.parse(Self.demoPlanText), lag: lag ?? 0)
            // `--demo-mac-switch-camera <seconds>`: the demo Mac flips between its two cameras that often.
            if let index = args.firstIndex(of: "--demo-mac-switch-camera"), index + 1 < args.count,
               let seconds = Double(args[index + 1]) {
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(seconds))
                        self?.syncClient.demoMacSwitchCamera()
                    }
                }
            }
        }
        // `--demo-remote-steps`: once linked (to a Mac or the demo one), press «Вышли» from the iPhone.
        if args.contains("--demo-remote-steps") {
            Task { [weak self] in
                while self?.isMirroringSession != true { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(3))
                self?.session?.markBehindDoor()
                // `--demo-remote-finish`: then "Вернулись", recording on, and finish (exercises the summary + log).
                guard args.contains("--demo-remote-finish") else { return }
                try? await Task.sleep(for: .seconds(3))
                self?.session?.endExit()
                try? await Task.sleep(for: .seconds(1))
                self?.startRecording()
                try? await Task.sleep(for: .seconds(8))
                self?.finishSession()
            }
        }
        // `--demo-hosts`: several computers with Waiting Paws nearby (the choice on the main screen and in Settings).
        if args.contains("--demo-hosts") { syncClient.demoHosts() }
        // `--demo-host`: one Mac nearby, never joined (the «рядом» card on the first-launch welcome screen).
        if args.contains("--demo-host") { syncClient.demoHosts(single: true) }
        #endif
        #if os(macOS)
        // `--demo-plan`: a parsed schedule waiting on the «Пульт» (no paste needed); `--demo-review` also opens its sheet.
        // `-demoPlanText <text>` puts that trainer's text there instead of the sample.
        if CommandLine.arguments.contains("--demo-plan") || CommandLine.arguments.contains("--demo-review") {
            let custom = UserDefaults.standard.string(forKey: "demoPlanText").flatMap { $0.isEmpty ? nil : $0 }
            setPending(PlanParser.parse(custom ?? DemoData.planText))
        }
        // `--demo-remote-pending`: 2 s after launch a linked iPhone «pastes» another schedule (the remote command path).
        if CommandLine.arguments.contains("--demo-remote-pending") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.applyRemote(.setPendingPlan(PlanParser.parse(Self.demoPlanText)))
            }
        }
        #endif
        // `--demo-camera-modes`: the C302's night mode & co. without a camera.
        if CommandLine.arguments.contains("--demo-camera-modes") { cameraModes.loadDemo() }
        #endif
        performance.startHangLogging()
        attachRecorder(recorder)
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
        // `--demo-show-second` (with `--demo-second-camera`): the second camera on screen.
        if CommandLine.arguments.contains("--demo-show-second") { showsSecondCamera = true }
        // `--demo-switch-camera <seconds>`: the switcher flips between the two cameras that often (with `--demo-clip`:
        // a recording joined from both).
        if let index = CommandLine.arguments.firstIndex(of: "--demo-switch-camera"), index + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[index + 1]) {
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self else { return }
                    self.showCamera(second: !self.showsSecondCamera)
                    print("[demo] camera \(self.showsSecondCamera ? "second" : "first") on screen")
                }
            }
        }
        #if os(iOS)
        // `--demo-rotate`: the screen turns to landscape and back, 3 s apart, like a phone turned in the hand (the
        // player must not load again: «[player] … load» in the log).
        if CommandLine.arguments.contains("--demo-rotate") {
            Task {
                for orientation in [UIInterfaceOrientationMask.landscapeRight, .portrait] {
                    try? await Task.sleep(for: .seconds(3))
                    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
                    print("[demo] turned to \(orientation == .portrait ? "portrait" : "landscape")")
                }
            }
        }
        #endif
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
            // `--demo-exits-done <n>`: the first n exits were done over the last minutes, with time outside and
            // breaks as planned (screenshots with a realistic timeline).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-exits-done"), index + 1 < CommandLine.arguments.count,
               let done = Int(CommandLine.arguments[index + 1]), let current = session {
                session = Self.demoReplay(current.plan, exitsDone: done)
            }
            // `--demo-phase away|break|finish` fast-forwards the demo session to that phase («leaving»: the walk to
            // the door an older iPhone's «Начать выход» starts).
            if let index = CommandLine.arguments.firstIndex(of: "--demo-phase"), index + 1 < CommandLine.arguments.count {
                let phase = CommandLine.arguments[index + 1]
                if phase == "leaving" { session?.startExit() } else { session?.markBehindDoor() }
                if phase == "break" || phase == "finish" { session?.endExit() }
                if phase == "finish" { finishSession() }
            }
        }
        #endif
    }

    #if DEBUG
    private final class DemoClock: @unchecked Sendable { var offset: TimeInterval = 0 }

    /// A session of `plan` whose first `exitsDone` exits happened in the past at a realistic pace; it is now
    /// in the break after the last of them.
    private static func demoReplay(_ plan: TrainingPlan, exitsDone: Int) -> TrainingSession {
        let clock = DemoClock()
        let done = min(exitsDone, plan.exits.count)
        // `--demo-break-left <seconds>`: how much of the last break is still ahead (4 s by default; `--demo-break-over
        // <seconds>`: the break ran over by that much).
        let args = CommandLine.arguments
        func value(_ flag: String) -> TimeInterval? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? TimeInterval(args[$0 + 1]) : nil } }
        let early = value("--demo-break-over").map { -$0 } ?? value("--demo-break-left") ?? 4
        let linger: TimeInterval = 3
        // The replay ends `early` seconds before the last break is over, which is now: from then on the session's
        // clock is the real one, like the views' (TimelineView) that count the time left.
        let total = (0..<done).reduce(0) { $0 + plan.exits[$1].duration + linger + plan.breakAfter(exitAt: $1) }
        clock.offset = -(total - early)
        let session = TrainingSession(plan: plan, clock: { Date().addingTimeInterval(clock.offset) })
        if args.contains("--demo-recording") { session.noteRecording(started: true, fileName: "demo.mp4") }
        for index in 0..<done {
            session.markBehindDoor(); clock.offset += plan.exits[index].duration + linger
            session.endExit(); clock.offset += plan.breakAfter(exitAt: index)
        }
        clock.offset = 0
        return session
    }

    /// The demo schedule; `-demoPlanText <text>` puts another one there (UI checks of a given trainer's text).
    static var demoPlanText: String {
        if let text = UserDefaults.standard.string(forKey: "demoPlanText"), !text.isEmpty { return text }
        return CoreLanguage.current == .ru ? """
        🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026
        ➡️ Все перерывы 2 минуты
        1 выход - 15 секунд
        2 выход - 30 секунд
        3 выход - 1 минута
        4 выход - 45 секунд
        5 выход - 2 минуты ИЛИ до вставания
        """ : """
        🐶 Monday training - Anna/Mark - 05.10.2026
        ➡️ All breaks 2 minutes
        Exit 1 - 15 seconds
        Exit 2 - 30 seconds
        Exit 3 - 1 minute
        Exit 4 - 45 seconds
        Exit 5 - 2 minutes OR until the dog stands up
        """
    }
    #endif

    /// DEBUG `--ui-preview`: UI checks next to a running copy of the app — no embedded go2rtc, no iPhone link,
    /// no recording, history and logs in a temporary folder (never the real ones).
    static let isUIPreview: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--ui-preview")
        #else
        return false
        #endif
    }()

    /// DEBUG `--sync-in-preview`: the iPhone ↔ Mac link in `--ui-preview` copies (direct `--sync-port` /
    /// `--sync-host`, no Bonjour, pairings not saved) — checks next to the user's own copies.
    static let isSyncTest: Bool = {
        #if DEBUG
        return isUIPreview && CommandLine.arguments.contains("--sync-in-preview")
        #else
        return false
        #endif
    }()

    /// DEBUG `--demo-session`: the sample schedule must not become the user's «last pasted text».
    static let isDemoLaunch: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-session")
        #else
        return false
        #endif
    }()

    static var storeRoot: URL {
        isUIPreview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("WaitingPawsPreview", isDirectory: true)
            : SessionStore.defaultRoot
    }

    /// The app's own log (stdout/stderr, go2rtc): `Library/Caches/Logs`, not among the user's files and not
    /// in backups.
    static var logsDirectory: URL {
        if isUIPreview { return storeRoot.appendingPathComponent("Logs", isDirectory: true) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Logs", isDirectory: true)
    }

    var client: Go2RTCClient? {
        settings.server.map { Go2RTCClient(server: $0) }
    }

    /// Boots the in-process go2rtc when the embedded mode is selected.
    func startEmbeddedIfNeeded() {
        guard settings.connectionMode == .embedded, !Self.isUIPreview else { return }
        #if os(macOS)
        let lanPassword = settings.shareWithIPhone ? settings.lanPassword : nil
        #else
        let lanPassword: String? = nil
        #endif
        Task { await embedded.start(lanPassword: lanPassword) }
    }

    /// Every 10 s: frames go2rtc dropped because a viewer (the player, the recording, a linked iPhone) fell behind.
    /// A dropped frame freezes that viewer until the next keyframe, so this line explains most freezes.
    private func startStreamDiagnostics() {
        guard !Self.isUIPreview else { return }
        Task { [weak self] in
            var last: [String: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard self.settings.connectionMode == .embedded, self.embedded.status.isRunning,
                      !self.settings.streamName.isEmpty, let client = self.client,
                      let data = try? await client.streamInfo(name: self.settings.streamName) else { continue }
                let drops = Self.viewerDrops(data)
                for (viewer, total) in drops.sorted(by: { $0.key < $1.key }) where total > (last[viewer] ?? 0) {
                    print("[go2rtc] \(Date().formatted(.dateTime.hour().minute().second())) \(viewer) fell behind: "
                          + "\(total - (last[viewer] ?? 0)) frames dropped in 10 s")
                }
                last = drops
            }
        }
    }

    /// Dropped frames per viewer ("mse ws 192.168.1.20:5123") from `GET /api/streams?src=`.
    nonisolated static func viewerDrops(_ data: Data) -> [String: Int] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let consumers = object["consumers"] as? [[String: Any]] else { return [:] }
        var result: [String: Int] = [:]
        for consumer in consumers {
            let name = ["format_name", "protocol", "remote_addr"].compactMap { consumer[$0] as? String }.joined(separator: " ")
            let drops = (consumer["senders"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["drops"] as? Int ?? 0) }
            result[name.isEmpty ? "viewer" : name, default: 0] += drops
        }
        return result
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

    /// The start starts the recording too: the setting is on and there is a camera here (a linked iPhone does not
    /// know the Mac's setting: plain «Начать тренировку» there).
    var startRecordsToo: Bool {
        if isLinkedToMac { return false }
        return settings.autoRecord && settings.isConfigured
    }

    /// «Начать тренировку и запись» when the start starts the recording too.
    var startTitle: String {
        startRecordsToo ? String(localized: "Начать тренировку и запись") : String(localized: "Начать тренировку")
    }

    /// «Завершить тренировку и запись» while a recording runs: finishing stops it.
    var finishTitle: String {
        isRecordingNow ? String(localized: "Завершить тренировку и запись") : String(localized: "Завершить тренировку")
    }

    func startSession(with plan: TrainingPlan) {
        var plan = plan
        plan.renumber()
        #if os(iOS)
        if syncClient.isConnected {
            // The Mac owns trainings while linked: it starts the session (and its recording) and mirrors it back.
            lastRecord = nil
            syncClient.send(.startSession(plan))
            return
        }
        #endif
        // A recording that broke off earlier must not end up attached to this session.
        if !isRecordingLocally { currentRecordingURL = nil }
        let session = TrainingSession(plan: plan)
        self.session = session
        lastRecord = nil
        // Without a camera the training is the timer and the log only.
        if settings.autoRecord, settings.isConfigured, !Self.isUIPreview { startRecording() }
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
            errorMessage = String(localized: "Не удалось сохранить лог: \(error.localizedDescription)")
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
            errorMessage = String(localized: "Камера не настроена")
            return
        }
        guard !isRecordingLocally else { return }
        let plan = session?.plan ?? TrainingPlan(title: String(localized: "Запись"))
        let fileURL = store.newRecordingURL(for: plan)
        let stream = shownLocalStreamName
        do {
            try recorder.start(url: client.mp4URL(stream: stream),
                               authorization: client.server.authorizationHeader,
                               to: fileURL)
            currentRecordingURL = fileURL
            recordingStream = stream
            recordingSegments = [RecordingSegment(url: fileURL, startedAt: recorder.startedAt ?? Date())]
            session?.noteRecording(started: true, fileName: fileURL.lastPathComponent)
            if session == nil {
                // A recording without a training replaces whatever summary card was shown.
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            }
            print("[rec] started \(fileURL.lastPathComponent) from \(stream)")
        } catch {
            errorMessage = String(localized: "Не удалось начать запись: \(error.localizedDescription)")
        }
    }

    func stopRecording(deleteFile: Bool) {
        #if os(iOS)
        if syncClient.isConnected {
            syncClient.send(.stopRecording)
            return
        }
        #endif
        let wasRecording = isRecordingLocally
        resumeTask?.cancel()
        resumeTask = nil
        recordingResuming = false
        dropIncomingPart()
        recordingStream = nil
        guard wasRecording || currentRecordingURL != nil else { return }
        // A session keeps the screen awake on its own; a recording without one releases it here.
        defer { if session == nil { keepAwake(false) } }
        if recorder.isRecording {
            recorder.stop()
            noteSegmentEnded()
        }
        let startedAt = recordingSegments.first?.startedAt ?? recorder.startedAt ?? Date()
        // Parts that got nothing (the camera was still away) are dropped; the first file stays as the name.
        let filled = recordingSegments.filter { $0.bytes > 0 }
        for part in recordingSegments.dropFirst() where part.bytes == 0 { try? FileManager.default.removeItem(at: part.url) }
        let parts = filled.filter { $0.url != currentRecordingURL }.map(\.url)
        recordingSegments = []
        if wasRecording {
            session?.noteRecording(started: false)
            print("[rec] stopped \(currentRecordingURL?.lastPathComponent ?? "?") parts=\(filled.count) error=\(recorder.lastError ?? "none")")
        }
        // Nothing arrived (stopped right away, or the stream never delivered): drop the empty file quietly.
        if wasRecording, filled.isEmpty, let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
            return
        }
        if deleteFile, let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            for part in parts { try? FileManager.default.removeItem(at: part) }
            currentRecordingURL = nil
        } else if wasRecording, let url = currentRecordingURL {
            let needsJoin = filled.count > 1 || filled.first?.url != url
            Task {
                if needsJoin { await joinRecording(url, segments: filled, startedAt: startedAt) }
                if settings.saveToPhotos {
                    saveToPhotos(url)
                } else {
                    await finalizeRecording(url)
                }
            }
            if session == nil {
                // Without a training nothing else will claim the file: it becomes a standalone recording.
                currentRecordingURL = nil
                lastClip = RecordingClip(url: url, date: startedAt)
                reloadClips()
            }
        }
    }

    /// Recording here (not on a linked Mac): writing, or waiting for the camera to come back.
    private var isRecordingLocally: Bool { recorder.isRecording || recordingResuming }

    /// When the recording in progress here started (its first part).
    private var localRecordingStartedAt: Date? { recordingSegments.first?.startedAt ?? recorder.startedAt }

    private func noteSegmentEnded() {
        guard let last = recordingSegments.indices.last else { return }
        recordingSegments[last].bytes = recorder.bytesWritten
        recordingSegments[last].mediaStartedAt = recorder.firstFragmentAt
    }

    /// The camera recorded here: the one on screen.
    private var shownLocalStreamName: String {
        showsSecondCamera && settings.hasSecondCamera ? settings.secondStreamName : settings.streamName
    }

    /// The current part's recorder: its video start goes into its part, its end (without a stop) starts the next one.
    private func attachRecorder(_ recorder: StreamRecorder) {
        recorder.onEnded = { [weak self, weak recorder] reason in
            MainActor.assumeIsolated {
                guard let self, recorder === self.recorder else { return }
                self.recordingStreamEnded(reason)
            }
        }
        recorder.onFirstFragment = { [weak self, weak recorder] in
            MainActor.assumeIsolated {
                guard let self, let recorder, recorder === self.recorder,
                      let last = self.recordingSegments.indices.last else { return }
                self.recordingSegments[last].mediaStartedAt = recorder.firstFragmentAt
            }
        }
    }

    private func partURL(_ main: URL, number: Int) -> URL {
        store.recordingsDirectory
            .appendingPathComponent(".parts", isDirectory: true)
            .appendingPathComponent("\(main.deletingPathExtension().lastPathComponent)-part\(number).mp4")
    }

    /// «То, что на экране, то и записывается»: the camera on screen changed (the switcher, here or on the linked
    /// iPhone; another camera chosen) while recording here, so the recording goes on from it in a new part. The old
    /// camera keeps writing until the new one's first keyframe — up to a whole GOP after the switch — and the parts
    /// are joined into one video when the recording stops.
    func followShownCameraInRecording() {
        guard isRecordingLocally, let client, let main = currentRecordingURL else { return }
        let stream = shownLocalStreamName
        guard !stream.isEmpty else { return }
        if let incomingPart {
            guard incomingPart.stream != stream else { return }
            dropIncomingPart()
        }
        guard stream != recordingStream else { return }
        if recordingResuming {
            // Nothing is being written (the camera broke off): the next part simply comes from the new one.
            resumeTask?.cancel()
            startNextRecordingPart()
            return
        }
        let number = recordingSegments.count + 1
        let url = partURL(main, number: number)
        let next = StreamRecorder()
        do {
            try next.start(url: client.mp4URL(stream: stream), authorization: client.server.authorizationHeader, to: url)
        } catch {
            print("[rec] part \(number) from \(stream) failed: \(error.localizedDescription)")
            return
        }
        next.onFirstFragment = { [weak self, weak next] in
            MainActor.assumeIsolated {
                guard let self, let next else { return }
                self.takeOverRecording(by: next)
            }
        }
        next.onEnded = { [weak self, weak next] reason in
            MainActor.assumeIsolated {
                guard let self, let next, self.incomingPart?.recorder === next else { return }
                self.incomingPartEnded(reason)
            }
        }
        incomingPart = (next, RecordingSegment(url: url, startedAt: next.startedAt ?? Date()), stream)
        print("[rec] \(stream) on screen: part \(number) starts with its next keyframe")
    }

    /// The new camera's first keyframe: its part becomes the recording's current one, the old camera stops.
    private func takeOverRecording(by next: StreamRecorder) {
        guard let incoming = incomingPart, incoming.recorder === next else { return }
        incomingPart = nil
        if recorder.isRecording {
            recorder.stop()
            noteSegmentEnded()
        }
        var segment = incoming.segment
        segment.mediaStartedAt = next.firstFragmentAt
        recordingSegments.append(segment)
        recorder = next
        attachRecorder(next)
        recordingStream = incoming.stream
        recordingResuming = false
        resumeTask?.cancel()
        resumeTask = nil
        print("[rec] part \(recordingSegments.count) from \(incoming.stream) took over")
    }

    /// The new camera's stream ended before its first keyframe (the camera is away): try again in a while; meanwhile
    /// the old camera goes on, or — if it broke off too — the recording waits for the one on screen.
    private func incomingPartEnded(_ reason: String?) {
        print("[rec] \(incomingPart?.stream ?? "?") did not start (\(reason ?? "ended")): trying again")
        dropIncomingPart()
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.recordingResuming { self.startNextRecordingPart() } else { self.followShownCameraInRecording() }
        }
    }

    private func dropIncomingPart() {
        guard let incoming = incomingPart else { return }
        incomingPart = nil
        incoming.recorder.stop()
        try? FileManager.default.removeItem(at: incoming.segment.url)
    }

    /// The recording's stream ended without a stop: go2rtc lost the camera (it reconnects by itself) or refused the
    /// stream. The recording goes on in a new part as soon as the stream is back, instead of silently ending here.
    private func recordingStreamEnded(_ reason: String?) {
        guard let main = currentRecordingURL, !recordingSegments.isEmpty else { return }
        noteSegmentEnded()
        // A try that got nothing (the camera still away) is not a part, and not worth a line in the log each time.
        if let last = recordingSegments.last, last.bytes == 0, last.url != main {
            try? FileManager.default.removeItem(at: last.url)
            recordingSegments.removeLast()
        } else {
            print("[rec] the camera stream broke off (\(reason ?? "ended")): going on when the camera is back")
        }
        recordingResuming = true
        // The camera just put on screen is already on its way in: it takes over.
        guard incomingPart == nil else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.startNextRecordingPart()
        }
    }

    private func startNextRecordingPart() {
        let stream = shownLocalStreamName
        guard recordingResuming, incomingPart == nil, let main = currentRecordingURL, let client, !stream.isEmpty else { return }
        let number = recordingSegments.count + 1
        let url = partURL(main, number: number)
        do {
            try recorder.start(url: client.mp4URL(stream: stream),
                               authorization: client.server.authorizationHeader, to: url)
            recordingSegments.append(RecordingSegment(url: url, startedAt: recorder.startedAt ?? Date()))
            recordingStream = stream
            recordingResuming = false
            if number != lastRequestedPart { print("[rec] waiting for the camera to write part \(number)") }
            lastRequestedPart = number
        } catch {
            print("[rec] part \(number) failed: \(error.localizedDescription)")
            recordingStreamEnded(error.localizedDescription)
        }
    }

    /// Puts the parts of a recording the camera broke off back into its first file (see `RecordingFinalizer.join`).
    private func joinRecording(_ url: URL, segments: [RecordingSegment], startedAt: Date) async {
        let name = url.lastPathComponent
        finalizingFileNames.insert(name)
        defer { finalizingFileNames.remove(name) }
        do {
            try await RecordingFinalizer.join(segments, startedAt: startedAt, into: url)
            print("[rec] joined \(segments.count) parts into \(name)")
        } catch {
            print("[rec] joining \(name) failed: \(error.localizedDescription)")
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
            case .auto: return String(localized: "Авто")
            case .sd: return "SD"
            case .hd: return "HD"
            case .uhd: return "2K"
            }
        }
    }

    /// Current `subtype` of the selected stream's xiaomi:// source, if it is a Xiaomi camera.
    private(set) var xiaomiQuality: XiaomiQuality?
    /// Resolution the player actually receives (reported by the web player), for the quality menu.
    var videoSize: CGSize? {
        didSet { rememberQualityResolution(size: videoSize, quality: xiaomiQuality, source: currentXiaomiSource) }
    }

    /// The second camera's quality: of its picture, and of the recording while it is on screen.
    var secondXiaomiQuality: XiaomiQuality? { secondXiaomiSource.map(Self.quality(of:)) }
    /// What the second camera's player receives.
    var secondVideoSize: CGSize? {
        didSet { rememberQualityResolution(size: secondVideoSize, quality: secondXiaomiQuality, source: secondXiaomiSource) }
    }

    /// «HD · 480p» once the camera (`source`, by default the one on screen) has been seen at that level,
    /// else «HD». «Авто» has no fixed resolution.
    func qualityTitle(_ quality: XiaomiQuality, source: String? = nil) -> String {
        guard quality != .auto, let did = (source ?? currentXiaomiSource).flatMap({ Self.query("did", in: $0) }),
              let seen = settings.qualityResolutions[did]?[quality.rawValue],
              let height = seen.split(separator: "x").last.flatMap({ Int($0) }) else { return quality.title }
        return "\(quality.title) · \(height)p"
    }

    /// Remembers what the current level gave. Only for an explicit `subtype`: without one go2rtc picks
    /// a level by model (3 on the C200/C300), which is not necessarily the «HD» shown then.
    private func rememberQualityResolution(size: CGSize?, quality: XiaomiQuality?, source: String?) {
        guard let size, size.width > 0, size.height > 0, let quality, quality != .auto,
              let source, Self.query("subtype", in: source) == quality.rawValue,
              let did = Self.query("did", in: source) else { return }
        let seen = "\(Int(size.width))x\(Int(size.height))"
        if settings.qualityResolutions[did]?[quality.rawValue] != seen {
            settings.qualityResolutions[did, default: [:]][quality.rawValue] = seen
        }
    }

    private static func query(_ name: String, in source: String) -> String? {
        URLComponents(string: source)?.queryItems?.first { $0.name == name }?.value
    }

    /// The level a `xiaomi://` source asks for: without `subtype` go2rtc's default is «HD».
    private static func quality(of source: String) -> XiaomiQuality {
        switch query("subtype", in: source) {
        case nil, "hd": return .hd
        case "sd": return .sd
        case let raw?: return XiaomiQuality(rawValue: raw) ?? .hd
        }
    }

    /// The selected stream's `xiaomi://` source. While the camera is live, `/api/streams` describes the
    /// running connection without the source URL, so the config file is read instead.
    private func xiaomiSource(client: Go2RTCClient, stream name: String? = nil) async -> String? {
        let name = name ?? settings.streamName
        if let stream = (try? await client.streams())?.first(where: { $0.name == name }),
           let source = stream.sources.first(where: { $0.hasPrefix("xiaomi://") }) {
            return source
        }
        return (try? await client.configuredSources(stream: name))?.first { $0.hasPrefix("xiaomi://") }
    }

    #if DEBUG
    /// `--demo-quality` (with `--demo-second-camera`): Mi Home sources for both cameras, the first at SD and the
    /// second at HD, without go2rtc; a quality change stays in memory.
    private static func demoXiaomiSource(second: Bool) -> String? {
        guard CommandLine.arguments.contains("--demo-quality") else { return nil }
        return second ? "xiaomi://demo:cn@127.0.0.1?did=2&model=chuangmi.camera.ipc019&subtype=2"
                      : "xiaomi://demo:cn@127.0.0.1?did=1&model=chuangmi.camera.069a01&subtype=1"
    }
    #endif

    /// Reads the selected stream's source and remembers its quality (nil for non-Xiaomi streams).
    func refreshXiaomiQuality() async {
        #if DEBUG
        if let demo = Self.demoXiaomiSource(second: false) {
            currentXiaomiSource = demo
            xiaomiQuality = Self.quality(of: demo)
            return
        }
        #endif
        await waitForServer()
        guard let client, let source = await xiaomiSource(client: client), URLComponents(string: source) != nil else {
            xiaomiQuality = nil
            currentXiaomiSource = nil
            return
        }
        currentXiaomiSource = source
        xiaomiQuality = Self.quality(of: source)
    }

    /// Re-registers the stream with `subtype=<quality>`: the quality of that camera's picture and of the recording while
    /// it is on screen. go2rtc then creates a new stream and the old one, with
    /// its own camera connection, lives until its viewers leave, so that camera's players reconnect (also a linked
    /// iPhone's, through `SyncState.streamRevision`).
    func setXiaomiQuality(_ quality: XiaomiQuality, second: Bool = false) async {
        #if DEBUG
        if let demo = Self.demoXiaomiSource(second: second) {
            let updated = demo.replacingOccurrences(of: "subtype=\(Self.quality(of: demo).rawValue)", with: "subtype=\(quality.rawValue)")
            if second { secondXiaomiSource = updated } else { currentXiaomiSource = updated; xiaomiQuality = quality }
            return
        }
        #endif
        guard let client else { return }
        let stream = second ? settings.secondStreamName : settings.streamName
        guard let source = await xiaomiSource(client: client, stream: stream), var components = URLComponents(string: source) else {
            errorMessage = String(localized: "Не удалось сменить качество: go2rtc не отдал адрес камеры")
            return
        }
        var items = (components.queryItems ?? []).filter { $0.name != "subtype" }
        items.append(URLQueryItem(name: "subtype", value: quality.rawValue))
        components.queryItems = items
        guard let updated = components.string else { return }
        do {
            try await client.addStream(name: stream, source: updated)
            if second {
                secondXiaomiSource = updated
                secondVideoSize = nil
                secondPlayerGeneration += 1
            } else {
                xiaomiQuality = quality
                currentXiaomiSource = updated
                videoSize = nil
                playerGeneration += 1
            }
            print("[camera] \(second ? "second camera " : "")quality \(quality.rawValue): \(updated)")
        } catch {
            errorMessage = String(localized: "Не удалось сменить качество: \(error.localizedDescription)")
        }
    }

    /// Reads which modes the camera on screen has (night mode, flip…) and their values. On an iPhone
    /// linked to a Mac it asks the Mac's go2rtc: the settings live in the camera, not in either app.
    func refreshCameraModes() async {
        await waitForServer()
        guard let server = activeServer, !Self.isUIPreview else {
            await cameraModes.load(server: nil, source: nil)
            return
        }
        // The camera on screen: its modes and turning (the second camera's too).
        let source: String?
        #if os(iOS)
        // The Mac's go2rtc config (with the Xiaomi tokens) is closed to the LAN: the Mac sends the source itself.
        source = isLinkedToMac
            ? (isShowingSecondCamera ? syncClient.state?.secondCameraSource : syncClient.state?.cameraSource)
            : await xiaomiSource(client: Go2RTCClient(server: server), stream: shownStreamName)
        #else
        source = await xiaomiSource(client: Go2RTCClient(server: server), stream: shownStreamName)
        if isShowingSecondCamera { secondXiaomiSource = source }
        #endif
        await cameraModes.load(server: server, source: source)
    }

    /// The second camera's `xiaomi://` source, for a linked iPhone (its modes and turning there).
    func refreshSecondCameraSource() async {
        #if DEBUG
        if let demo = Self.demoXiaomiSource(second: true) {
            secondXiaomiSource = demo
            return
        }
        #endif
        guard settings.hasSecondCamera, let client, !Self.isUIPreview else {
            secondXiaomiSource = nil
            return
        }
        await waitForServer()
        secondXiaomiSource = await xiaomiSource(client: client, stream: settings.secondStreamName)
    }

    /// What the camera settings depend on (a `.task` id).
    var cameraModesKey: String {
        #if os(iOS)
        if isLinkedToMac {
            let source = isShowingSecondCamera ? syncClient.state?.secondCameraSource : syncClient.state?.cameraSource
            return "mac|\(shownStreamName)|\(source ?? "")"
        }
        #endif
        return "own|\(shownStreamName)"
    }

    // MARK: - Xiaomi account

    /// «Выйти из аккаунта Xiaomi»: go2rtc forgets the account's token, its cameras are removed from go2rtc, and
    /// when one of them was selected the app goes on without a camera.
    func signOutOfXiaomi(accountID: String) async {
        await waitForServer()
        guard let client else { return }
        do {
            try await client.xiaomiLogout(accountID: accountID)
        } catch {
            errorMessage = String(localized: "Не удалось выйти из аккаунта Xiaomi: \(error.localizedDescription)")
            return
        }
        print("[xiaomi] signed out of account \(accountID)")
        let prefix = "xiaomi://\(accountID):"
        let names = ((try? await client.streams()) ?? []).map(\.name)
        let sources = (try? await client.configuredSources(streams: names)) ?? [:]
        var removedSelected = currentXiaomiSource?.hasPrefix(prefix) == true
        for (name, list) in sources where list.contains(where: { $0.hasPrefix(prefix) }) {
            try? await client.deleteStream(name: name)
            if name == settings.streamName { removedSelected = true }
            if name == settings.secondStreamName { removeSecondCamera() }
        }
        if settings.xiaomiAccountID == accountID { settings.xiaomiAccountID = "" }
        if removedSelected {
            settings.streamName = ""
            settings.cameraTitle = ""
            settings.withoutCamera = true
            currentXiaomiSource = nil
            xiaomiQuality = nil
            videoSize = nil
            await cameraModes.load(server: nil, source: nil)
        }
    }

    // MARK: - History

    /// Recordings made without a training (or kept after deleting only the log), newest first.
    private(set) var clips: [RecordingClip] = []
    /// The recording without a training that has just been stopped (drives its small card).
    var lastClip: RecordingClip?

    /// Recording right now without a training session.
    /// Recording without a training — here, or on the linked Mac (the iPhone then shows the same full-screen view).
    var isRecordingClip: Bool { isRecordingNow && session == nil }

    func reloadHistory() {
        #if DEBUG
        // `--demo-history` keeps its sample trainings (screenshots); nothing real is shown or written.
        if CommandLine.arguments.contains("--demo-history") {
            if history.isEmpty { history = DemoData.history() }
            return
        }
        #endif
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

    // MARK: - App lifecycle

    #if os(iOS)
    /// The app went to the background. iOS suspends it a few seconds later (there is no background mode for a
    /// camera), and then the link to the Mac, go2rtc's listener and the players' connections die: coming back meant
    /// connecting again and waiting for frames. So the app asks for the usual ~30 s of grace whenever there is
    /// something to keep — a training, a recording, a camera or the link: a quick look at the messenger finds all
    /// of it still there. When the grace runs out a recording is closed cleanly and goes on when the app is back;
    /// the training keeps time by the clock and catches up on return.
    func didEnterBackground() {
        let worthKeeping = session != nil || isRecordingLocally || isLinkedToMac || settings.isConfigured
        guard worthKeeping, backgroundTask == .invalid else { return }
        print("[app] in the background: keeping the camera and the link for a while")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep the camera") { [weak self] in
            MainActor.assumeIsolated { self?.cutRecordingForBackground() }
        }
    }

    private func cutRecordingForBackground() {
        print("[app] the background grace ran out")
        if isRecordingLocally, !isLinkedToMac {
            recordingCutByBackground = true
            stopRecording(deleteFile: false)
            print("[rec] stopped: the app stayed in the background")
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Back in the foreground: reopen go2rtc's API if iOS closed it, and resume a recording cut by the suspension.
    func didBecomeActive() async {
        endBackgroundTask()
        if await embedded.recoverIfNeeded() { playerGeneration += 1 }
        syncClient.autoConnectIfPossible()
        guard recordingCutByBackground else { return }
        recordingCutByBackground = false
        startRecording()
        linkNotice = LinkNotice(title: String(localized: "Запись продолжена"),
                                detail: String(localized: "Пока приложение было свёрнуто, видео не записывалось. Начало записи — в истории."))
    }
    #endif

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

    /// What the linked host is called in the texts: "Mac", "ПК" («Запись на ПК»).
    var linkedHostKind: String {
        #if os(iOS)
        return syncClient.host?.kindTitle ?? "Mac"
        #else
        return "Mac"
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

    // MARK: Second camera

    /// The second camera to look at: ours, or the linked Mac's. Empty without one.
    var activeSecondStreamName: String {
        #if DEBUG
        // `--demo-second-camera`: a second camera «Комната» (UI checks; the settings are not written).
        if CommandLine.arguments.contains("--demo-second-camera") { return "room" }
        #endif
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.secondStreamName ?? "" }
        #endif
        return settings.hasSecondCamera ? settings.secondStreamName : ""
    }

    var activeSecondCameraName: String {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-second-camera") { return String(localized: "Комната") }
        #endif
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.secondCameraTitle ?? String(localized: "Камера 2") }
        #endif
        return settings.secondCameraDisplayName
    }

    var hasSecondCamera: Bool { !activeSecondStreamName.isEmpty }

    /// The second camera is the one on screen, and the one recorded (the first one keeps playing behind it).
    var isShowingSecondCamera: Bool { showsSecondCamera && hasSecondCamera }

    /// The stream on screen: the first camera's, or the second one's the switcher shows. Turning, quality, the
    /// camera's modes and the recording follow it.
    var shownStreamName: String { isShowingSecondCamera ? activeSecondStreamName : activeStreamName }

    func showCamera(second: Bool) {
        guard second != showsSecondCamera else { return }
        panTilt.stop()
        showsSecondCamera = second
        #if os(iOS)
        // The linked Mac shows — and records — the same camera. A Mac from before that would drop the link on the
        // command: its state has no camera in it.
        if syncClient.isConnected, syncClient.state?.showsSecondCamera != nil {
            syncClient.send(.showCamera(second: second))
            print("[sync] \(second ? "second" : "first") camera on screen, on the \(linkedHostKind) too")
        }
        #endif
        followShownCameraInRecording()
    }

    func removeSecondCamera() {
        settings.secondStreamName = ""
        settings.secondCameraTitle = ""
        showsSecondCamera = false
        secondVideoSize = nil
        followShownCameraInRecording()
    }

    var activeCameraName: String {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.cameraTitle ?? String(localized: "Камера \(linkedHostKind)") }
        #endif
        return settings.cameraDisplayName
    }

    /// MSE works through the Mac's API port alone (WebRTC would need its UDP ports open on the LAN).
    /// Bumped whenever the players must reconnect: ours, or the linked Mac's (its quality changed).
    var activePlayerGeneration: Int {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.streamRevision ?? 0 }
        #endif
        return playerGeneration
    }

    /// For the second camera's player: also bumped when only its quality changed. A linked Mac's `streamRevision`
    /// already counts that change.
    var activeSecondPlayerGeneration: Int {
        #if os(iOS)
        if syncClient.isConnected { return activePlayerGeneration }
        #endif
        return playerGeneration + secondPlayerGeneration
    }

    var activePlayerMode: PlayerMode {
        isLinkedToMac ? .mse : settings.playerMode
    }

    /// The schedule waiting on the linked Mac (pasted there or here); nil when not linked.
    var macPendingPlan: TrainingPlan? {
        #if os(iOS)
        return syncClient.isConnected && session == nil ? syncClient.state?.pendingPlan : nil
        #else
        return nil
        #endif
    }

    /// Puts a schedule parsed or edited on this iPhone on the linked Mac as well (nil removes it there).
    func sharePlanWithMac(_ plan: TrainingPlan?) {
        #if os(iOS)
        guard syncClient.isConnected, session == nil else { return }
        syncClient.send(.setPendingPlan(plan))
        #endif
    }

    var isRecordingNow: Bool {
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.recordingSince != nil }
        #endif
        #if DEBUG
        if Self.demoRecordingSince != nil { return true }
        #endif
        return isRecordingLocally
    }

    #if DEBUG
    /// `--demo-recording`: everything shows a recording in progress (nothing is written).
    static let demoRecordingSince: Date? = CommandLine.arguments.contains("--demo-recording")
        ? Date().addingTimeInterval(-83) : nil
    #endif

    /// When the recording on screen started: the linked Mac's on an iPhone, the DEBUG demo one in previews.
    var recordingStartedAt: Date? {
        #if DEBUG
        if let since = Self.demoRecordingSince { return since }
        #endif
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.recordingSince }
        #endif
        return localRecordingStartedAt
    }

    func recordingDuration(at now: Date) -> TimeInterval {
        #if DEBUG
        if let since = Self.demoRecordingSince { return now.timeIntervalSince(since) }
        #endif
        #if os(iOS)
        if syncClient.isConnected { return syncClient.state?.recordingSince.map { now.timeIntervalSince($0) } ?? 0 }
        #endif
        return localRecordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
    }

    func setUpSync() {
        guard !Self.isUIPreview || Self.isSyncTest else { return }
        #if os(macOS)
        syncHost.stateProvider = { [unowned self] in
            SyncState(session: session?.snapshot,
                      recordingSince: isRecordingLocally ? localRecordingStartedAt : nil,
                      cameraReady: settings.isConfigured && (settings.connectionMode == .external || embedded.status.isRunning),
                      cameraTitle: settings.cameraDisplayName,
                      streamName: settings.streamName,
                      lastRecord: lastRecord,
                      pendingPlan: session == nil ? pendingPlan : nil,
                      cameraSource: currentXiaomiSource,
                      // Either camera's quality: the iPhone (also one from before the second camera's
                      // quality) reconnects both of its players.
                      streamRevision: playerGeneration + secondPlayerGeneration,
                      secondStreamName: settings.hasSecondCamera ? settings.secondStreamName : nil,
                      secondCameraTitle: settings.hasSecondCamera ? settings.secondCameraDisplayName : nil,
                      secondCameraSource: settings.hasSecondCamera ? secondXiaomiSource : nil,
                      showsSecondCamera: isShowingSecondCamera)
        }
        syncHost.commandHandler = { [unowned self] command in applyRemote(command) }
        syncHost.accessProvider = { [unowned self] in
            SyncHost.SyncWelcomeAccess(port: EmbeddedGo2RTC.apiPort, username: EmbeddedGo2RTC.lanUsername,
                                       password: embedded.lanEnabled ? settings.lanPassword : "")
        }
        syncHost.onPairingRequest = { [unowned self] request in MacPairingPrompt.present(request, host: syncHost) }
        syncHost.onPairingCancelled = { request in MacPairingPrompt.cancel(request) }
        // A forgotten iPhone must not keep watching the camera with the password it was given.
        syncHost.onDeviceForgotten = { [unowned self] in
            embedded.setLANPassword(settings.rotateLanPassword())
            syncHost.refreshAccess()
        }
        syncHost.nameProvider = { [unowned self] in settings.linkName }
        if settings.shareWithIPhone { syncHost.start() }
        #else
        syncClient.onState = { [unowned self] state in applySyncState(state) }
        syncClient.nameProvider = { [unowned self] in settings.linkName }
        syncClient.canAutoConnect = { [unowned self] in session == nil && !isRecordingLocally }
        syncClient.startBrowsing()
        #if DEBUG
        // `--demo-share-plan`: once linked, «paste» the sample schedule here (it should appear on the Mac).
        if CommandLine.arguments.contains("--demo-share-plan") {
            Task { [weak self] in
                while self?.isLinkedToMac != true { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(4))
                self?.sharePlanWithMac(PlanParser.parse(Self.demoPlanText))
            }
        }
        #endif
        #endif
    }

    #if os(macOS)
    /// A new waiting schedule (paste, «Повторить», a linked iPhone); nil clears it.
    func setPending(_ plan: TrainingPlan?) {
        pendingPlan = plan
        pendingOriginal = plan
    }

    /// A button press from a linked iPhone.
    private func applyRemote(_ command: SyncCommand) {
        switch command {
        case .session(let command, let time):
            if command == .finish {
                finishSession()
            } else if let session {
                command.apply(to: session, at: time)
            }
        case .startSession(let plan):
            if session == nil {
                startSession(with: plan)
                setPending(nil)
            }
        case .setPendingPlan(let plan):
            guard session == nil else { return }
            // An edit of the same pasted text keeps «Как у тренера»; another text replaces both.
            if let plan, let current = pendingPlan, current.rawText == plan.rawText, !plan.rawText.isEmpty {
                pendingPlan = plan
            } else {
                setPending(plan)
            }
        case .updateSessionPlan(let plan, let quiet, let since):
            session?.updatePlan(plan, quiet: quiet ?? false, changesSince: since)
        case .abandonSession:
            abandonSession()
        case .startRecording:
            if !isRecordingLocally { startRecording() }
        case .stopRecording:
            stopRecording(deleteFile: false)
        case .showCamera(let second):
            showCamera(second: second)
        }
    }
    #endif

    #if os(iOS)
    /// Mirrors the Mac's session; keeps the log of a mirrored training when it ends.
    private func applySyncState(_ state: SyncState?) {
        let previous = lastSyncState
        lastSyncState = state
        guard let state else {
            if isMirroringSession || previous?.recordingSince != nil {
                session = nil
                keepAwake(false)
            }
            return
        }
        let hostName = syncClient.host?.name ?? linkedHostKind
        let kind = linkedHostKind
        // The camera on the Mac's screen (the one it records) is the one here: when it changes there, or on linking.
        if let shown = state.showsSecondCamera, shown != previous?.showsSecondCamera, shown != showsSecondCamera {
            panTilt.stop()
            showsSecondCamera = shown
            print("[sync] \(shown ? "second" : "first") camera on screen, as on the \(kind)")
        }
        if previous == nil {
            linkNotice = LinkNotice(title: String(localized: "Синхронизировано с «\(hostName)»"),
                                    detail: String(localized: "Тренировка, запись и лог — на \(kind), шаги общие."))
        }
        // Recording without a training on the Mac: same full-screen view here, the screen stays on.
        if state.session == nil {
            if state.recordingSince != nil, previous?.recordingSince == nil {
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            } else if state.recordingSince == nil, previous?.recordingSince != nil, previous?.session == nil {
                keepAwake(false)
                linkNotice = LinkNotice(title: String(localized: "Видео сохранено на \(kind)"),
                                        detail: String(localized: "Оно в истории на «\(hostName)»."))
            }
        }
        if let snapshot = state.session {
            if let session, isMirroringSession, session.isSameSession(as: snapshot) {
                session.restore(snapshot)
            } else if session == nil || isMirroringSession {
                // The mirror keeps the Mac's time: a press is sent with its moment there (a late command still lands
                // where it happened), and the press shown here at once matches the Mac's answer.
                let mirror = TrainingSession(snapshot: snapshot, clock: { [unowned self] in
                    syncClient.clock.hostTime(for: Date())
                })
                mirror.commandHandler = { [weak self, weak mirror] command, time in
                    self?.syncClient.send(.session(command, at: time))
                    // Nothing else ticks a mirror: a press the Mac never answers stops showing then.
                    Task { [weak mirror] in
                        try? await Task.sleep(for: .seconds(TrainingSession.predictionLifetime + 0.5))
                        mirror?.tick()
                    }
                }
                mirror.planHandler = { [weak self] plan, quiet, since in
                    self?.syncClient.send(.updateSessionPlan(plan, quiet: quiet ? true : nil, since: since))
                }
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

#if os(iOS)
/// What the tooltip under the Mac link pill says.
struct LinkNotice: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}
#endif

struct RecordingClip: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: String { url.lastPathComponent }

    func loadDuration() async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}
