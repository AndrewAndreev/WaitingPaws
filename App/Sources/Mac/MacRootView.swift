#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Main window: the «Пульт» once a camera is set up; otherwise a pointer to the welcome window.
struct MacMainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.settings.isConfigured {
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
        }
    }
}
#endif
