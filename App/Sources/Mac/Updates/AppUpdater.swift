#if os(macOS) && WP_DIRECT
import AppKit
import Observation
import Sparkle

/// Updates of the Mac app downloaded from GitHub (target WaitingPaws-macOS-Direct, Developer ID) through Sparkle.
/// The App Store app has none: the App Store updates it.
///
/// A new version found in the background never opens a window: it shows as «Обновление» in the toolbar
/// (`UpdateGroup`), outside a training or a recording. «Проверить обновления…» and the toolbar's «Загрузить и
/// установить» use Sparkle's own window. Settings → About has the mode, the nightly switch and «Проверить сейчас».
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// Made at launch (`start(model:)`); nil in the App Store app, which has no `AppUpdater` at all.
    private(set) static var shared: AppUpdater?

    /// Settings → About «Новые версии».
    enum Mode: String, CaseIterable, Identifiable {
        /// Download in the background, install when the app quits (or at «Перезапустить»).
        case automatic
        /// Show «Обновление» for a new version, download it only when asked.
        case notify
        /// Only «Проверить сейчас» / «Проверить обновления…».
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return String(localized: "Install automatically")
            case .notify: return String(localized: "Notify only")
            case .manual: return String(localized: "Don't check")
            }
        }

        var explanation: String {
            switch self {
            case .automatic:
                return String(localized: "They download in the background and install when you quit Waiting Paws. A training or a recording is never interrupted.")
            case .notify:
                return String(localized: "Once a day the app checks for a new version and shows “Update” in the toolbar. It downloads when you say so.")
            case .manual:
                return String(localized: "Only with “Check Now” or “Check for Updates…” in the menu.")
            }
        }
    }

    /// A version waiting for the user: shown as «Обновление» in the toolbar and in Settings → About.
    struct Pending: Equatable {
        var version: String
        /// The release's first lines («что нового»), at most four.
        var notes: [String]
        /// Downloaded and installed on quit; «Перезапустить» installs it at once. Otherwise only found.
        var downloaded: Bool
        var releasePage: URL
    }

    /// False in a build from Xcode (version 0.0.0, "dev"): it has no version to compare, so it never checks.
    let isAvailable: Bool
    /// Sparkle can start a check now (not while one is running).
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    private(set) var pending: Pending?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var postponedRelaunch: Task<Void, Never>?
    /// From `willInstallUpdateOnQuit`: installs the downloaded version and relaunches, without Sparkle's window.
    @ObservationIgnored private var installNowHandler: (() -> Void)?

    private static let nightlyKey = "WPUpdatesNightly"

    /// DEBUG `--demo-update [found]`: a waiting 1.7.21 without Sparkle (downloaded, or with `found` only found), for UI
    /// checks of «Обновление» and Settings → About. `--demo-update-popover` opens the popover too (`UpdateGroup`).
    private static var demoPending: Pending? {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-update") else { return nil }
        let found = arguments.indices.contains(index + 1) && arguments[index + 1] == "found"
        let notes = "- Обновления прямо из приложения\n- Камера быстрее подключается после перезапуска\n"
            + "- Недоделанная ночная запись больше не грузит процессор"
        return Pending(version: "1.7.21", notes: UpdateNotes.lines(notes), downloaded: !found, releasePage: releasesPage)
        #else
        return nil
        #endif
    }

    static var demoOpensPopover: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-update-popover")
        #else
        return false
        #endif
    }
    static let releasesPage = URL(string: "https://github.com/AndrewAndreev/WaitingPaws/releases")!

    static func start(model: AppModel) {
        guard shared == nil else { return }
        shared = AppUpdater(model: model)
    }

    private init(model: AppModel) {
        self.model = model
        isAvailable = AppInfo.release != nil || Self.demoPending != nil
        nightly = UserDefaults.standard.bool(forKey: Self.nightlyKey)
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: AppInfo.release != nil, updaterDelegate: self,
                                                  userDriverDelegate: self)
        pending = Self.demoPending
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

    var mode: Mode {
        get {
            access(keyPath: \.mode)
            let updater = controller.updater
            guard updater.automaticallyChecksForUpdates else { return .manual }
            return updater.automaticallyDownloadsUpdates ? .automatic : .notify
        }
        set {
            withMutation(keyPath: \.mode) {
                let updater = controller.updater
                updater.automaticallyChecksForUpdates = newValue != .manual
                updater.automaticallyDownloadsUpdates = newValue == .automatic
            }
        }
    }

    /// Settings → About «Тестовые сборки»: the nightly appcast (`WPNightlyFeedURL`) instead of the releases one. It
    /// lists the latest release too, so a newer release still arrives; switching back keeps the nightly until then.
    var nightly: Bool {
        didSet {
            guard nightly != oldValue else { return }
            UserDefaults.standard.set(nightly, forKey: Self.nightlyKey)
            pending = nil
            installNowHandler = nil
            if isAvailable, controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
        }
    }

    /// «Проверить обновления…» / «Проверить сейчас»: Sparkle's own window shows the result.
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    /// «Перезапустить» (downloaded) or «Загрузить и установить» (only found: Sparkle's window takes it from here).
    func installPending() {
        if let installNowHandler, !isBusy {
            installNowHandler()
        } else {
            checkForUpdates()
        }
    }

    /// The toolbar shows «Обновление»: something waits and no training or recording runs.
    var showsInToolbar: Bool {
        guard pending != nil, let model else { return false }
        return model.session == nil && !model.isRecordingNow
    }

    private var isBusy: Bool { model?.hasWorkBeforeQuit ?? false }

    private func remember(_ item: SUAppcastItem, downloaded: Bool) {
        pending = Pending(version: item.displayVersionString, notes: UpdateNotes.lines(item.itemDescription),
                          downloaded: downloaded, releasePage: item.fullReleaseNotesURL ?? Self.releasesPage)
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard UserDefaults.standard.bool(forKey: Self.nightlyKey) else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "WPNightlyFeedURL") as? String
    }

    /// No background check during a training or a recording. The next daily check comes later; one the user asks for
    /// («Проверить обновления…») always runs.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isBusy else { return }
        throw NSError(domain: "WaitingPaws.AppUpdater", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "A training or a recording is running"])
    }

    /// Downloaded in the background: «Обновление» in the toolbar; installed on quit, or at once by «Перезапустить».
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        remember(item, downloaded: true)
        installNowHandler = immediateInstallHandler
        return true
    }

    /// «Install and Relaunch» in Sparkle's window during a training or a recording: the relaunch waits until it has
    /// ended (and the video is finished), then the update installs.
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

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A version found by a background check: the toolbar shows it, not Sparkle's window.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        remember(update, downloaded: state.stage != .notDownloaded)
    }

    /// Sparkle's window took over (shown, installed, skipped): «Обновление» goes away.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if installNowHandler == nil { pending = nil }
    }

    func standardUserDriverWillFinishUpdateSession() {
        if installNowHandler == nil { pending = nil }
    }
}

/// The first lines of a release's description in the appcast (HTML `<li>`s or markdown `- ` lines).
enum UpdateNotes {
    static func lines(_ description: String?, limit: Int = 4) -> [String] {
        guard let description, !description.isEmpty else { return [] }
        var items: [String]
        if description.range(of: "<li", options: .caseInsensitive) != nil {
            items = description.components(separatedBy: "<li").dropFirst().map { part in
                let body = part.drop(while: { $0 != ">" }).dropFirst()
                return String(body.components(separatedBy: "</li").first ?? "")
            }
        } else {
            let lines = description.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            items = lines.compactMap { line in
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
                return nil
            }
        }
        return items.map(plain).filter { !$0.isEmpty }.prefix(limit).map { $0 }
    }

    /// Tags and the common entities out, spaces folded.
    private static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
#endif
