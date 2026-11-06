#if os(iOS)
import ActivityKit
import AudioToolbox
import CoreHaptics
import Foundation
import UIKit
import WaitingPawsCore

/// The training without looking at the screen (design council, round 1, «Взгляд мимоходом»): a short vibration when
/// one of its timers runs out, and the Live Activity on the lock screen and in the Dynamic Island. Both follow the
/// readout's big number (`ReadoutContent.status`), for a training run on this iPhone and one mirrored from a linked Mac
/// alike. It looks at the training four times a second while the app runs; once iOS suspends the app, the Live Activity
/// goes on counting by itself from the dates it was given. The Live Activity's step button (round 3) is performed here
/// too, with the app woken in the background for it (`performStep`). Out of the front the vibration is a notification's
/// (round 4, `TrainingAlerts`): scheduled for the countdowns' ends when the app leaves the front and whenever the
/// training changes in the background, taken away when it is back.
///
/// When a countdown runs out while the app is suspended, nothing can update the Live Activity (a local notification
/// doesn't wake the app, and iOS draws `then` only once it marks the activity stale, minutes after `staleDate`); so
/// the extension draws both states and switches to `then` at the moment by itself (the exit's «0:00» turns into a
/// orange «+0:01…»; its `AtEnd`, round 8). The notification arrives on time and says what ran out.
///
/// Round 12 (the owner's criteria): a glance, not a remote — the phase, the number, the step; the trainer's conditions
/// are only read in the app, so nothing here counts them down or waits for the quiet.
@MainActor
final class TrainingGlance {
    private typealias Attributes = TrainingActivityAttributes

    private weak var model: AppModel?
    private var loop: Task<Void, Never>?
    /// The training looked at: its plan and start (a mirror rebuilt for the same training is the same one).
    private var training: Training?
    private var lastStatus: ReadoutContent.Status?
    private var activity: Activity<Attributes>?
    private var shown: Attributes.ContentState?
    /// The owner swiped this training's Live Activity away: it is not put back for it.
    private var dismissed: Training?
    private var lastRequestFailure: Date?
    /// The last moment a Mac's training was known to be current here (the link up): «🕓 с Mac в 22:31» once the app is
    /// about to stop hearing of it.
    private var lastLinked: Date?

    private struct Training: Equatable {
        let planID: UUID
        let startedAt: Date

        /// `TrainingActivityAttributes.training`: what a press on the step button names.
        var id: String { "\(planID.uuidString) \(startedAt.timeIntervalSinceReferenceDate)" }
    }
    /// The Live Activity's update under way: a press on its button waits for it (iOS may suspend the app right after).
    private var pendingUpdate: Task<Void, Never>?
    /// The timers' notifications while the app is not in front.
    private let alerts = TrainingAlerts()
    /// The break's end, strong enough to be noticed with the phone out of the hand.
    private let breakOverBuzz = StrongBuzz()
    private var observers: [NSObjectProtocol] = []

    nonisolated init() {}

    /// DEBUG `--ui-preview` copies start no Live Activity unless asked with `--demo-live-activity` (their screenshots
    /// share the simulator with others).
    static let showsLiveActivity: Bool = {
        #if DEBUG
        return !AppModel.isUIPreview || CommandLine.arguments.contains("--demo-live-activity")
        #else
        return true
        #endif
    }()

    /// DEBUG `--ui-preview` copies neither ask for notifications nor send them unless asked with `--demo-notifications`.
    static let sendsNotifications: Bool = {
        #if DEBUG
        return !AppModel.isUIPreview || CommandLine.arguments.contains("--demo-notifications")
        #else
        return true
        #endif
    }()

    func start(model: AppModel) {
        self.model = model
        alerts.start()
        // Leaving the front schedules the notifications at once (iOS may suspend the app within seconds); coming back
        // takes them away, and finds out whether they are still allowed.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.step(at: Date()) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.alerts.refreshAuthorization()
                    _ = self?.step(at: Date())
                }
            },
        ]
        // The step button of the Live Activity (`TrainingStepIntent`) runs here, in the app's process.
        TrainingStepIntent.handler = { [weak self] step, training in
            await self?.performStep(step, training: training)
        }
        // A training cut off with the app (quit from the app switcher, a crash) left its Live Activity counting.
        for leftover in Activity<Attributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.step(at: Date())
                try? await Task.sleep(for: .milliseconds(busy ? 250 : 1000))
            }
        }
    }

    /// One look at the training; false when there is none.
    private func step(at now: Date) -> Bool {
        guard let model, let session = model.session, !session.isFinished else {
            training = nil
            lastStatus = nil
            endActivity()
            alerts.removeAll()
            return false
        }
        let current = Training(planID: session.plan.id, startedAt: session.startedAt)
        if current != training {
            endActivity()
            training = current
            lastStatus = nil
            lastLinked = nil
        }
        if model.isMirroringSession, !Self.isReconnecting(model) { lastLinked = now }
        let content = ReadoutContent(session: session)
        let status = content.status(at: now, watch: nil)
        let inFront = UIApplication.shared.applicationState == .active
        let notifies = notify(session, model: model, inFront: inFront, now: now)
        // Out of the front the notification vibrates instead (in the background the app can't).
        if let lastStatus, model.settings.haptics, inFront || !notifies { vibrate(from: lastStatus, to: status, at: now) }
        if let lastStatus, lastStatus.kind != status.kind, !inFront { print("[glance] in the background: now \(status.kind)") }
        lastStatus = status
        if Self.showsLiveActivity {
            // The card shows the iPhone's own number (`phoneStatus`): the last break counts its own time up, as the app's
            // card does; the vibration and the notifications above keep to the plan's moments.
            show(state(content, status: content.phoneStatus(at: now), model: model, now: now), at: now)
            #if DEBUG
            if activity != nil { watchForAlert() }
            #endif
        }
        return true
    }

    // MARK: - Notifications

    /// While the app is not in front, what runs out next is scheduled as notifications; in front there are none (the
    /// app vibrates), and iOS is asked for them when a training is under way. Returns whether they are sent.
    private func notify(_ session: TrainingSession, model: AppModel, inFront: Bool, now: Date) -> Bool {
        guard Self.sendsNotifications, model.settings.notifications else {
            alerts.removeAll()
            return false
        }
        if inFront {
            alerts.askIfNeeded()
            alerts.removeAll()
        } else {
            alerts.show(TrainingAlerts.upcoming(session, now: now), vibrates: model.settings.haptics, now: now)
        }
        return alerts.isAllowed
    }

    /// A moment in the app's language, «22:31» (the extension would use the device's).
    private static func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(WaitingPawsApp.locale))
    }

    // MARK: - Vibration

    /// A timer of the training has just run out: the exit's plan or the break's. Each has its own feel. A change found
    /// on coming back to the app long after doesn't vibrate.
    private func vibrate(from previous: ReadoutContent.Status, to status: ReadoutContent.Status, at now: Date) {
        guard status.kind != previous.kind, let ranOut = previous.endsAt,
              now >= ranOut.addingTimeInterval(-1), now.timeIntervalSince(ranOut) < 3 else { return }
        switch status.kind {
        case .overdue:
            // The exit's plan time is reached: the system's "warning", two taps.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .breakOver:
            // The break's plan is over: time to go out again, and the phone is often on the table or the sofa. Three
            // soft knocks went unnoticed out of the hand (the owner, 2026-11-06): three long buzzes at full strength.
            breakOverBuzz.play()
        default:
            return
        }
        print("[glance] vibration: \(status.kind)")
    }

    // MARK: - Live Activity

    private func show(_ state: Attributes.ContentState, at now: Date) {
        // Past this date the extension draws `then` by itself.
        let content = ActivityContent(state: state, staleDate: state.then == nil ? nil : state.status.endsAt)
        if let activity {
            switch activity.activityState {
            case .dismissed:
                dismissed = training
                self.activity = nil
                return
            case .ended:
                self.activity = nil
            default:
                guard !(shown.map { $0.isClose(to: state) } ?? false) else { return }
                shown = state
                let previous = pendingUpdate
                pendingUpdate = Task {
                    await previous?.value
                    await activity.update(content)
                }
                return
            }
        }
        // iOS starts one only from the foreground; a refusal (Live Activities off for the app) is not retried at once.
        guard let training, dismissed != training, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active,
              lastRequestFailure.map({ now.timeIntervalSince($0) > 30 }) ?? true else { return }
        do {
            activity = try Activity.request(attributes: Attributes(training: training.id), content: content,
                                            pushType: nil)
            shown = state
            print("[live] Live Activity for the training started")
        } catch {
            lastRequestFailure = now
            print("[live] no Live Activity: \(error.localizedDescription)")
        }
    }

    private func endActivity() {
        shown = nil
        guard let activity else { return }
        self.activity = nil
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        print("[live] Live Activity ended")
    }

    // MARK: - The step button

    /// A press on the Live Activity's «Вернулись» / «Вышли» (`TrainingStepIntent`), with the app in the background or
    /// just launched for it. It takes the step only if the button still means it: the same training, the same step the
    /// app's own button would take now. A Mac's training gets it through the session, like the app's button (the link
    /// may need a moment to come back after the app was suspended). Returns once the Live Activity shows the result.
    private func performStep(_ kind: Attributes.Step, training id: String) async {
        let expected: ReadoutContent.Step = kind == .outside ? .outside : .backInside
        func current() -> TrainingSession? {
            guard let session = model?.session, !session.isFinished,
                  Training(planID: session.plan.id, startedAt: session.startedAt).id == id,
                  ReadoutContent(session: session).step == expected else { return nil }
            return session
        }
        defer {
            let phase = model?.session.map { Self.phaseName($0.phase) } ?? "gone"
            print("[live] step button: the training is now \(phase)")
        }
        guard let model, var session = current() else {
            print("[live] step button «\(kind)» pressed, but the training has moved on: nothing done")
            await refresh()
            return
        }
        if model.isMirroringSession {
            let deadline = Date().addingTimeInterval(8)
            while !model.syncClient.isConnected, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // The mirror may have been rebuilt meanwhile, or the Mac's training moved on.
            guard model.syncClient.isConnected, let again = current() else {
                print("[live] step button «\(kind)» pressed, but the \(model.linkedHostKind) can't be reached: "
                      + "nothing done")
                await refresh()
                return
            }
            session = again
        }
        let before = model.syncClient.state?.session?.phase
        switch kind {
        case .outside: session.markBehindDoor()
        case .backInside: session.endExit()
        }
        let sent = model.isMirroringSession ? ", sent to the \(model.linkedHostKind)" : ""
        print("[live] step button «\(kind)» pressed: done\(sent)")
        await refresh()
        guard model.isMirroringSession else { return }
        // iOS may suspend the app as soon as this returns: wait a moment for the Mac's answer, then show it.
        let deadline = Date().addingTimeInterval(3)
        while model.syncClient.state?.session?.phase == before, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if model.syncClient.state?.session?.phase == before {
            print("[live] step button: no answer from the \(model.linkedHostKind) yet")
        }
        await refresh()
    }

    /// Shows the training as it is now and waits until the Live Activity and the notifications have it.
    private func refresh() async {
        _ = step(at: Date())
        await pendingUpdate?.value
        await alerts.settle()
    }

    private static func phaseName(_ phase: SessionPhase) -> String {
        switch phase {
        case .ready: return "ready"
        case .leaving: return "leaving"
        case .away(let index, _, _): return "away (exit \(index + 1))"
        case .breakTime(let after, _, _, _): return "break (after exit \(after + 1))"
        case .finished: return "finished"
        }
    }

    #if DEBUG
    /// `--demo-island-alert`: 3 s after the app goes to the background its Live Activity is sent again with an alert,
    /// which opens the expanded Dynamic Island for a few seconds (screenshots of it in the simulator).
    private var alertTask: Task<Void, Never>?

    private func watchForAlert() {
        guard CommandLine.arguments.contains("--demo-island-alert"), alertTask == nil else { return }
        alertTask = Task { [weak self] in
            while UIApplication.shared.applicationState != .background { try? await Task.sleep(for: .milliseconds(300)) }
            try? await Task.sleep(for: .seconds(3))
            guard let self, let activity = self.activity, let state = self.shown else { return }
            let title = state.title, value = state.status.value
            await activity.update(ActivityContent(state: state, staleDate: state.then == nil ? nil : state.status.endsAt),
                                  alertConfiguration: AlertConfiguration(title: "\(title)", body: "\(value)", sound: .default))
            print("[live] alert sent (expanded Dynamic Island)")
        }
    }
    #endif

    // MARK: - What it shows

    private func state(_ content: ReadoutContent, status: ReadoutContent.Status, model: AppModel,
                       now: Date) -> Attributes.ContentState {
        let session = content.session
        if model.isMirroringSession, Self.isReconnecting(model) {
            return unreachable(content, status: status, model: model)
        }
        var then: Attributes.Readout?
        if let endsAt = status.endsAt {
            // What the readout says just after the countdown has run out, for the extension to show by itself.
            let after = endsAt.addingTimeInterval(0.05)
            then = readout(content.phoneStatus(at: after), session: session, now: after)
        }
        return Attributes.ContentState(title: content.phoneTitle, position: Self.position(session),
                                       status: readout(status, session: session, now: now), then: then,
                                       triggers: Self.triggers(session), updated: updated(model, now: now),
                                       step: stepButton(content, model: model))
    }

    /// A Mac's training this iPhone can't reach: the card's main message is «Нет связи с Mac» in place of the big
    /// number (GPT, round 7: a countdown carried on from old data still read as live), «Открыть» in the button's
    /// place — a press can't reach the Mac, and the app, opened, finds it again. Nothing that ticks.
    private func unreachable(_ content: ReadoutContent, status: ReadoutContent.Status,
                             model: AppModel) -> Attributes.ContentState {
        let readout = Attributes.Readout(tone: .orange, glyph: .noLink,
                                         value: String(localized: "Нет связи с \(model.linkedHostKind)"), isWords: true,
                                         endsAt: nil, countsUpFrom: nil,
                                         plus: false, tintsValue: true, progressFrom: nil, progressFull: false,
                                         hidesProgress: true)
        return Attributes.ContentState(title: content.phoneTitle, position: Self.position(content.session), status: readout,
                                       then: nil, step: nil, openApp: String(localized: "Открыть"))
    }

    /// «из 5» next to «Выход 3»: outside an exit of the plan and before the first one.
    private static func position(_ session: TrainingSession) -> String? {
        switch session.phase {
        case .ready, .leaving, .away:
            guard session.currentExit?.isOpen == false else { return nil }
            return String(localized: "из \(session.plan.exits.count)")
        case .breakTime, .finished:
            return nil
        }
    }

    /// What the trainer's text asks to take for the exit ahead («взять ключи»), in a break and before the first exit.
    private static func triggers(_ session: TrainingSession) -> String? {
        let exit: PlannedExit?
        switch session.phase {
        case .ready:
            exit = session.currentExit
        case .breakTime(_, _, _, let next?):
            exit = session.plan.exits.indices.contains(next) ? session.plan.exits[next] : nil
        default:
            exit = nil
        }
        guard let triggers = exit?.triggers, !triggers.isEmpty else { return nil }
        return triggers.joined(separator: " · ")
    }

    /// The app's main button, if it may be pressed from the lock screen: «Вернулись» or «Вышли». Not «Завершить»
    /// (the last break), and nothing while a Mac's training can't be reached (the app's buttons are off then too).
    private func stepButton(_ content: ReadoutContent, model: AppModel) -> Attributes.StepButton? {
        guard !Self.isReconnecting(model) else { return nil }
        switch content.step {
        case .outside?: return Attributes.StepButton(kind: .outside, title: ReadoutContent.Step.outside.title)
        case .backInside?: return Attributes.StepButton(kind: .backInside, title: ReadoutContent.Step.backInside.title)
        case .finish?, nil: return nil
        }
    }

    /// The number alone, in the phase colour where it isn't the plain countdown: past the plan «+0:17», orange — no
    /// words over it, no «до 20:44», no «план 1 мин» (design council, round 12). The last break, with no exit ahead to
    /// count down to, counts its own time up, white, without a line (round 15, as the app's card).
    private func readout(_ status: ReadoutContent.Status, session: TrainingSession, now: Date) -> Attributes.Readout {
        var lastBreak = false
        if case .breakTime(_, _, _, nil) = session.phase { lastBreak = true }
        let overPlan = status.kind == .overdue || status.kind == .breakOver
        // The line fills from where the countdown began: `progress` is linear in time up to `endsAt` (not where it is
        // held at 0, e.g. a demo break longer than its plan: the start found would move with `now`).
        var progressFrom: Date?
        if let end = status.endsAt, let progress = status.progress, progress > 0.001, progress < 0.999 {
            progressFrom = end.addingTimeInterval(-end.timeIntervalSince(now) / (1 - progress))
        }
        return Attributes.Readout(tone: Self.tone(status), glyph: Self.glyph(status), value: status.value,
                                  isWords: status.isWords, endsAt: status.endsAt,
                                  countsUpFrom: status.countsUpFrom, plus: overPlan, tintsValue: overPlan,
                                  progressFrom: progressFrom, progressFull: (status.progress ?? 0) >= 0.999,
                                  hidesProgress: lastBreak ? true : nil)
    }

    /// The phase's sign (`TrainingActivityAttributes.Glyph`), the same on both sides of zero: ⏸ for a break run over
    /// too, the exit's door past its plan too.
    private static func glyph(_ status: ReadoutContent.Status) -> Attributes.Glyph {
        switch status.kind {
        case .breakTime, .breakOver: return .rest
        case .done: return .done
        default: return .outside
        }
    }

    private static func tone(_ status: ReadoutContent.Status) -> Attributes.Tone {
        switch status.kind {
        case .breakTime: return .blue
        case .overdue, .breakOver: return .overtime
        default: return .pink
        }
    }

    /// The link to the Mac dropped and is being restored: presses can't reach it.
    private static func isReconnecting(_ model: AppModel) -> Bool {
        #if DEBUG
        // `--demo-live-link-lost`: a Mac's training looks cut off from its Mac (screenshots of that state).
        if model.isMirroringSession, CommandLine.arguments.contains("--demo-live-link-lost") { return true }
        #endif
        return model.isReconnecting
    }

    /// A Mac's training goes on there; the iPhone hears of it only while the app runs. In the background iOS gives the
    /// app some 30 s before it suspends it: while they last the card is current and says nothing about it; when they
    /// are nearly out, the last update says when the iPhone last heard of the Mac («🕓 с Mac в 19:04»), so an old state
    /// doesn't pass for the current one (the timers go on counting from it either way). In the app's language, like
    /// every other text here (the extension would use the device's).
    private func updated(_ model: AppModel, now: Date) -> Attributes.Updated? {
        guard model.isMirroringSession else { return nil }
        let app = UIApplication.shared
        var aboutToSleep = app.applicationState == .background && app.backgroundTimeRemaining < Self.suspendMargin
        #if DEBUG
        // `--demo-live-stale`: as once the app is about to be suspended (screenshots).
        if app.applicationState == .background, CommandLine.arguments.contains("--demo-live-stale") { aboutToSleep = true }
        #endif
        guard aboutToSleep else { return nil }
        let kind = model.linkedHostKind
        let at = lastLinked ?? now
        let time = Self.clockTime(at)
        return Attributes.Updated(text: String(localized: "с \(kind) в \(time)"),
                                  spoken: String(localized: "Обновлено с \(kind) в \(time)"), at: at)
    }

    /// The background time left at which the card is told the news will stop: enough for the update to get through
    /// before iOS suspends the app (the loop looks four times a second).
    private static let suspendMargin: TimeInterval = 10
}

// MARK: - Not every second

private extension TrainingActivityAttributes.ContentState {
    /// The same thing on screen: dates computed again from a later moment differ by a hair, and that is no reason
    /// to send an update (iOS gives a Live Activity only so many).
    func isClose(to other: Self) -> Bool {
        guard status.isClose(to: other.status) else { return false }
        switch (then, other.then) {
        case (nil, nil): break
        case let (a?, b?): guard a.isClose(to: b) else { return false }
        default: return false
        }
        var a = self, b = other
        a.status = b.status
        a.then = b.then
        // «с Mac в …» takes the time of the update that carries it: alone it is no reason for one.
        if a.updated != nil, b.updated != nil { a.updated = b.updated }
        return a == b
    }
}

private extension TrainingActivityAttributes.Readout {
    func isClose(to other: Self) -> Bool {
        func close(_ x: Date?, _ y: Date?) -> Bool {
            switch (x, y) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x.timeIntervalSince(y)) < 0.5
            default: return false
            }
        }
        guard close(endsAt, other.endsAt), close(countsUpFrom, other.countsUpFrom),
              close(progressFrom, other.progressFrom) else { return false }
        var a = self, b = other
        a.endsAt = nil; b.endsAt = nil
        a.countsUpFrom = nil; b.countsUpFrom = nil
        a.progressFrom = nil; b.progressFrom = nil
        // The frozen number of a ticking readout changes every second and isn't shown.
        if endsAt != nil || countsUpFrom != nil, !isWords { a.value = ""; b.value = "" }
        return a == b
    }
}
/// A vibration felt with the phone on the table or the sofa, not only in the hand: three long buzzes at full strength,
/// each opened by a sharp knock (Core Haptics, ~1.7 s in all). The impact generator's soft knocks it replaces are only
/// felt in the hand. Where Core Haptics can't play (no Taptic Engine, the engine failed), the system's own vibration,
/// twice. Like every haptic, only while the app is in front: out of it the notification vibrates (`TrainingAlerts`).
@MainActor
final class StrongBuzz {
    private var engine: CHHapticEngine?
    static let buzzes = 3
    static let length: TimeInterval = 0.45
    static let pause: TimeInterval = 0.2

    nonisolated init() {}

    func play() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return Self.systemVibration(times: 2) }
        do {
            let engine = try self.engine ?? makeEngine()
            self.engine = engine
            // Stopped by the system meanwhile (the app was in the background, an interruption): started again.
            try engine.start()
            try engine.makePlayer(with: Self.pattern()).start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[glance] haptics failed (\(error.localizedDescription)): the system vibration instead")
            engine = nil
            Self.systemVibration(times: 2)
        }
    }

    private func makeEngine() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        // No sound of its own, and no part in the player's audio session.
        engine.playsHapticsOnly = true
        // Idle between breaks: the hardware may sleep; `start()` before each pattern wakes it.
        engine.isAutoShutdownEnabled = true
        // After a reset the next `play` starts it again.
        engine.resetHandler = {}
        return engine
    }

    private static func pattern() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = []
        for index in 0..<buzzes {
            let start = Double(index) * (length + pause)
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
            ], relativeTime: start))
            // Low sharpness: the deep buzz that carries through a table top.
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
            ], relativeTime: start, duration: length))
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    /// The system's vibration (~0.4 s), `times` in a row.
    private static func systemVibration(times: Int) {
        guard times > 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(kSystemSoundID_Vibrate) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { systemVibration(times: times - 1) }
        }
    }
}
#endif
