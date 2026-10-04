#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Main window: the «Пульт» once a camera is set up; otherwise a pointer to the welcome window.
struct MacMainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var configured: Bool {
        #if DEBUG
        // `--preview-unconfigured`: behave as on a first launch (UI checks next to a configured copy).
        if CommandLine.arguments.contains("--preview-unconfigured") { return false }
        #endif
        return model.settings.isSetUp || WaitingPawsApp.previewConfigured
    }

    var body: some View {
        if configured {
            MacConsoleView()
        } else {
            ContentUnavailableView {
                Label("Камера не подключена", systemImage: "video.slash")
            } description: {
                Text("Войдите в Xiaomi, выберите поток go2rtc или продолжите без камеры в окне приветствия.")
            } actions: {
                Button("Подключить камеру…") { openWindow(id: "welcome") }
                    .buttonStyle(.borderedProminent)
            }
            .onAppear {
                // First launch: only the welcome window, like Xcode. (A `.suppressed` launch behaviour on this
                // scene leaves the app without any window when the welcome one is suppressed too.)
                openWindow(id: "welcome")
                dismissWindow(id: "main")
            }
        }
    }
}
#endif
