import SwiftUI
import WaitingPawsCore

@main
struct WaitingPawsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(width: 560, height: 640)
        }
        #endif
    }
}
