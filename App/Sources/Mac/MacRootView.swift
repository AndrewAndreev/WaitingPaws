#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Main window: the «Пульт» once a camera is set up; otherwise a pointer to the welcome window.
struct MacMainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if model.settings.isConfigured || WaitingPawsApp.previewConfigured {
            MacConsoleView()
        } else {
            ContentUnavailableView {
                Label("Камера не подключена", systemImage: "video.slash")
            } description: {
                Text("Войдите в Xiaomi или выберите поток go2rtc в окне приветствия.")
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
