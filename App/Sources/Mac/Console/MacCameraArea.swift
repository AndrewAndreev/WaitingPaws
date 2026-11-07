#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The live camera (go2rtc player, trackpad / mouse / menu zoom), or why there is none.
///
/// Zoomed in, the picture is not cut at the toolbar: the camera's column reaches up to the window's top edge, and what
/// of the picture lies above the area shows under the toolbar, where the header's pieces float over it on their own
/// glass with a shadow (`ConsoleHeader`; the owner, 2026-11-06, in place of a frosted band under the whole toolbar).
/// The area under the toolbar is still what is framed: gestures and the corner pill keep to it. Panning takes the
/// picture up to the window's top, so zoomed in far enough it fills the window under the header too (the owner,
/// 2026-11-07: the top of the pan left black there). The sides and the bottom stay cut: the panel and the timeline
/// are there.
struct MacCameraArea: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    var reloadToken: Int
    /// The area's top in the window: under the toolbar.
    @State private var areaTop: CGFloat = 0

    var body: some View {
        Color.black
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { areaTop = $0 }
            .overlay {
                GeometryReader { geometry in
                    // The toolbar's height over the column (the proxy reports no safe area once it is ignored).
                    let top = max(0, areaTop - geometry.frame(in: .global).minY)
                    content(bleedTop: top)
                        .padding(.top, top)
                }
                // Cut at the column (up to the window's top), not at the area: the clip goes inside the extension.
                .clipped()
                .ignoresSafeArea(.container, edges: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Settings → Диагностика → «Показывать нагрузку»: the video's delay and the load, over the picture.
            .overlay(alignment: .bottomLeading) {
                if model.performance.isRunning {
                    PerformanceBar(fillsWidth: false).padding(12).allowsHitTesting(false)
                }
            }
            .onChange(of: model.settings.streamName) {
                ui.cameraZoom.reset()
                model.panTilt.stop()
            }
            #if DEBUG
            // `--demo-zoom=<scale>[@x,y]`: the picture zoomed in (UI checks), round its point x, y (0…1) where the
            // edges allow (`0,0`: panned as far as it goes to the top-left corner). One argument: a lone value would
            // shift AppKit's `-key value` pairing and be opened as a document (no window).
            .task {
                guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-zoom=") })?.dropFirst(12)
                else { return }
                let parts = raw.split(separator: "@")
                let point = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
                guard let scale = parts.first.flatMap({ Double($0) }) else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if point.count == 2 {
                    ui.cameraZoom.frame(scale: scale, x: point[0], y: point[1])
                } else {
                    ui.cameraZoom.zoom(to: scale)
                }
            }
            #endif
    }

    /// Width over height of the picture shown (16:9 until the player says): the zoom keeps to the picture, not to the
    /// black round it.
    private var aspect: CGFloat {
        #if DEBUG
        if let image = DemoData.cameraImage, image.size.height > 0 { return image.size.width / image.size.height }
        #endif
        let size = model.isShowingSecondCamera ? model.secondVideoSize : model.videoSize
        guard let size, size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    @ViewBuilder
    private func content(bleedTop: CGFloat) -> some View {
        #if DEBUG
        if let image = DemoData.cameraImage {
            ZoomableView(zoom: ui.cameraZoom, aspect: aspect, overflows: true,
                         bleed: EdgeInsets(top: bleedTop, leading: 0, bottom: 0, trailing: 0)) {
                ZStack {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .opacity(model.isShowingSecondCamera ? 0 : 1)
                    if model.hasSecondCamera {
                        // The second camera in demos: the same picture mirrored.
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .scaleEffect(x: -1, y: 1)
                            .opacity(model.isShowingSecondCamera ? 1 : 0)
                    }
                }
            }
        } else {
            stream(bleedTop: bleedTop)
        }
        #else
        stream(bleedTop: bleedTop)
        #endif
    }

    @ViewBuilder
    private func stream(bleedTop: CGFloat) -> some View {
        if !model.settings.isConfigured {
            noCamera
        } else if model.settings.connectionMode == .embedded, !model.embedded.status.isRunning {
            CameraPlaceholder(text: embeddedStatusText)
        } else if let server = model.settings.server, !model.settings.streamName.isEmpty {
            // Both cameras play all the time: the switcher only shows one, so switching never reconnects.
            // The player zooms the picture in its layer and lets it run up under the toolbar itself (`PlayerWebView`).
            ZoomableView(zoom: ui.cameraZoom, contentZooms: true, aspect: aspect, overflows: true,
                         bleed: EdgeInsets(top: bleedTop, leading: 0, bottom: 0, trailing: 0)) {
                ZStack {
                    CameraStreamView(server: server,
                                     stream: model.settings.streamName,
                                     mode: model.settings.playerMode,
                                     audioEnabled: model.settings.audioEnabled && !model.isShowingSecondCamera,
                                     reloadToken: reloadToken + model.playerGeneration,
                                     onVideoSize: { size in model.videoSize = size },
                                     onDelay: { model.performance.notePlayerDelay(buffer: $0, network: $1) },
                                     bleedTop: bleedTop)
                        .opacity(model.isShowingSecondCamera ? 0 : 1)
                        .allowsHitTesting(!model.isShowingSecondCamera)
                    if model.hasSecondCamera {
                        CameraStreamView(server: server,
                                         stream: model.activeSecondStreamName,
                                         mode: model.settings.playerMode,
                                         audioEnabled: model.settings.audioEnabled && model.isShowingSecondCamera,
                                         reloadToken: reloadToken + model.activeSecondPlayerGeneration,
                                         onVideoSize: { size in model.secondVideoSize = size },
                                         onDelay: { _, _ in },
                                         bleedTop: bleedTop)
                            .opacity(model.isShowingSecondCamera ? 1 : 0)
                            .allowsHitTesting(model.isShowingSecondCamera)
                    }
                }
            }
        } else {
            CameraPlaceholder(text: String(localized: "Камера не выбрана"))
        }
    }

    /// Started without a camera: the timer, schedule and log work; a camera can be added any time.
    private var noCamera: some View {
        ContentUnavailableView {
            Label("Без камеры", systemImage: "pawprint.fill")
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
