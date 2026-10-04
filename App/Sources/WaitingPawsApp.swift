import SwiftUI
import WaitingPawsCore

@main
struct WaitingPawsApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @State private var ui = MacUIState()
    #endif

    var body: some Scene {
        #if os(macOS)
        // «Пульт»: camera, readout, the session timeline.
        Window("Waiting Paws", id: "main") {
            MacMainWindow()
                .environment(model)
                .environment(ui)
                .preferredColorScheme(.dark)
                .tint(MacPalette.pink)
                .modifier(DebugWindowOpener(model: model))
        }
        .defaultSize(width: 1440, height: 860)
        .commands { MacCommands(model: model, ui: ui) }

        // First launch: sign in to Xiaomi or pick a go2rtc stream (Xcode-style welcome window).
        Window("Добро пожаловать в Waiting Paws", id: "welcome") {
            MacWelcomeView()
                .environment(model)
                .environment(ui)
                .tint(MacPalette.accent)
                .modifier(DebugWindowOpener(model: model))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // Opened by the main window when no camera is set up; never on its own or restored from last time.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("История", id: "history") {
            MacHistoryWindow()
                .environment(model)
                .environment(ui)
                .tint(MacPalette.accent)
        }
        .defaultSize(width: 1360, height: 840)
        // Only from the toolbar button / ⌘Y — not at launch, not restored from the previous session.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsView()
                .environment(model)
                .environment(ui)
                .tint(MacPalette.accent)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #endif
    }

    #if os(macOS)
    /// DEBUG `--demo-camera=<path>` shows the «Пульт» with a still picture even without a configured camera.
    static var previewConfigured: Bool {
        #if DEBUG
        return DemoData.cameraImage != nil
        #else
        return false
        #endif
    }
    #endif
}

#if os(macOS)
/// DEBUG `--open history|settings|welcome|main`: open that window at launch (UI checks without clicks).
struct DebugWindowOpener: ViewModifier {
    /// Passed in: this modifier sits outside the `.environment(model)` of the window content.
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private static var done = false

    private static var pairingShown = false

    func body(content: Content) -> some View {
        content.onAppear {
            #if DEBUG
            // `--demo-pairing`: an iPhone asks to join (checks the «Подключить?» prompt without a phone).
            if CommandLine.arguments.contains("--demo-pairing"), !Self.pairingShown {
                Self.pairingShown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MacPairingPrompt.present(SyncHost.PairingRequest(id: UUID(), deviceName: "iPhone Андрея"), host: model.syncHost)
                }
            }
            guard !Self.done, let index = CommandLine.arguments.firstIndex(of: "--open"),
                  index + 1 < CommandLine.arguments.count else { return }
            Self.done = true
            let target = CommandLine.arguments[index + 1]
            // A beat later: on first launch the main window hands over to the welcome window right away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if target == "settings" { openSettings() } else { openWindow(id: target) }
            }
            #endif
        }
    }
}
#endif
