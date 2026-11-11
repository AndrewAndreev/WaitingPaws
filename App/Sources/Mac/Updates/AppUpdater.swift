#if os(macOS) && WP_DIRECT
import AppKit
import Observation
import Sparkle

/// Updates of the Mac app downloaded from GitHub (target WaitingPaws-macOS-Direct, Developer ID) through Sparkle.
/// The App Store app has none: the App Store updates it.
///
/// Sparkle checks the appcast once a day, downloads a new version in the background and installs it when the app quits
/// (Info-Direct.plist; both can be turned off in Settings → About). A training or a recording is never interrupted:
/// background checks wait for it to end, and «Install and Relaunch» relaunches only after it.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    /// Made at launch (`start(model:)`); nil in the App Store app, which has no `AppUpdater` at all.
    private(set) static var shared: AppUpdater?

    /// False in a build from Xcode (version 0.0.0, "dev"): it has no version to compare, so it never checks.
    let isAvailable: Bool
    /// Sparkle can start a check now (not while one is running).
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var postponedRelaunch: Task<Void, Never>?

    static func start(model: AppModel) {
        guard shared == nil else { return }
        shared = AppUpdater(model: model)
    }

    private init(model: AppModel) {
        self.model = model
        isAvailable = AppInfo.release != nil
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: isAvailable, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
    }

    /// Settings → About «Проверять автоматически».
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    /// Settings → About «Загружать и устанавливать автоматически».
    var installsAutomatically: Bool {
        get {
            access(keyPath: \.installsAutomatically)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.installsAutomatically) { controller.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    /// «Проверить обновления…»: Sparkle's own window shows the result (a new version, or "up to date").
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    private var isBusy: Bool { model?.hasWorkBeforeQuit ?? false }

    // MARK: SPUUpdaterDelegate

    /// No background check during a training or a recording: its window would pop up over the session. The next daily
    /// check comes later; one the user asks for («Проверить обновления…») always runs.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isBusy else { return }
        throw NSError(domain: "WaitingPaws.AppUpdater", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "A training or a recording is running"])
    }

    /// «Install and Relaunch» pressed during a training or a recording: the relaunch waits until it has ended (and the
    /// video is finished), then the update installs.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        postponedRelaunch?.cancel()
        postponedRelaunch = Task { @MainActor [weak self] in
            while let self, self.isBusy {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
            installHandler()
        }
        return true
    }
}
#endif
