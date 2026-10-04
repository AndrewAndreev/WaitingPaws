#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The live camera (go2rtc player, pinch / trackpad zoom), or why there is none.
struct MacCameraArea: View {
    @Environment(AppModel.self) private var model
    var reloadToken: Int

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let image = DemoData.cameraImage {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            stream
        }
        #else
        stream
        #endif
    }

    @ViewBuilder
    private var stream: some View {
        if model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.settings.server, !model.settings.streamName.isEmpty {
            ZoomableView {
                CameraStreamView(server: server,
                                 stream: model.settings.streamName,
                                 mode: model.settings.playerMode,
                                 audioEnabled: model.settings.audioEnabled,
                                 reloadToken: reloadToken,
                                 onVideoSize: { size in model.videoSize = size })
            }
        } else {
            CameraPlaceholder(text: "Камера не выбрана")
        }
    }

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle, .starting: return "Запускаем go2rtc…"
        case .failed(let message): return message
        case .unavailable: return "Встроенный go2rtc не собран"
        case .running: return ""
        }
    }
}
#endif
