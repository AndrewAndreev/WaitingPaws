#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The live camera (go2rtc player, trackpad / mouse / menu zoom), or why there is none.
struct MacCameraArea: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    var reloadToken: Int

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.settings.streamName) { ui.cameraZoom.reset() }
        #if DEBUG
        // `--demo-zoom=<scale>`: the picture zoomed in (UI checks). One argument: a lone value would shift
        // AppKit's `-key value` pairing and be opened as a document (no window).
        .task {
            guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-zoom=") })?.dropFirst(12),
                  let scale = Double(raw) else { return }
            try? await Task.sleep(for: .milliseconds(600))
            ui.cameraZoom.zoom(to: scale)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let image = DemoData.cameraImage {
            ZoomableView(zoom: ui.cameraZoom) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        } else {
            stream
        }
        #else
        stream
        #endif
    }

    @ViewBuilder
    private var stream: some View {
        if !model.settings.isConfigured {
            noCamera
        } else if model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.settings.server, !model.settings.streamName.isEmpty {
            ZoomableView(zoom: ui.cameraZoom) {
                CameraStreamView(server: server,
                                 stream: model.settings.streamName,
                                 mode: model.settings.playerMode,
                                 audioEnabled: model.settings.audioEnabled,
                                 reloadToken: reloadToken + model.playerGeneration,
                                 onVideoSize: { size in model.videoSize = size })
            }
        } else {
            CameraPlaceholder(text: String(localized: "Камера не выбрана"))
        }
    }

    /// Started without a camera: the timer, schedule and log work; a camera can be added any time.
    private var noCamera: some View {
        ContentUnavailableView {
            Label("Без камеры", systemImage: "pawprint.fill")
        } description: {
            Text("Таймеры, расписание и лог работают. С камерой вы увидите собаку, пока вы за дверью, и сможете записывать видео.")
        } actions: {
            Button("Подключить камеру…") { openWindow(id: "welcome") }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private var embeddedStatusText: String {
        switch model.embedded.status {
        case .idle, .starting: return String(localized: "Запускаем go2rtc…")
        case .failed(let message): return message
        case .unavailable: return String(localized: "Встроенный go2rtc не собран")
        case .running: return ""
        }
    }
}
#endif
