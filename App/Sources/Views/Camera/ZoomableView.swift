import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Zoom and pan of the camera picture. Shared by the gestures and (on the Mac) the View menu.
@MainActor
@Observable
final class ZoomState {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    /// Size of the zoomed area; set by `ZoomableView`.
    var viewport: CGSize = .zero

    static let maxScale: CGFloat = 5
    /// One ⌘= / ⌘− step and the smart-magnify (two-finger double tap) target.
    static let step: CGFloat = 1.5
    static let smartScale: CGFloat = 2.5

    @ObservationIgnored private var baseScale: CGFloat = 1
    @ObservationIgnored private var baseOffset: CGSize = .zero

    var isZoomed: Bool { scale > 1.01 }

    /// Multiplies the scale keeping `anchor` (a viewport point, top-left origin) in place; the centre without one.
    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        set(scale: scale * factor, from: scale, offset: offset, anchor: anchor)
    }

    func zoom(to target: CGFloat, anchor: CGPoint? = nil) {
        set(scale: target, from: scale, offset: offset, anchor: anchor)
    }

    func pan(by delta: CGSize) {
        guard isZoomed else { return }
        offset = clamped(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    func reset() {
        scale = 1
        offset = .zero
        baseScale = 1
        baseOffset = .zero
    }

    /// After a gesture: a hair above 1× is 1×.
    func settle() {
        if !isZoomed { reset() }
        baseScale = scale
        baseOffset = offset
    }

    // MARK: Continuous gestures (relative to where they began)

    func magnify(_ magnification: CGFloat, anchor: CGPoint?) {
        set(scale: baseScale * magnification, from: baseScale, offset: baseOffset, anchor: anchor)
    }

    func drag(_ translation: CGSize) {
        guard isZoomed else { return }
        offset = clamped(CGSize(width: baseOffset.width + translation.width, height: baseOffset.height + translation.height))
    }

    // MARK: Math

    /// The content is scaled around the viewport centre, then shifted by `offset`; a viewport point `p` shows
    /// content point `(p − centre − offset) / scale`. Keeping that point under `anchor` while the scale changes
    /// gives the new offset.
    private func set(scale target: CGFloat, from oldScale: CGFloat, offset oldOffset: CGSize, anchor: CGPoint?) {
        let newScale = min(Self.maxScale, max(1, target))
        var newOffset = oldOffset
        if let anchor, viewport != .zero, oldScale > 0 {
            let x = anchor.x - viewport.width / 2
            let y = anchor.y - viewport.height / 2
            newOffset = CGSize(width: x - (x - oldOffset.width) * newScale / oldScale,
                               height: y - (y - oldOffset.height) * newScale / oldScale)
        } else if oldScale > 0 {
            newOffset = CGSize(width: oldOffset.width * newScale / oldScale, height: oldOffset.height * newScale / oldScale)
        }
        scale = newScale
        offset = clamped(newOffset)
    }

    /// Keeps the zoomed content covering the viewport.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let maxX = viewport.width * (scale - 1) / 2
        let maxY = viewport.height * (scale - 1) / 2
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }
}

/// Zoomable camera picture. iPhone: pinch, drag when zoomed, double tap to reset. Mac: trackpad pinch
/// around the pointer, two-finger double tap, drag or two-finger scroll to pan, ⌘/⌥ + wheel for a mouse,
/// double click to reset. The content itself gets no events, so this works over a WKWebView.
struct ZoomableView<Content: View>: View {
    private let external: ZoomState?
    private let content: Content
    @State private var own = ZoomState()

    /// `zoom`: pass one to drive the zoom from elsewhere (menu commands); otherwise the view keeps its own.
    init(zoom: ZoomState? = nil, @ViewBuilder content: () -> Content) {
        external = zoom
        self.content = content()
    }

    var body: some View {
        let zoom = external ?? own
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                content
                    .allowsHitTesting(false)
                    // Always the same modifier chain: an `if` here would change the view identity and recreate the web view.
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                ZoomInput(zoom: zoom)

                if zoom.isZoomed {
                    Button {
                        withAnimation(.spring(response: 0.3)) { zoom.reset() }
                    } label: {
                        Pill(text: String(format: "%.1f×", zoom.scale), systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(10)
                    #if os(macOS)
                    .help("Без увеличения · ⌘0")
                    #endif
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in zoom.viewport = size }
        }
        .clipped()
    }
}

#if os(iOS)
/// Pinch around the fingers, drag when zoomed, double tap to reset.
private struct ZoomInput: View {
    let zoom: ZoomState

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { zoom.magnify($0.magnification, anchor: $0.startLocation) }
                    .onEnded { _ in withAnimation(.spring(response: 0.3)) { zoom.settle() } }
                    .simultaneously(with: DragGesture(minimumDistance: zoom.isZoomed ? 0 : 1_000)
                        .onChanged { zoom.drag($0.translation) }
                        .onEnded { _ in zoom.settle() })
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) { zoom.reset() }
            }
    }
}
#else
/// Trackpad and mouse input in AppKit terms: the view sits on top of the player and takes the events.
private struct ZoomInput: NSViewRepresentable {
    let zoom: ZoomState

    func makeNSView(context: Context) -> ZoomInputView {
        let view = ZoomInputView()
        view.zoom = zoom
        return view
    }

    func updateNSView(_ view: ZoomInputView, context: Context) {
        view.zoom = zoom
    }
}

final class ZoomInputView: NSView {
    var zoom: ZoomState?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func magnify(with event: NSEvent) {
        guard let zoom else { return super.magnify(with: event) }
        zoom.zoom(by: 1 + event.magnification, anchor: point(event))
        if event.phase == .ended || event.phase == .cancelled {
            withAnimation(.spring(response: 0.3)) { zoom.settle() }
        }
    }

    /// Two-finger double tap, as in Safari and Preview.
    override func smartMagnify(with event: NSEvent) {
        guard let zoom else { return super.smartMagnify(with: event) }
        withAnimation(.spring(response: 0.3)) {
            if zoom.isZoomed { zoom.reset() } else { zoom.zoom(to: ZoomState.smartScale, anchor: point(event)) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let zoom else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // Mouse wheel zoom: a notch is ~1 line, a trackpad gives points.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom.zoom(by: exp(delta * 0.01), anchor: point(event))
            if event.phase == .ended || event.momentumPhase == .ended { zoom.settle() }
        } else if zoom.isZoomed {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            zoom.pan(by: CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            zoom.settle()
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let zoom else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            withAnimation(.spring(response: 0.3)) { zoom.reset() }
            return
        }
        dragging = zoom.isZoomed
        if dragging { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let zoom else { return }
        zoom.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        NSCursor.pop()
        zoom?.settle()
    }
}
#endif
