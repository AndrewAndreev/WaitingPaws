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
    /// The direct iPhone ↔ Mac links next to the sync link (an experiment: `P2PLinks`).
    let p2p = P2PLinks()
    #if os(macOS)
    /// Lets an iPhone on the same network watch the camera and drive the training running on this Mac.
    let syncHost = SyncHost()
    #else
    /// Finds Macs running Waiting Paws and mirrors a training running there.
    let syncClient = SyncClient()
    /// The training without looking at the screen: vibrations when its timers run out, the Live Activity and the
    /// Dynamic Island (`TrainingGlance` follows `session` by itself; started at the end of `init`).
    let glance = TrainingGlance()
    #endif

    private(set) var session: TrainingSession?
    /// What the owner marked from behind the door on this device (a tap on «Легла», on «Залаяла»): see `exitWatch`.
    private var storedExitWatch: ExitWatch?
    private(set) var history: [TrainingRecord] = []
    /// The record of the session that has just finished (drives the summary card).
    var lastRecord: TrainingRecord?
    var errorMessage: String?
    #if os(iOS)
    /// A short note under the Mac link pill («Синхронизировано с …», «Видео сохранено на Mac»), at the top without
    /// one; fades by itself.
    var linkNotice: LinkNotice?
    @ObservationIgnored private var lastSyncState: SyncState?
    /// `SyncClient.links` at the last state: a state from a new link (also one restored after a drop) is its first.
    @ObservationIgnored private var lastSyncLink = 0
    /// The host the last state came from (the notice when its training goes from the screen names it).
    @ObservationIgnored private var lastSyncHost: SyncDevice?
    /// The host's training last mirrored here, until its log is kept here too (also when it ended while unlinked).
    @ObservationIgnored private var mirroredSession: (planID: UUID, startedAt: Date)?
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
    /// Bumped by every stop: a start still waiting for go2rtc gives up (the training was finished or abandoned meanwhile).
    @ObservationIgnored private var recordingStartGeneration = 0
    /// What follows a stop (joining the parts, remuxing, Photos), per recording file name; quitting waits for it.
    @ObservationIgnored private var recordingFinishTasks: [String: Task<Void, Never>] = [:]
    /// Recordings deleted while that work runs (`removeLeftovers`): it skips the copy to Photos.
    @ObservationIgnored private var deletedWhileFinishing: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private var awakeActivity: NSObjectProtocol?
    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var recordingCutByBackground = false
    /// Background time asked for while a stopped recording is joined and remuxed (`beginFinishingInBackground`).
    @ObservationIgnored private var finishingBackgroundTasks: Set<UIBackgroundTaskIdentifier> = []
    #endif

    init() {
        LogMirror.start(directory: Self.logsDirectory)
        reloadHistory()
        finishLeftoverRecordings()
        startEmbeddedIfNeeded()
        #if os(iOS)
        // Swiped away while still running (in the background grace): the cameras are told their sessions are over, as
        // on the Mac (MacAppDelegate). A suspended app is killed without notice; its sessions run out on the camera.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            EmbeddedGo2RTC.closeCameraSessions()
        }
        #endif
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
        // `--demo-p2p[=failed|away|checking]` with `--demo-mac-link`: the direct links' results, without any network.
        if let p2pDemo = args.first(where: { $0.hasPrefix("--demo-p2p") }) {
            p2p.demo(peer: "demo-mac", variant: p2pDemo.split(separator: "=").dropFirst().first.map(String.init) ?? "")
        }
        // `--demo-hosts`: several computers with Waiting Paws nearby (the choice on the main screen and in Settings).
        if args.contains("--demo-hosts") { syncClient.demoHosts() }
        // `--demo-host`: one Mac nearby, never joined (the «рядом» card on the first-launch welcome screen).
        if args.contains("--demo-host") { syncClient.demoHosts(single: true) }
        #endif
        #if os(macOS)
        // `--demo-p2p[=failed]` with `--demo-iphone`: the direct links' results for the demo iPhone.
        if let p2pDemo = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-p2p") }) {
            p2p.demo(peer: "demo-iphone", variant: p2pDemo.split(separator: "=").dropFirst().first.map(String.init) ?? "")
        }
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
        // Vibrations and the Live Activity of a training here or mirrored from a Mac (it looks for one by itself,
        // so the demo sessions set up below are found too).
        glance.start(model: self)
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
        // `--demo-camera-steps 10:main:camC,20:main:camB,30:second:camA,40:remove`: «Выбрать камеру…», «Вторая
        // камера…» and «Убрать вторую камеру» that many seconds after launch, through the pickers' own code — cameras
        // changed in the middle of a training or a recording. `restream:camA=rtsp://…` registers a stream again under
        // its name, as a quality change does. Not with `--ui-preview`: its picker never writes settings.
        if let index = CommandLine.arguments.firstIndex(of: "--demo-camera-steps"), index + 1 < CommandLine.arguments.count {
            let steps = CommandLine.arguments[index + 1].split(separator: ",").compactMap { step -> (at: Double, action: String, stream: String)? in
                let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let at = Double(parts[0]) else { return nil }
                return (at, parts[1], parts.count > 2 ? parts[2] : "")
            }
            Task { [weak self] in
                let start = Date()
                for step in steps {
                    try? await Task.sleep(for: .seconds(max(0, step.at - Date().timeIntervalSince(start))))
                    guard let self else { return }
                    await self.demoCameraStep(step.action, stream: step.stream)
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
                // Outside with marks (below): out for a while before them, so the marks fall inside the exit.
                let lead = phase == "away" ? Self.demoMarksLead() : nil
                if phase == "leaving" {
                    session?.startExit()
                } else {
                    session?.markBehindDoor(at: lead.map { Date().addingTimeInterval(-$0) })
                }
                if phase == "break" || phase == "finish" { session?.endExit() }
                if phase == "finish" { finishSession() }
            }
            // `--demo-mark <n>` (with `--demo-mark-ago <s>`, 5 by default): the owner tapped the exit's n-th condition
            // s seconds ago; `--demo-barking`: the dog is barking; `--demo-quiet-ago <s>`: quiet for s seconds (`ExitWatch`).
            if let session, case .away = session.phase, let exit = session.currentExit {
                let arguments = CommandLine.arguments
                func number(_ flag: String) -> Double? {
                    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                    return Double(arguments[index + 1])
                }
                var watch = ExitWatch(exitID: exit.id, attempt: session.attempt)
                let entries = session.plan.earlyEntries(of: exit)
                // In the log as well, as a tap puts them there («Отмечено: легла на 0:06 — в логе»).
                if let mark = number("--demo-mark").map({ Int($0) }), entries.indices.contains(mark - 1) {
                    let at = Date().addingTimeInterval(-(number("--demo-mark-ago") ?? 5))
                    watch.mark(entries[mark - 1], at: at)
                    session.observe(entries[mark - 1].event.lowercased(), at: at)
                }
                if arguments.contains("--demo-barking") {
                    watch.markBarking(at: Date())
                    session.observe(String(localized: "barked"), at: Date().addingTimeInterval(-3))
                }
                if let ago = number("--demo-quiet-ago") {
                    watch.markQuiet(at: Date().addingTimeInterval(-ago))
                    session.observe(String(localized: "barked"), at: Date().addingTimeInterval(-ago - 9))
                    session.observe(String(localized: "went quiet"), at: Date().addingTimeInterval(-ago))
                }
                if !watch.isEmpty { storedExitWatch = watch }
            }
            // `--demo-false-start`: «Фальстарт» just pressed — outside (`--demo-phase away`) or in a break before the
            // next exit (`--demo-phase break`); its «Отменить фальстарт» stays through the break that follows.
            if CommandLine.arguments.contains("--demo-false-start"), session?.phase.canFalseStart == true {
                falseStart()
            }
        }
        #endif
    }

    #if DEBUG
    private final class DemoClock: @unchecked Sendable { var offset: TimeInterval = 0 }

    /// How long before now a demo exit with marks (`--demo-mark-ago`, `--demo-barking`, `--demo-quiet-ago`) went
    /// outside: a few seconds before the earliest of them. nil without marks (the exit starts now).
    private static func demoMarksLead() -> TimeInterval? {
        let arguments = CommandLine.arguments
        func number(_ flag: String) -> Double? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return Double(arguments[index + 1])
        }
        var earliest: [TimeInterval] = []
        if arguments.contains("--demo-mark") { earliest.append(number("--demo-mark-ago") ?? 5) }
        if arguments.contains("--demo-barking") { earliest.append(3) }
        if let ago = number("--demo-quiet-ago") { earliest.append(ago + 9) }
        return earliest.max().map { $0 + 6 }
    }

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
        // `--demo-marks`: the owner's marks from behind the door on the replayed exits, in the record like real ones.
        let marks = args.contains("--demo-marks")
        for index in 0..<done {
            let away = plan.exits[index].duration + linger
            session.markBehindDoor()
            var at: TimeInterval = 0
            for (text, moment) in marks ? demoMarks(plan, exit: plan.exits[index], away: away) : [] {
                clock.offset += moment - at; at = moment
                session.observe(text)
            }
            clock.offset += away - at
            session.endExit(); clock.offset += plan.breakAfter(exitAt: index)
        }
        clock.offset = 0
        return session
    }

    /// What an owner would have tapped on a replayed exit, and when (from behind the door): the exit's condition
    /// with the shortest wait, as long before the return as it says («легла» 0:20 before), or on a long exit without
    /// one the bark and the quiet the rule waits for — so each return follows from its marks.
    private static func demoMarks(_ plan: TrainingPlan, exit: PlannedExit, away: TimeInterval) -> [(String, TimeInterval)] {
        let timed = plan.earlyEntries(of: exit).compactMap { entry in entry.delay.map { (entry, $0) } }.filter { $0.1 > 0 }
        if let (entry, delay) = timed.min(by: { $0.1 < $1.1 }), away - delay >= 5 {
            return [(entry.event.lowercased(), away - delay)]
        }
        if away >= 90, let quiet = plan.doNotEnterRule?.quietTime, away - quiet >= 20 {
            return [(String(localized: "barked"), away - quiet - 9), (String(localized: "went quiet"), away - quiet)]
        }
        return []
    }

    /// The demo schedule; `-demoPlanText <text>` puts another one there (UI checks of a given trainer's text).
    static var demoPlanText: String {
        if let text = UserDefaults.standard.string(forKey: "demoPlanText"), !text.isEmpty { return text }
        return CoreLanguage.current == .ru ? """
        🐹 Тренировка на понедельник - Аня/Марк - 05.10.2026
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
        Task {
            await embedded.start(lanPassword: lanPassword)
            // An iPhone linked before the API was open to the LAN (back from «Свой сервер») got no password.
            syncHost.refreshAccess()
        }
        #else
        Task { await embedded.start(lanPassword: nil) }
        #endif
    }

    /// The connection mode changed in Settings or the setup.
    func connectionModeChanged() {
        startEmbeddedIfNeeded()
        #if os(macOS)
        // A linked iPhone gets the camera only from the built-in go2rtc (`setUpSync`), which can't be stopped in-process
        // and stays open to the LAN: with «Свой сервер» a new password shuts out an iPhone given the old one.
        guard settings.connectionMode == .external, !Self.isUIPreview else { return }
        if embedded.lanEnabled { embedded.setLANPassword(settings.rotateLanPassword()) }
        syncHost.refreshAccess()
        #endif
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
        startRecordsToo ? String(localized: "Start Training & Recording") : String(localized: "Start Training")
    }

    /// «Завершить тренировку и запись» while a recording runs: finishing stops it.
    var finishTitle: String {
        isRecordingNow ? String(localized: "Finish Training & Recording") : String(localized: "Finish Training")
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
        // A late «Отменить без сохранения» (the training already ended, e.g. on the iPhone) must not delete a recording
        // started since.
        guard session != nil else { return }
        stopRecording(deleteFile: true)
        session = nil
        lastRecord = nil
        tickTask?.cancel()
        keepAwake(false)
    }

    // MARK: - What the owner sees from behind the door

    /// The marks of the exit under way (`ExitWatch`): nil outside an exit, and forgotten by itself when the exit ends,
    /// a false start repeats it or the next one begins. They stay on this device: the app does not see the dog, it
    /// times what the owner saw, and the owner is the one holding this phone.
    var exitWatch: ExitWatch? {
        guard let watch = storedExitWatch, let session, case .away = session.phase,
              session.currentExit?.id == watch.exitID, session.attempt == watch.attempt else { return nil }
        return watch
    }

    /// A tap on a condition («Легла»): seen now, its countdown starts (again).
    func markCondition(_ entry: EarlyEntry) {
        updateExitWatch { $0.mark(entry, at: Date()) }
        // For the trainer: what was seen and when, on this exit's line of the log.
        session?.observe(entry.event.lowercased())
    }

    /// A tap on the rule against coming in: «Лает» (wait, nothing counts) and «Замолчала» (the quiet counts from now)
    /// in turn — what the owner hears, in the order it happens.
    func tapQuietRule() {
        var barking = false
        updateExitWatch { watch in
            if watch.barking { watch.markQuiet(at: Date()) } else { watch.markBarking(at: Date()) }
            barking = watch.barking
        }
        session?.observe(barking ? String(localized: "barked") : String(localized: "went quiet"))
    }

    /// «Фальстарт» just pressed on this device: the training before it, the exit it was about and the break it led
    /// to, for «Отменить фальстарт» all through that break. Not on a mirror (the Mac owns that training).
    struct FalseStartUndo {
        let snapshot: TrainingSession.Snapshot
        let exitNumber: Int
        /// When it was pressed: an undo later than `backOutsideFor` ends the exit there instead of going back out.
        let pressedAt: Date
        /// The break the press started (`afterExitIndex`, `since`): the undo lasts while it does.
        let breakAfter: Int
        let breakSince: Date
        /// Pressed in a break (the dog went to the door before «Вышли»): that break started over, «Перерыв начат
        /// заново»; outside, the exit ended and this break is the one before its repeat.
        var fromBreak = false
    }
    private var storedFalseStartUndo: FalseStartUndo?

    /// The way back from the last «Фальстарт»: until the next exit starts (the break it led to is over), not a few
    /// seconds — in the break the owner is busy with the dog, not with the phone.
    var falseStartUndo: FalseStartUndo? {
        guard let undo = storedFalseStartUndo, let session, session.isSameSession(as: undo.snapshot),
              case .breakTime(let after, let since, _, _) = session.phase,
              after == undo.breakAfter, since == undo.breakSince else { return nil }
        return undo
    }

    /// An undo this soon after the press puts the owner back outside, the exit still running (a press by mistake
    /// behind the door); later they are plainly inside, and the exit ends normally at the press.
    static let falseStartBackOutsideFor: TimeInterval = 10

    /// «Фальстарт» of the exit the session is at: outside, the one under way (back inside early); in a break (or
    /// before the first exit), the next one — the dog went to the door before «Вышли», the break starts over. Either
    /// way that exit repeats after a break.
    func falseStart() {
        guard let session else { return }
        let before = session.snapshot
        let number = session.currentExit?.number
        let inBreak: Bool = if case .breakTime = session.phase { true } else { false }
        session.resetExit()
        guard !isMirroringSession, let number, case .breakTime(let after, let since, _, _) = session.phase else {
            storedFalseStartUndo = nil
            return
        }
        storedFalseStartUndo = FalseStartUndo(snapshot: before, exitNumber: number, pressedAt: Date(),
                                              breakAfter: after, breakSince: since, fromBreak: inBreak)
    }

    /// «Отменить фальстарт»: as if it was never pressed. In a break that was that break going on; outside, right
    /// after the press, the exit still running — and later, the exit ended normally at the press (the owner came in
    /// then), its break counting from there.
    func undoFalseStart() {
        guard let undo = falseStartUndo, let session else { return }
        session.revert(to: undo.snapshot)
        if session.phase.isOutside, Date().timeIntervalSince(undo.pressedAt) > Self.falseStartBackOutsideFor {
            session.endExit(at: undo.pressedAt)
        }
        storedFalseStartUndo = nil
    }

    /// ✕ next to what the big number says: every mark of this exit taken back, the plan's countdown again.
    func clearMarks() {
        updateExitWatch { $0.clear() }
    }

    private func updateExitWatch(_ change: (inout ExitWatch) -> Void) {
        guard let session, case .away = session.phase, let exit = session.currentExit else { return }
        var watch = exitWatch ?? ExitWatch(exitID: exit.id, attempt: session.attempt)
        change(&watch)
        storedExitWatch = watch.isEmpty ? nil : watch
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
            errorMessage = String(localized: "Couldn’t save the log: \(error.localizedDescription)")
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
        let generation = recordingStartGeneration
        Task { await startRecordingWhenReady(generation: generation) }
    }

    private func startRecordingWhenReady(generation: Int) async {
        await waitForServer()
        // Stopped while go2rtc was starting (the training finished or was abandoned): this start is no longer wanted.
        guard generation == recordingStartGeneration else {
            print("[rec] start dropped: stopped while go2rtc was starting")
            return
        }
        guard let client, !settings.streamName.isEmpty else {
            errorMessage = String(localized: "No camera is set up")
            return
        }
        guard !isRecordingLocally else { return }
        let plan = session?.plan ?? TrainingPlan(title: String(localized: "Record"))
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
            errorMessage = String(localized: "Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording(deleteFile: Bool) {
        recordingStartGeneration += 1
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
            let name = url.lastPathComponent
            #if os(iOS)
            // The app may be on its way out (the background grace ran out, or it was left right after «Стоп»): without
            // time asked for, the join runs while iOS suspends it.
            let background = beginFinishingInBackground()
            #endif
            recordingFinishTasks[name] = Task {
                if needsJoin { await joinRecording(url, segments: filled, startedAt: startedAt) }
                if deletedWhileFinishing.contains(name) {
                    print("[rec] \(name) was deleted meanwhile")
                } else if settings.saveToPhotos {
                    await copyToPhotos(url)
                } else {
                    await finalizeInPlace(url)
                }
                recordingFinishTasks[name] = nil
                #if os(iOS)
                endFinishingInBackground(background)
                #endif
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

    /// `stream` was registered again under its name (another quality, another address): go2rtc made a new stream, and
    /// the old one, with its own connection to the camera, lives as long as the recorder reads it. The recording would
    /// go on from it — in the old quality, and a camera that allows one connection would keep the new stream, and the
    /// picture on screen, out until the recording ends. So the part ends here and the next one reads the new stream: a
    /// camera reconnect's pause, joined like the parts of any other break.
    func recordedStreamReplaced(_ stream: String) {
        guard isRecordingLocally else { return }
        if let incomingPart, incomingPart.stream == stream {
            // Still waiting for its first keyframe: it starts again from the new stream.
            dropIncomingPart()
            followShownCameraInRecording()
            return
        }
        // Waiting for the camera to come back (`recordingResuming`): the next part reads the new stream anyway.
        guard recordingStream == stream, recorder.isRecording else { return }
        recorder.stop()
        noteSegmentEnded()
        recordingResuming = true
        print("[rec] \(stream) was registered again: the next part reads the new stream")
        startNextRecordingPart()
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
        videoPreparations[name] = VideoPreparation()
        defer {
            finalizingFileNames.remove(name)
            videoPreparations[name] = nil
        }
        do {
            let used = try await RecordingFinalizer.join(segments, startedAt: startedAt, into: url,
                                                         progress: preparationProgress(name))
            print("[rec] joined \(used) parts into \(name)")
        } catch {
            print("[rec] joining \(name) failed: \(error.localizedDescription)")
        }
    }

    /// Recordings being remuxed right now (file names); sharing waits for them.
    private(set) var finalizingFileNames: Set<String> = []
    private var finalizeTasks: [String: Task<Void, Never>] = [:]

    /// How far a recording being prepared right now is (`RecordingFinalizer`'s progress), for the history's ring and
    /// «Готовим видео · 42 % · ещё ≈ 6 мин». A usual recording takes a second or two; a night's one, minutes (14.5 h:
    /// about 4 on an M-series Mac).
    struct VideoPreparation: Equatable {
        var fraction = 0.0
        let startedAt = Date()
        /// Left raw by an earlier run (closed, or stuck, before it was prepared), finished now in the background.
        var leftover = false
        /// Seconds left, once the pace is clear (5 s and 3 % in): linear from the pace so far.
        var remaining: TimeInterval?
    }

    /// By file name, while its finalize or join runs.
    private(set) var videoPreparations: [String: VideoPreparation] = [:]
    /// Recordings still in go2rtc's raw form that nothing is preparing right now: waiting their turn after a launch
    /// (`finishLeftoverRecordings`), or their finalize failed. The history shows them without opening them (see
    /// `RecordingDurations`); opening one in the history prepares it at once.
    private(set) var unfinishedFileNames: Set<String> = []
    /// Why preparing a recording failed, by file name, until it is tried again.
    private(set) var preparationErrors: [String: String] = [:]
    /// ⌘Q is finishing what it waits for (`finishBeforeQuit`): no more leftover recordings are started.
    private var isQuitting = false

    private func preparationProgress(_ name: String) -> RecordingFinalizer.ProgressHandler {
        { [weak self] fraction in
            Task { @MainActor in self?.notePreparation(name, at: fraction) }
        }
    }

    private func notePreparation(_ name: String, at fraction: Double) {
        guard var preparation = videoPreparations[name], fraction > preparation.fraction else { return }
        preparation.fraction = fraction
        let elapsed = Date().timeIntervalSince(preparation.startedAt)
        preparation.remaining = fraction >= 0.03 && elapsed >= 5 ? elapsed / fraction * (1 - fraction) : nil
        videoPreparations[name] = preparation
    }

    /// Recordings an earlier run did not get to prepare stay go2rtc's raw stream, which every player and the history
    /// open slowly: the app was closed meanwhile (⌘Q waits 30 s for it), or the finalize hung — the night's recording
    /// of 29 Oct did, on its sound past 12 h 25 min (see `RecordingFinalizer.SoundReader`). A few seconds after launch
    /// they are prepared one at a time, newest first. Temporary files an interrupted finalize left are removed first.
    private func finishLeftoverRecordings() {
        #if DEBUG
        // A UI preview's history is shared by every Debug copy (other sessions' screenshots): its raw files are left
        // alone unless asked (`--finish-unfinished`, with a copy signed into a container of its own).
        if Self.isUIPreview, !CommandLine.arguments.contains("--finish-unfinished") { return }
        #endif
        Task { [weak self] in
            // Only the app's own temporary directory: an unsandboxed Debug copy shares the user's.
            #if os(macOS)
            if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
                RecordingFinalizer.removeAbandonedTemporaryFiles()
            }
            #else
            RecordingFinalizer.removeAbandonedTemporaryFiles()
            #endif
            // The camera and the windows first.
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            let names = unfinishedFileNames
            guard !names.isEmpty else { return }
            let files = names.map { self.store.recordingsDirectory.appendingPathComponent($0) }
                .sorted { (Self.creationDate($0) ?? .distantPast) > (Self.creationDate($1) ?? .distantPast) }
            print("[rec] \(files.count) recording(s) left unprepared by an earlier run: preparing them now")
            for url in files where unfinishedFileNames.contains(url.lastPathComponent) {
                // The quit doesn't wait for these (`hasFinalizeToWaitFor`): none is started once it is under way.
                if isQuitting { break }
                #if os(iOS)
                let background = beginFinishingInBackground()
                #endif
                await finalizeInPlace(url)
                #if os(iOS)
                endFinishingInBackground(background)
                #endif
            }
        }
    }

    private static func creationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// Which recordings are still raw (a few header bytes each), leaving out the one being written and those being
    /// prepared.
    private func refreshUnfinished() {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        let active = currentRecordingURL?.lastPathComponent
        unfinishedFileNames = Set(files.filter { url in
            let name = url.lastPathComponent
            return url.pathExtension == "mp4" && name != active && !finalizingFileNames.contains(name)
                && recordingFinishTasks[name] == nil && RecordingFinalizer.isUnfinished(url)
        }.map(\.lastPathComponent))
    }

    /// Turns a finished recording into a regular MP4 with an audio track (see `RecordingFinalizer`).
    /// Cheap for files that are already done; concurrent calls for one file share the work. A recording just stopped
    /// is first joined and finalized by its own task (`recordingFinishTasks`): opening it waits for that instead of
    /// remuxing its first part over the joined video.
    func finalizeRecording(_ url: URL) async {
        if let finishing = recordingFinishTasks[url.lastPathComponent] { await finishing.value }
        await finalizeInPlace(url)
    }

    private func finalizeInPlace(_ url: URL) async {
        let name = url.lastPathComponent
        if let running = finalizeTasks[name] {
            await running.value
            return
        }
        // Already a regular MP4 (the app writes AAC sound into every one it prepares): nothing to open.
        guard RecordingFinalizer.isUnfinished(url) else {
            unfinishedFileNames.remove(name)
            return
        }
        finalizingFileNames.insert(name)
        videoPreparations[name] = VideoPreparation(leftover: unfinishedFileNames.contains(name))
        unfinishedFileNames.remove(name)
        preparationErrors[name] = nil
        let task = Task {
            let started = Date()
            do {
                if try await RecordingFinalizer.finalize(url, progress: preparationProgress(name)) {
                    print("[rec] finalized \(name) in \(Int(Date().timeIntervalSince(started))) s")
                }
            } catch {
                print("[rec] finalize failed \(name): \(error.localizedDescription)")
                preparationErrors[name] = error.localizedDescription
            }
            // Still raw (it failed): shown as unfinished again; the history hands it to the player as it is.
            if RecordingFinalizer.isUnfinished(url) { unfinishedFileNames.insert(name) }
            finalizingFileNames.remove(name)
            videoPreparations[name] = nil
            finalizeTasks[name] = nil
        }
        finalizeTasks[name] = task
        await task.value
    }

    /// Copies a recording into the Photos library in the background; errors surface in the alert.
    func saveToPhotos(_ url: URL) {
        photosSaveErrors[url.lastPathComponent] = nil
        Task {
            if let finishing = recordingFinishTasks[url.lastPathComponent] { await finishing.value }
            await copyToPhotos(url)
        }
    }

    /// `saveToPhotos` for a caller that waits for it (the end of a recording: quitting waits for that).
    private func copyToPhotos(_ url: URL) async {
        let name = url.lastPathComponent
        photosSaveErrors[name] = nil
        await finalizeInPlace(url)
        do {
            try await PhotoLibrarySaver.save(videoAt: url)
            photosSavedFileNames.insert(name)
            print("[photos] saved \(name)")
        } catch {
            photosSaveErrors[name] = error.localizedDescription
            print("[photos] failed \(name): \(error.localizedDescription)")
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
            case .auto: return String(localized: "Auto")
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
    /// One `--demo-camera-steps` step: `main` / `second` choose that go2rtc stream as the pickers do (the second one then
    /// comes on screen, as after «Вторая камера…»), `remove` takes the second camera away.
    private func demoCameraStep(_ action: String, stream: String) async {
        let choice = SetupCameraCatalog.Choice.stream(Go2RTCStream(name: stream, sources: []))
        do {
            switch action {
            case "main":
                try await SetupCameraCatalog().choose(choice, model: self)
            case "second":
                try await SetupCameraCatalog().choose(choice, model: self, target: .second)
                showCamera(second: true)
            case "remove":
                removeSecondCamera()
            case "restream":
                // `camA=rtsp://…`: what `setXiaomiQuality` does with its new `subtype`, for any source.
                let pair = stream.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let client else { return }
                try await client.addStream(name: pair[0], source: pair[1])
                if pair[0] == settings.streamName { videoSize = nil; playerGeneration += 1 }
                if pair[0] == settings.secondStreamName { secondVideoSize = nil; secondPlayerGeneration += 1 }
                recordedStreamReplaced(pair[0])
            default:
                print("[demo] unknown camera step «\(action)»")
                return
            }
            print("[demo] camera step \(action) \(stream): main \(settings.streamName), second \(settings.secondStreamName), on screen \(shownStreamName)")
        } catch {
            print("[demo] camera step \(action) \(stream) failed: \(error.localizedDescription)")
        }
    }

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
            errorMessage = String(localized: "Couldn’t change quality: go2rtc didn’t return the camera address")
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
            // «Recordings use this quality too»: also a recording going on now, from its next part.
            recordedStreamReplaced(stream)
        } catch {
            errorMessage = String(localized: "Couldn’t change quality: \(error.localizedDescription)")
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
            errorMessage = String(localized: "Couldn’t sign out of Xiaomi: \(error.localizedDescription)")
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
        refreshUnfinished()
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
        let video = includingRecording ? store.recordingURL(for: record) : nil
        store.delete(record, includingRecording: includingRecording)
        if let video { removeLeftovers(of: video) }
        history.removeAll { $0.id == record.id }
        if lastRecord?.id == record.id { lastRecord = nil }
        // A video kept without its log shows up as a standalone recording.
        if !includingRecording { reloadClips() }
    }

    func delete(_ clip: RecordingClip) {
        try? FileManager.default.removeItem(at: clip.url)
        removeLeftovers(of: clip.url)
        clips.removeAll { $0.id == clip.id }
        if lastClip?.id == clip.id { lastClip = nil }
    }

    /// What else goes with a deleted recording: its parts in `Recordings/.parts` (one left out of a join, or a join cut
    /// short), and — while it is still being joined or remuxed — the file that work puts back when it ends: it goes again
    /// then, without the copy to Photos.
    private func removeLeftovers(of url: URL) {
        let name = url.lastPathComponent
        unfinishedFileNames.remove(name)
        preparationErrors[name] = nil
        guard let work = recordingFinishTasks[name] ?? finalizeTasks[name] else { return removeParts(of: url) }
        deletedWhileFinishing.insert(name)
        Task {
            await work.value
            try? FileManager.default.removeItem(at: url)
            removeParts(of: url)
            deletedWhileFinishing.remove(name)
        }
    }

    private func removeParts(of url: URL) {
        let directory = store.recordingsDirectory.appendingPathComponent(".parts", isDirectory: true)
        let prefix = url.deletingPathExtension().lastPathComponent + "-part"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp4" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix(prefix), Int(stem.dropFirst(prefix.count)) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every saved session with its log and video, and every standalone recording (nothing is touched in Photos).
    func deleteAll() {
        for record in history {
            let video = store.recordingURL(for: record)
            store.delete(record, includingRecording: true)
            if let video { removeLeftovers(of: video) }
        }
        for clip in clips {
            try? FileManager.default.removeItem(at: clip.url)
            removeLeftovers(of: clip.url)
        }
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
        p2p.didEnterBackground()
        let worthKeeping = session != nil || isRecordingLocally || isLinkedToMac || settings.isConfigured || p2p.hasAliveLinks
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

    /// Background time to join and remux a stopped recording (`stopRecording`). It gets what is left of the app's
    /// time: when that runs out every such request ends (iOS ends an app holding one); a join cut short keeps its parts.
    private func beginFinishingInBackground() -> UIBackgroundTaskIdentifier {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Finish the recording") { [weak self] in
            MainActor.assumeIsolated { self?.endFinishingInBackground(nil) }
        }
        if id != .invalid { finishingBackgroundTasks.insert(id) }
        return id
    }

    /// Ends one request for finishing time, or all of them (`nil`: the time ran out).
    private func endFinishingInBackground(_ id: UIBackgroundTaskIdentifier?) {
        for task in id.map({ [$0] }) ?? Array(finishingBackgroundTasks) where finishingBackgroundTasks.remove(task) != nil {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Back in the foreground: reopen go2rtc's API if iOS closed it, and resume a recording cut by the suspension.
    func didBecomeActive() async {
        endBackgroundTask()
        p2p.didBecomeActive(peer: p2p.lastPeer) { [weak self] in
            guard let self, case .connected(let host) = syncClient.status else { return false }
            return host.id == p2p.lastPeer
        }
        if await embedded.recoverIfNeeded() { playerGeneration += 1 }
        syncClient.autoConnectIfPossible()
        guard recordingCutByBackground else { return }
        recordingCutByBackground = false
        startRecording()
        linkNotice = LinkNotice(title: String(localized: "Recording resumed"),
                                detail: String(localized: "No video was recorded while the app was in the background. The start of the recording is in History."),
                                systemImage: "record.circle")
    }
    #endif

    #if os(macOS)
    /// ⌘Q (or logging out) finds something to finish first: a training, a recording, or a video still being joined.
    var hasWorkBeforeQuit: Bool {
        session != nil || isRecordingLocally || !recordingFinishTasks.isEmpty || hasFinalizeToWaitFor
    }

    /// A finalize the quit waits for. Not one of a recording an earlier run left raw (prepared in the background after a
    /// launch, or opened in the history): a night's takes minutes, and one cut short stays raw and is prepared again at
    /// the next launch, so waiting for it would only hold the quit up.
    private var hasFinalizeToWaitFor: Bool {
        finalizeTasks.keys.contains { videoPreparations[$0]?.leftover != true }
    }

    /// Quitting mid-training keeps what was done, as closing the window does on Windows: the training is finished and
    /// saved, the recording stopped, and the quit waits (up to `limit`) for the video to be joined and remuxed. A video
    /// cut short by the limit stays as written (its first part; the rest in `.parts`).
    func finishBeforeQuit(limit: Duration) async {
        print("[app] quitting: finishing the training and the recording first")
        isQuitting = true
        if session != nil { finishSession() } else { stopRecording(deleteFile: false) }
        let deadline = ContinuousClock.now + limit
        while !recordingFinishTasks.isEmpty || hasFinalizeToWaitFor, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !recordingFinishTasks.isEmpty || hasFinalizeToWaitFor { print("[app] quitting before the video was finished") }
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

    /// Whether this iPhone shows a Mac's camera and training right now (also while the link is being restored: see
    /// `isReconnecting`).
    var isLinkedToMac: Bool {
        #if os(iOS)
        return syncClient.isLinked
        #else
        return false
        #endif
    }

    /// The link dropped mid-training and is being restored: the training stays on screen, but presses can't reach
    /// the Mac, so its buttons are off (`SyncClient.reconnecting`).
    var isReconnecting: Bool {
        #if os(iOS)
        return syncClient.reconnecting != nil
        #else
        return false
        #endif
    }

    /// What the linked host is called in the texts: "Mac", "ПК" («Запись на ПК»).
    var linkedHostKind: String {
        #if os(iOS)
        return (syncClient.host ?? syncClient.reconnecting)?.kindTitle ?? "Mac"
        #else
        return "Mac"
        #endif
    }

    /// go2rtc the camera view and the recorder talk to: the linked Mac's, or our own. Here and below, the Mac's last
    /// state also while the link is being restored (`isReconnecting`); commands go only while connected.
    var activeServer: Go2RTCServer? {
        #if os(iOS)
        if syncClient.isLinked { return syncClient.server }
        #endif
        return settings.server
    }

    var activeStreamName: String {
        #if os(iOS)
        if syncClient.isLinked { return syncClient.state?.streamName ?? "" }
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
        if syncClient.isLinked { return syncClient.state?.secondStreamName ?? "" }
        #endif
        return settings.hasSecondCamera ? settings.secondStreamName : ""
    }

    var activeSecondCameraName: String {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-second-camera") { return String(localized: "Room") }
        #endif
        #if os(iOS)
        if syncClient.isLinked { return syncClient.state?.secondCameraTitle ?? String(localized: "Camera 2") }
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
            // By its name too: a Mac that knows it shows this camera even if the two changed places there meanwhile.
            let stream = second ? activeSecondStreamName : activeStreamName
            syncClient.send(.showCamera(second: second, stream: stream.isEmpty ? nil : stream))
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

    /// The second camera was chosen as the camera (the main one), e.g. «Выбрать камеру…» to bring back a stalled one:
    /// the old main one takes its place, so choosing one camera never drops the other. The chosen one is on screen
    /// (and recorded), here and on a linked iPhone. Called with the new main camera already in the settings.
    func secondCameraBecameMain(previousStream: String, previousTitle: String) {
        guard !previousStream.isEmpty, previousStream != settings.streamName else {
            removeSecondCamera()
            return
        }
        panTilt.stop()
        settings.secondStreamName = previousStream
        settings.secondCameraTitle = previousTitle
        showsSecondCamera = false
        secondVideoSize = nil
        print("[setup] cameras swapped: \(settings.streamName) is the main camera, \(previousStream) the second one")
        followShownCameraInRecording()
    }

    /// The linked computer has a camera but gives this iPhone no video: it works with its own go2rtc server (its state
    /// has the camera's name and no stream then).
    var isLinkedCameraNotShared: Bool {
        #if os(iOS)
        if syncClient.isLinked, let state = syncClient.state {
            return !state.cameraReady && state.streamName.isEmpty && !state.cameraTitle.isEmpty
        }
        #endif
        return false
    }

    var activeCameraName: String {
        #if os(iOS)
        if syncClient.isLinked { return syncClient.state?.cameraTitle ?? String(localized: "\(linkedHostKind) Camera") }
        #endif
        return settings.cameraDisplayName
    }

    /// MSE works through the Mac's API port alone (WebRTC would need its UDP ports open on the LAN).
    /// Bumped whenever the players must reconnect: ours, or the linked Mac's (its quality changed).
    var activePlayerGeneration: Int {
        #if os(iOS)
        if syncClient.isLinked { return syncClient.state?.streamRevision ?? 0 }
        #endif
        return playerGeneration
    }

    /// For the second camera's player: also bumped when only its quality changed. A linked Mac's `streamRevision`
    /// already counts that change.
    var activeSecondPlayerGeneration: Int {
        #if os(iOS)
        if syncClient.isLinked { return activePlayerGeneration }
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
        if syncClient.isLinked { return syncClient.state?.recordingSince != nil }
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
        if syncClient.isLinked { return syncClient.state?.recordingSince }
        #endif
        return localRecordingStartedAt
    }

    func recordingDuration(at now: Date) -> TimeInterval {
        #if DEBUG
        if let since = Self.demoRecordingSince { return now.timeIntervalSince(since) }
        #endif
        #if os(iOS)
        if syncClient.isLinked { return syncClient.state?.recordingSince.map { now.timeIntervalSince($0) } ?? 0 }
        #endif
        return localRecordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
    }

    func setUpSync() {
        guard !Self.isUIPreview || Self.isSyncTest else { return }
        #if os(macOS)
        syncHost.stateProvider = { [unowned self] in
            // The iPhone is given this Mac's built-in go2rtc only: with «Свой сервер» no camera (the built-in one,
            // still running from before, would open a second session to a camera that allows one). The camera's
            // name stays: the training and the recording still go from the iPhone.
            let shares = settings.connectionMode == .embedded
            let second = shares && settings.hasSecondCamera
            return SyncState(session: session?.snapshot,
                             recordingSince: isRecordingLocally ? localRecordingStartedAt : nil,
                             cameraReady: shares && settings.isConfigured && embedded.status.isRunning,
                             cameraTitle: settings.cameraDisplayName,
                             streamName: shares ? settings.streamName : "",
                             lastRecord: lastRecord,
                             pendingPlan: session == nil ? pendingPlan : nil,
                             cameraSource: shares ? currentXiaomiSource : nil,
                             // Either camera's quality: the iPhone (also one from before the second camera's
                             // quality) reconnects both of its players.
                             streamRevision: playerGeneration + secondPlayerGeneration,
                             secondStreamName: second ? settings.secondStreamName : nil,
                             secondCameraTitle: second ? settings.secondCameraDisplayName : nil,
                             secondCameraSource: second ? secondXiaomiSource : nil,
                             showsSecondCamera: isShowingSecondCamera)
        }
        syncHost.commandHandler = { [unowned self] command in applyRemote(command) }
        syncHost.accessProvider = { [unowned self] in
            SyncHost.SyncWelcomeAccess(port: EmbeddedGo2RTC.apiPort, username: EmbeddedGo2RTC.lanUsername,
                                       password: settings.connectionMode == .embedded && embedded.lanEnabled ? settings.lanPassword : "")
        }
        syncHost.onPairingRequest = { [unowned self] request in MacPairingPrompt.present(request, host: syncHost) }
        syncHost.onPairingCancelled = { request in MacPairingPrompt.cancel(request) }
        // A forgotten iPhone must not keep watching the camera with the password it was given.
        syncHost.onDeviceForgotten = { [unowned self] in
            embedded.setLANPassword(settings.rotateLanPassword())
            syncHost.refreshAccess()
        }
        syncHost.nameProvider = { [unowned self] in settings.linkName }
        // The direct links answer the iPhones' offers; their signals ride the sync link.
        syncHost.onP2PSignal = { [unowned self] signal, peer in p2p.handle(signal, from: peer) }
        syncHost.onForget = { [unowned self] peer in p2p.closeLinks(peer: peer) }
        p2p.sendSignal = { [unowned self] peer, signal in syncHost.sendP2P(signal, to: peer) }
        if settings.shareWithIPhone { syncHost.start() }
        #else
        syncClient.onState = { [unowned self] state in applySyncState(state) }
        syncClient.nameProvider = { [unowned self] in settings.linkName }
        // Not over a training or recording of this iPhone's own; a mirror kept while reconnecting is the host's.
        syncClient.canAutoConnect = { [unowned self] in (session == nil || isMirroringSession) && !isRecordingLocally }
        // The direct links start once a host that knows them is joined, and stay when the sync link drops (away from
        // home that is the point); «Отключить синхронизацию» and «Забыть» end them.
        syncClient.onP2PHost = { [unowned self] host in p2p.startLinks(to: host) }
        syncClient.onP2PSignal = { [unowned self] signal, host in p2p.handle(signal, from: host) }
        syncClient.onStopped = { [unowned self] host in p2p.closeLinks(peer: host) }
        p2p.sendSignal = { [unowned self] peer, signal in syncClient.sendP2P(signal, to: peer) }
        p2p.onFirstResult = { [unowned self] key, status in showP2PResult(key, status) }
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
        case .showCamera(let second, let stream):
            if let shown = SyncCommand.shownSecondCamera(second: second, stream: stream, first: settings.streamName,
                                                         secondStream: settings.hasSecondCamera ? settings.secondStreamName : nil) {
                showCamera(second: shown)
            } else {
                print("[sync] the camera the iPhone chose (\(stream ?? "?")) is no longer here")
            }
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
                // The link is gone (not restored in time, «Отключить синхронизацию», turned away): the training
                // goes on there, it is just not seen here.
                if isMirroringSession, let host = lastSyncHost {
                    linkNotice = LinkNotice(title: String(localized: "The training continues on the \(host.kindTitle)"),
                                            detail: String(localized: "Without a connection to “\(host.name)”, it isn’t shown here."),
                                            systemImage: "wifi.slash")
                }
                session = nil
                keepAwake(false)
            }
            return
        }
        lastSyncHost = syncClient.host ?? lastSyncHost
        let hostName = syncClient.host?.name ?? linkedHostKind
        let kind = linkedHostKind
        let firstOfLink = syncClient.links != lastSyncLink
        lastSyncLink = syncClient.links
        // The camera on the Mac's screen (the one it records) is the one here: when it changes there, on linking — also
        // back after a drop, whatever was switched here meanwhile — and when the Mac's cameras changed
        // (`SyncState.shownSecondCamera`).
        if let shown = state.shownSecondCamera(after: previous, local: showsSecondCamera, firstOfLink: firstOfLink) {
            panTilt.stop()
            showsSecondCamera = shown
            print("[sync] \(shown ? "second" : "first") camera on screen, as on the \(kind)")
        }
        if previous == nil {
            linkNotice = LinkNotice(title: String(localized: "Synced with “\(hostName)”"),
                                    detail: String(localized: "Training, recording and log stay on the \(kind); the steps are shared."))
        }
        // Recording without a training on the Mac: same full-screen view here, the screen stays on.
        if state.session == nil {
            if state.recordingSince != nil, previous?.recordingSince == nil {
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            } else if state.recordingSince == nil, previous?.recordingSince != nil, previous?.session == nil {
                keepAwake(false)
                linkNotice = LinkNotice(title: String(localized: "Video saved on the \(kind)"),
                                        detail: String(localized: "It’s in History on “\(hostName)”."))
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
                    guard let self else { return }
                    guard syncClient.isConnected else {
                        // The link is being restored: the press can't reach the Mac, so it doesn't show as done
                        // either (its buttons are off meanwhile; this catches the rest).
                        Task { mirror?.tick(at: .distantFuture) }
                        return
                    }
                    syncClient.send(.session(command, at: time))
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
                mirroredSession = (snapshot.plan.id, snapshot.startedAt)
                lastRecord = nil
                lastClip = nil
                keepAwake(true)
            }
        } else if isMirroringSession {
            session = nil
            keepAwake(false)
        }
        // The Mac saved the record of the training mirrored here together with the video; keep its log here too (the
        // video stays on the Mac) — also when the training ended while the link was down. Only that training's record.
        if state.session == nil, let mirrored = mirroredSession, var record = state.lastRecord,
           record.plan.id == mirrored.planID, record.startedAt == mirrored.startedAt {
            mirroredSession = nil
            if !history.contains(where: { $0.id == record.id }) {
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
/// What the tooltip under the Mac link pill (or the banner at the top without one) says.
extension AppModel {
    /// The direct link's first result, once per link (the bubble under the «Mac» pill): whether it works, and
    /// for the cellular one whether it will work away from home.
    func showP2PResult(_ key: P2PLinks.Key, _ status: P2PLinkStatus) {
        let works: Bool
        switch status.outcome() {
        case .direct: works = true
        case .failed: works = false
        case .checking, .lost: return
        }
        // The home one only when it fails: the one that matters is the outside one.
        guard key.kind == .out || !works else { return }
        let rtt = status.rtt.map { String(localized: "\(Int($0.rounded())) ms") } ?? ""
        switch (key.kind, works) {
        case (.out, true):
            linkNotice = LinkNotice(title: String(localized: "Direct link works outside home too"),
                                    detail: String(localized: "Over cellular, without a server: \(status.pairText ?? ""), \(rtt). It will keep working once you leave, while the app is open."),
                                    systemImage: "point.3.connected.trianglepath.dotted")
        case (.out, false):
            linkNotice = LinkNotice(title: String(localized: "No direct link outside home"),
                                    detail: String(localized: "Over cellular the Mac couldn’t be reached directly: a server will be needed. Details are in Settings."),
                                    systemImage: "point.3.connected.trianglepath.dotted", isWarning: true)
        default:
            linkNotice = LinkNotice(title: String(localized: "No direct link at home"),
                                    detail: String(localized: "Syncing works as usual. Details are in Settings."),
                                    systemImage: "point.3.connected.trianglepath.dotted", isWarning: true)
        }
    }
}

struct LinkNotice: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var systemImage = "laptopcomputer.and.iphone"
    /// Drawn in the warning colour (the link is down).
    var isWarning = false
}
#endif

struct RecordingClip: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: String { url.lastPathComponent }

    func loadDuration() async -> TimeInterval? {
        await RecordingDurations.shared.duration(of: url)
    }
}
