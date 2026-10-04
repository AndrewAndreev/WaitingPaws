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
                .modifier(DebugWindowOpener())
        }
        .defaultSize(width: 1440, height: 860)
        .defaultLaunchBehavior(model.settings.isConfigured || Self.previewConfigured ? .presented : .suppressed)
        .commands { MacCommands(model: model, ui: ui) }

        // First launch: sign in to Xiaomi or pick a go2rtc stream (Xcode-style welcome window).
        Window("Добро пожаловать в Waiting Paws", id: "welcome") {
            MacWelcomeView()
                .environment(model)
                .environment(ui)
                .tint(MacPalette.accent)
                .modifier(DebugWindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.settings.isConfigured || Self.previewConfigured ? .suppressed : .presented)

        Window("История", id: "history") {
            MacHistoryWindow()
                .environment(model)
                .environment(ui)
                .tint(MacPalette.accent)
        }
        .defaultSize(width: 1360, height: 840)

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
    /// DEBUG `--demo-camera <path>` shows the «Пульт» with a still picture even without a configured camera.
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private static var done = false

    func body(content: Content) -> some View {
        content.task {
            #if DEBUG
            guard !Self.done, let index = CommandLine.arguments.firstIndex(of: "--open"),
                  index + 1 < CommandLine.arguments.count else { return }
            Self.done = true
            switch CommandLine.arguments[index + 1] {
            case "settings": openSettings()
            case let id: openWindow(id: id)
            }
            #endif
        }
    }
}
#endif
