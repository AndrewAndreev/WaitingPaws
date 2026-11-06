#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// The live camera (go2rtc player, trackpad / mouse / menu zoom), or why there is none.
///
/// Zoomed in, the picture is not cut at the toolbar: the camera's column reaches up to the window's top edge, and what
/// of the picture lies above the area shows under the toolbar, frosted (`ToolbarFrost`): the title and the camera's
/// buttons sit on a matte toolbar, never straight on the picture (the owner, 2026-11-06, from the variants in
/// Design/shade-lab). The area under the toolbar is still what is framed: gestures, panning and the corner pill keep
/// to it. The sides and the bottom stay cut: the panel and the timeline are there.
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
                    let area = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - top))
                    // The picture runs up past the area: there is picture under the toolbar.
                    let runsUp = ui.cameraZoom.pictureFrame(in: area, aspect: aspect).minY < -0.5
                    ZStack(alignment: .topLeading) {
                        content(bleedTop: top)
                            .padding(.top, top)
                        // Just the toolbar's height: its lower edge is the area's top edge.
                        ToolbarFrost()
                            .frame(height: top)
                            .opacity(top > 0 && runsUp ? 1 : 0)
                            .animation(.easeInOut(duration: 0.2), value: runsUp)
                    }
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
            ZoomableView(zoom: ui.cameraZoom, aspect: aspect, overflows: true) {
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
            ZoomableView(zoom: ui.cameraZoom, contentZooms: true, aspect: aspect, overflows: true) {
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

/// The toolbar over a zoomed picture run up under it: a frosted band exactly the toolbar's height. The HUD material:
/// of the system's materials the one that keeps the picture's colours under its blur (the toolbar's own washed them
/// into flat grey) and darkens it about a third, like the variant picked in Design/shade-lab (blur, ×1.3 saturation,
/// 30 % black); Core Image background filters do not blur the player's video. Always active: a material left to
/// follow the window goes flat grey while the window is not the key one.
private struct ToolbarFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> FrostView {
        let view = FrostView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: FrostView, context: Context) {}

    /// Takes no clicks: the toolbar above it drags the window and holds the buttons.
    final class FrostView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
