#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications
import WaitingPawsCore

/// The training's timers as notifications while the app is not in front (design council, round 4): the exit's plan
/// time reached and the break's plan over — the same moments the app vibrates for when it is open
/// (`TrainingGlance.vibrate`). Local ones, without a server: `TrainingGlance` hands
/// over what is coming when the app leaves the front, and again whenever the training changes in the background (a
/// press on the Live Activity's button, news from the Mac); each is scheduled for its countdown's end. Back in front,
/// all of them are taken away: the app shows and vibrates by itself there.
///
/// They tell what the timer did, in one line — «Выход 3 — время вышло», «Перерыв закончился» — and nothing the card
/// above them already shows: the plan, the exit ahead, a lost link (design council, rounds 12 and 13). Not that the
/// owner may come in: the trainer's text says when to come in, and the app doesn't see the dog. Plain titles, no emoji (Fable, round
/// 7: the Live Activity above them speaks in SF Symbols, and a notification can't carry those; the app's icon already
/// says whose it is). They make no sound (a chime behind the door is heard by the dog): a silent sound file brings the
/// system's vibration when «Вибрация» is on. Time Sensitive, to get through a Focus once
/// the app has that capability (a paid developer account); until then iOS delivers them as ordinary ones.
@MainActor
final class TrainingAlerts: NSObject {
    /// One notification to come: what runs out, and when.
    struct Alert: Equatable {
        /// The readout's state it starts (`ReadoutContent.Status.Kind`): a rescheduled one is matched by it.
        var kind: String
        var date: Date
        var title: String
        var body: String
        /// What ran out (`Event`), for the notification's category.
        var event: Event
    }

    /// What ran out: each kind of notification has its category.
    enum Event: String {
        case plan, rest
    }

    private struct Scheduled {
        var id: String
        var alert: Alert
    }

    private let center = UNUserNotificationCenter.current()
    /// iOS's answer, once known.
    private(set) var authorization: UNAuthorizationStatus?
    private var asking = false
    /// Scheduled from this state of the training, delivered ones included until they are taken away.
    private var scheduled: [Scheduled] = []
    /// Some may be pending or delivered (left over from an earlier run of the app, too).
    private var mayHaveSome = true
    /// The center's calls, one after another: a removal must not overtake the additions made after it.
    private var queue: Task<Void, Never>?
    private var counter = 0

    private static let prefix = "training."

    var isAllowed: Bool {
        switch authorization {
        case .authorized?, .provisional?, .ephemeral?: return true
        default: return false
        }
    }

    func start() {
        center.delegate = self
        removeAll()
        refreshAuthorization()
    }

    func refreshAuthorization() {
        enqueue { [weak self] in
            guard let self else { return }
            self.authorization = await self.center.notificationSettings().authorizationStatus
        }
    }

    /// iOS's question, when a training is under way in front of the owner (its start: the moment it makes sense).
    func askIfNeeded() {
        guard authorization == .notDetermined, !asking else { return }
        asking = true
        enqueue { [weak self] in
            guard let self else { return }
            let granted = (try? await self.center.requestAuthorization(options: [.alert, .sound])) ?? false
            self.authorization = await self.center.notificationSettings().authorizationStatus
            self.asking = false
            print("[glance] notifications \(granted ? "allowed" : "not allowed")")
        }
    }

    /// From now on exactly `alerts` are to come. If what is coming has changed (a step was taken, a mark made), the
    /// ones already delivered go too: they were about a state that is gone. A change of words alone (the time of the
    /// Mac's last news) replaces the pending ones and leaves the delivered.
    func show(_ alerts: [Alert], vibrates: Bool, now: Date) {
        guard isAllowed else { return }
        let ahead = scheduled.filter { $0.alert.date > now }
        var unmatched = ahead
        var kept: [(Scheduled, Alert)] = []
        for alert in alerts {
            guard let index = unmatched.firstIndex(where: {
                $0.alert.kind == alert.kind && abs($0.alert.date.timeIntervalSince(alert.date)) < 1
            }) else { break }
            kept.append((unmatched.remove(at: index), alert))
        }
        if kept.count == alerts.count, unmatched.isEmpty {
            let changed = kept.filter { $0.0.alert.title != $0.1.title || $0.0.alert.body != $0.1.body }
            guard !changed.isEmpty else { return }
            for (old, alert) in changed {
                scheduled = scheduled.map { $0.id == old.id ? Scheduled(id: old.id, alert: alert) : $0 }
                add(alert, id: old.id, vibrates: vibrates)
            }
            return
        }
        let gone = scheduled.map(\.id)
        if !gone.isEmpty {
            // Behind the additions still queued: one of them may be among these.
            enqueue { [weak self] in
                self?.center.removePendingNotificationRequests(withIdentifiers: gone)
                self?.center.removeDeliveredNotifications(withIdentifiers: gone)
            }
        }
        scheduled = alerts.map { alert in
            counter += 1
            return Scheduled(id: Self.prefix + "\(counter)", alert: alert)
        }
        for item in scheduled { add(item.alert, id: item.id, vibrates: vibrates) }
        mayHaveSome = mayHaveSome || !scheduled.isEmpty
        let first = alerts.first.map { "«\($0.title)» in \(Int($0.date.timeIntervalSince(now).rounded())) s" } ?? "none"
        print("[glance] notifications scheduled: \(alerts.count) (first \(first))")
    }

    /// The app is in front, the training is over or notifications are off: none pending, none left on the lock screen.
    func removeAll() {
        scheduled = []
        guard mayHaveSome else { return }
        mayHaveSome = false
        enqueue { [weak self] in
            guard let self else { return }
            let pending = await self.center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(Self.prefix) }
            let delivered = await self.center.deliveredNotifications().map(\.request.identifier)
                .filter { $0.hasPrefix(Self.prefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: pending)
            self.center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }

    /// Returns once the center has everything asked of it (iOS may suspend the app right after).
    func settle() async {
        await queue?.value
    }

    private func add(_ alert: Alert, id: String, vibrates: Bool) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = vibrates ? Self.vibrationOnly : nil
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "training"
        content.categoryIdentifier = "training.\(alert.event.rawValue)"
        content.relevanceScore = 1
        // From the moment it is added: the date may be a hair away by then.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.5, alert.date.timeIntervalSinceNow),
                                                        repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        enqueue { [weak self] in
            do {
                try await self?.center.add(request)
            } catch {
                print("[glance] notification not scheduled: \(error.localizedDescription)")
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queue
        // In the background the app may be about to be suspended: a moment for the center to get it.
        let grace = UIApplication.shared.applicationState == .active ? nil : Grace()
        queue = Task {
            await previous?.value
            await operation()
            grace?.end()
        }
    }

    /// A few seconds of background time.
    @MainActor
    private final class Grace {
        private var id = UIBackgroundTaskIdentifier.invalid

        init() {
            id = UIApplication.shared.beginBackgroundTask(withName: "Training notifications") { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // MARK: - The sound

    /// A notification's sound that is not heard: half a second of silence, so that iOS vibrates with it (a
    /// notification without a sound doesn't vibrate). Written once to `Library/Sounds`, where iOS looks for it.
    private static let vibrationOnly: UNNotificationSound? = {
        let name = "WaitingPaws-silence.wav"
        let files = FileManager.default
        guard let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = library.appendingPathComponent("Sounds", isDirectory: true)
        let file = folder.appendingPathComponent(name)
        if !files.fileExists(atPath: file.path) {
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                try silence(seconds: 0.5).write(to: file, options: .atomic)
            } catch {
                print("[glance] no silent sound: \(error.localizedDescription)")
                return nil
            }
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }()

    /// A WAV file of silence: 16-bit mono PCM at 8 kHz.
    private static func silence(seconds: Double) -> Data {
        let rate: UInt32 = 8000
        let size = UInt32(Double(rate) * seconds) * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); number(36 + size); text("WAVE")
        text("fmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(rate); number(rate * 2)
        number(UInt16(2)); number(UInt16(16))
        text("data"); number(size)
        data.append(Data(count: Int(size)))
        return data
    }

    // MARK: - What is coming

    /// What runs out from `now` on if nothing is pressed meanwhile: the shown countdown's end, as the readout will show
    /// it.
    static func upcoming(_ session: TrainingSession, now: Date) -> [Alert] {
        let content = ReadoutContent(session: session)
        let status = content.status(at: now, watch: nil)
        guard let end = status.endsAt, end > now else { return [] }
        let after = content.status(at: end.addingTimeInterval(0.05), watch: nil)
        guard after.kind != status.kind, let alert = alert(to: after, at: end, content: content) else {
            return []
        }
        return [alert]
    }

    /// The words for one moment, one line that fits a lock screen's title (some 25 letters). A state the app doesn't
    /// vibrate for gets none.
    private static func alert(to after: ReadoutContent.Status, at date: Date, content: ReadoutContent) -> Alert? {
        let session = content.session
        let title: String
        let event: Event
        switch after.kind {
        case .overdue:
            guard let exit = session.currentExit, !exit.isOpen else { return nil }
            title = String(localized: "Выход \(exit.number) — время вышло")
            event = .plan
        case .breakOver:
            guard case .breakTime = session.phase else { return nil }
            title = String(localized: "Перерыв закончился")
            event = .rest
        default:
            return nil
        }
        return Alert(kind: "\(after.kind)", date: date, title: title, body: "", event: event)
    }
}

extension TrainingAlerts: UNUserNotificationCenterDelegate {
    /// One arriving while the app is in front: not shown (the app says it on its screen and vibrates by itself); over
    /// the app but not in front of it (Control Center pulled down, a call), shown.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            completionHandler(UIApplication.shared.applicationState == .active ? [] : [.banner, .list, .sound])
        }
    }

    /// A tap on one opens the app on the training: nothing else to do.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// Settings' «Уведомления»: the switch (turned on, it asks iOS if it hasn't yet), and the way to iOS's settings when
/// notifications are off there for the app.
struct TrainingAlertsToggle: View {
    @Binding var isOn: Bool
    @State private var status: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Toggle("Уведомления", isOn: $isOn)
            .onChange(of: isOn) { _, on in
                guard on else { return }
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    await check()
                }
            }
            .task { await check() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await check() } }
            }
        if isOn, status == .denied {
            Button("Включить в настройках iOS") {
                guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        }
    }

    private func check() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
#endif
