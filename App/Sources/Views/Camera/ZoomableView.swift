import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the owner framed: the part of the picture kept in view — its middle and how much of the picture's width and
/// height (0…1) it spans. An area of another size (the details open, the trainer's text, the phone on its side) shows
/// at least all of it: zoomed in as far as that allows, never further, so the app crops nothing the owner kept. The
/// iPhone keeps one per camera (`AppSettings.cameraFraming`).
struct CameraFraming: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

/// Zoom and pan of the camera picture. Shared by the gestures and (on the Mac) the View menu.
@MainActor
@Observable
final class ZoomState {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    /// Size of the zoomed area; set by `ZoomableView`.
    private(set) var viewport: CGSize = .zero
    /// Width over height of the picture when it is letterboxed in the area (the iPhone: the area runs from the top bar
    /// to the card, the picture fits in it); nil: the content fills the area itself (the Mac's player).
    private(set) var aspect: CGFloat?
    /// The iPhone: the last framing zoomed in, and whether it is on. A double tap on the whole picture goes back to
    /// it; it is saved per camera when a gesture ends, and a new size of the area shows it anew.
    private(set) var memory = Memory()
    /// Keeps `memory` (the iPhone); the Mac's double click zooms in where it is.
    let remembers: Bool

    struct Memory: Equatable {
        var framing: CameraFraming?
        var isOn = false
    }

    static let maxScale: CGFloat = 5
    /// One ⌘= / ⌘− step and the double tap / double click target.
    static let step: CGFloat = 1.5
    static let smartScale: CGFloat = 2.5

    @ObservationIgnored private var baseScale: CGFloat = 1
    @ObservationIgnored private var baseOffset: CGSize = .zero

    init(remembers: Bool = false) {
        self.remembers = remembers
    }

    var isZoomed: Bool { scale > 1.01 }

    /// The scale at which the picture covers the whole area (1 when it already does).
    var fillScale: CGFloat {
        let picture = picture
        guard picture.width > 0, picture.height > 0 else { return 1 }
        return max(viewport.width / picture.width, viewport.height / picture.height)
    }

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

    /// The whole picture. The iPhone keeps the framing for a double tap.
    func reset() {
        scale = 1
        offset = .zero
        baseScale = 1
        baseOffset = .zero
        commit()
    }

    /// Double tap / double click: back to the whole picture; from it, to the framing left last (the iPhone) or in at
    /// that point — as far as fills the area when the picture is letterboxed in it.
    func toggle(at anchor: CGPoint) {
        if isZoomed {
            scale = 1
            offset = .zero
        } else if remembers, let framing = memory.framing, scale(for: framing) > 1.01 {
            show(framing)
        } else if aspect != nil {
            let fill = fillScale
            zoom(to: fill < 1.4 ? 2 : min(fill, Self.smartScale), anchor: anchor)
        } else {
            zoom(to: Self.smartScale, anchor: anchor)
        }
        settle()
    }

    /// «Приблизить» ↔ «Весь кадр» (`CameraZoomButton`), there whatever the area's shape: back to the whole picture; from
    /// it, to the framing left last — the same one a double tap brings back — where this area shows it closer; else as
    /// far as fills a letterboxed area, and where the picture fills it already or nearly (a tall card, the accessibility
    /// text sizes) twice as close — round the middle of the framing left last (where the owner looked), or a little
    /// below the picture's middle where that framing kept its whole height: the camera looks down at the door, the dog
    /// is on the floor (design council, round 10: the button was gone where the picture filled the area).
    func toggleZoomIn() {
        if isZoomed {
            scale = 1
            offset = .zero
        } else if remembers, let framing = memory.framing, scale(for: framing) > 1.01 {
            show(framing)
        } else {
            let fill = aspect != nil ? fillScale : 1
            let framing = remembers ? memory.framing : nil
            center(scale: fill < 1.4 ? 2 : fill, x: framing?.x ?? 0.5,
                   y: framing.flatMap { $0.height < 0.9 ? $0.y : nil } ?? 0.6)
        }
        settle()
    }

    /// `scale` with the picture's point (`x`, `y`, 0…1) in the middle, kept as the camera's framing (DEBUG
    /// `--demo-zoom`).
    func frame(scale target: CGFloat, x: CGFloat, y: CGFloat) {
        center(scale: target, x: x, y: y)
        settle()
    }

    /// `scale` with the picture's point (`x`, `y`, 0…1) in the middle where the picture's edges allow.
    private func center(scale target: CGFloat, x: CGFloat, y: CGFloat) {
        let picture = picture
        scale = min(Self.maxScale, max(1, target))
        offset = clamped(CGSize(width: -(x - 0.5) * picture.width * scale, height: -(y - 0.5) * picture.height * scale))
    }

    /// The camera's remembered framing: zoomed in there when it was left so, else the whole picture.
    func restore(_ memory: Memory) {
        self.memory = memory
        if memory.isOn, let framing = memory.framing {
            show(framing)
        } else {
            scale = 1
            offset = .zero
        }
        baseScale = scale
        baseOffset = offset
    }

    /// After a gesture: a hair above 1× is 1×, a hair off filling the area fills it.
    func settle() {
        if aspect != nil, isZoomed {
            let fill = fillScale
            if fill > 1.05, abs(scale - fill) < fill * 0.06 { set(scale: fill, from: scale, offset: offset, anchor: nil) }
        }
        if !isZoomed {
            scale = 1
            offset = .zero
        }
        baseScale = scale
        baseOffset = offset
        commit()
    }

    /// The area's size and the picture's aspect, from `ZoomableView`. The iPhone shows its framing in the new area;
    /// elsewhere the zoom stays as it is.
    func layout(viewport newViewport: CGSize, aspect newAspect: CGFloat?) {
        guard newViewport != viewport || newAspect != aspect else { return }
        viewport = newViewport
        aspect = newAspect
        if remembers, memory.isOn, let framing = memory.framing {
            show(framing)
        } else {
            offset = clamped(offset)
        }
        baseScale = scale
        baseOffset = offset
    }

    /// Where the picture shows in an area of `size`: its zoomed frame cut to the area. The stream's state and the corner
    /// buttons sit in it, not in the black around a letterboxed picture.
    func visibleRect(in size: CGSize, aspect: CGFloat?) -> CGRect {
        let visible = pictureFrame(in: size, aspect: aspect).intersection(CGRect(origin: .zero, size: size))
        return visible.isNull ? CGRect(origin: .zero, size: size) : visible
    }

    /// The whole zoomed picture in an area of `size`, past its edges too (`ZoomableView.overflows`).
    func pictureFrame(in size: CGSize, aspect: CGFloat?) -> CGRect {
        let picture = Self.fitted(aspect, in: size)
        let width = picture.width * scale, height = picture.height * scale
        return CGRect(x: (size.width - width) / 2 + offset.width, y: (size.height - height) / 2 + offset.height,
                      width: width, height: height)
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

    /// The picture at 1×: fitted into the area.
    private var picture: CGSize { Self.fitted(aspect, in: viewport) }

    private static func fitted(_ aspect: CGFloat?, in area: CGSize) -> CGSize {
        guard let aspect, aspect > 0, area.width > 0, area.height > 0 else { return area }
        return area.width / area.height > aspect ? CGSize(width: area.height * aspect, height: area.height)
                                                 : CGSize(width: area.width, height: area.width / aspect)
    }

    /// The part of the picture on screen now, in the picture's own 0…1.
    private var currentFraming: CameraFraming? {
        let picture = picture
        guard picture.width > 0, picture.height > 0 else { return nil }
        let width = picture.width * scale, height = picture.height * scale
        let frame = CGRect(x: (viewport.width - width) / 2 + offset.width, y: (viewport.height - height) / 2 + offset.height,
                           width: width, height: height)
        let visible = frame.intersection(CGRect(origin: .zero, size: viewport))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CameraFraming(x: (visible.midX - frame.minX) / width, y: (visible.midY - frame.minY) / height,
                             width: visible.width / width, height: visible.height / height)
    }

    /// As far in as shows all of `framing` in this area.
    private func scale(for framing: CameraFraming) -> CGFloat {
        let picture = picture
        guard picture.width > 0, picture.height > 0, framing.width > 0, framing.height > 0 else { return 1 }
        let fits = min(viewport.width / (framing.width * picture.width), viewport.height / (framing.height * picture.height))
        return min(Self.maxScale, max(1, fits))
    }

    /// `framing` in this area, its middle in the middle where the picture's edges allow. Before the area has a size
    /// the whole picture; `layout` shows it then.
    private func show(_ framing: CameraFraming) {
        let picture = picture
        guard picture.width > 0, picture.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        scale = scale(for: framing)
        offset = clamped(CGSize(width: -(framing.x - 0.5) * picture.width * scale,
                                height: -(framing.y - 0.5) * picture.height * scale))
    }

    private func commit() {
        guard remembers else { return }
        if isZoomed, let framing = currentFraming {
            memory = Memory(framing: framing, isOn: true)
        } else {
            memory.isOn = false
        }
    }

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

    /// Keeps the zoomed picture covering the area where it is larger than the area, centred where it is not.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let picture = picture
        let maxX = max(0, (picture.width * scale - viewport.width) / 2)
        let maxY = max(0, (picture.height * scale - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }
}

extension ZoomState.Memory {
    /// As kept in the settings: x, y, width, height, on (1/0).
    init?(saved: [Double]?) {
        guard let saved, saved.count == 5, (0.01...1).contains(saved[2]), (0.01...1).contains(saved[3]) else { return nil }
        self.init(framing: CameraFraming(x: saved[0], y: saved[1], width: saved[2], height: saved[3]), isOn: saved[4] > 0)
    }

    var saved: [Double]? {
        framing.map { [Double($0.x), Double($0.y), Double($0.width), Double($0.height), isOn ? 1 : 0] }
    }
}

/// Zoomable camera picture. iPhone: pinch, drag when zoomed, double tap to zoom in there (or to the framing left last)
/// and again back to the whole picture. Mac: trackpad pinch around the pointer, drag or two-finger scroll to pan,
/// ⌘/⌥ + wheel for a mouse, double click or two-finger double tap to zoom in there and again back to 1×. The content
/// itself gets no events, so this works over a WKWebView.
///
/// `aspect`: the picture is letterboxed in the area (fit, no crop) and zooms within the whole area, filling it once
/// it is large enough; `chrome` (the stream's state, corner buttons) is laid over the part of the picture on screen,
/// unscaled.
struct ZoomableView<Content: View, Chrome: View>: View {
    private let external: ZoomState?
    private let contentZooms: Bool
    private let aspect: CGFloat?
    private let showsZoomPill: Bool
    private let overflows: Bool
    private let content: Content
    private let chrome: Chrome
    @State private var own = ZoomState()

    /// `zoom`: pass one to drive the zoom from elsewhere (menu commands, a camera's remembered framing); otherwise the
    /// view keeps its own.
    /// `contentZooms`: the content is not scaled here but gets the `ZoomState` in its environment and shows the
    /// zoom itself — the Mac's web player: WebKit pushes the page of a WKWebView down when its scaled-up frame
    /// runs under the window's toolbar, so the picture there zooms in the web view's layer instead (`PlayerWebView`).
    /// `showsZoomPill`: off where the chrome has its own way back (the training's `ZoomFillButton`).
    /// `overflows`: the zoomed picture is not cut at the area's edges: what of it lies past them shows round the area,
    /// behind what is there (the iPhone's bar and card, the Mac's toolbar) instead of the black. The content must be
    /// the picture alone, no black round it (sized to its aspect), and the caller draws the area under its neighbours
    /// and cuts it where it must (the screen, the window's camera column). The zoom still frames the area: gestures,
    /// panning and the chrome keep to it.
    init(zoom: ZoomState? = nil, contentZooms: Bool = false, aspect: CGFloat? = nil, showsZoomPill: Bool = true,
         overflows: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder chrome: () -> Chrome) {
        external = zoom
        self.contentZooms = contentZooms
        self.aspect = aspect
        self.showsZoomPill = showsZoomPill
        self.overflows = overflows
        self.content = content()
        self.chrome = chrome()
    }

    private struct LayoutKey: Equatable {
        var size: CGSize
        var aspect: CGFloat?
        var zoom: ObjectIdentifier
    }

    var body: some View {
        let zoom = external ?? own
        GeometryReader { geometry in
            let visible = zoom.visibleRect(in: geometry.size, aspect: aspect)
            ZStack {
                content
                    .allowsHitTesting(false)
                    // Always the same modifier chain: an `if` here would change the view identity and recreate the web view.
                    .scaleEffect(contentZooms ? 1 : zoom.scale)
                    .offset(contentZooms ? .zero : zoom.offset)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .environment(contentZooms ? zoom : nil)

                ZoomInput(zoom: zoom)

                ZStack(alignment: .topTrailing) {
                    chrome
                    if showsZoomPill && zoom.isZoomed {
                        Button {
                            withAnimation(.spring(response: 0.3)) { zoom.reset() }
                        } label: {
                            Pill(text: String(format: "%.1f×", zoom.scale), systemImage: Self.wholePictureIcon)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .padding(10)
                        #if os(macOS)
                        .help("Без увеличения · ⌘0")
                        #else
                        // The words of the training's corner button for the same thing (`CameraZoomButton`).
                        .accessibilityLabel("Весь кадр")
                        .accessibilityShowsLargeContentViewer {
                            Label("Весь кадр", systemImage: Self.wholePictureIcon)
                        }
                        #endif
                    }
                }
                // The pill in the corner even when the chrome has nothing to fill the frame with.
                .frame(width: visible.width, height: visible.height, alignment: .topTrailing)
                .position(x: visible.midX, y: visible.midY)
            }
            // A switch to the other camera's state, too: it may never have been laid out.
            .onChange(of: LayoutKey(size: geometry.size, aspect: aspect, zoom: ObjectIdentifier(zoom)), initial: true) { _, key in
                zoom.layout(viewport: key.size, aspect: key.aspect)
            }
        }
        .modifier(ClipsUnless(overflows: overflows))
    }

    /// The pill's sign: on the iPhone the training's «Весь кадр» one (`CameraZoomButton`); the Mac's as its View menu's
    /// «Без увеличения».
    private static var wholePictureIcon: String {
        #if os(macOS)
        "arrow.down.right.and.arrow.up.left"
        #else
        CameraZoomButton.wholePictureIcon
        #endif
    }
}

extension ZoomableView where Chrome == EmptyView {
    init(zoom: ZoomState? = nil, contentZooms: Bool = false, aspect: CGFloat? = nil, overflows: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(zoom: zoom, contentZooms: contentZooms, aspect: aspect, overflows: overflows, content: content,
                  chrome: { EmptyView() })
    }
}

/// The area's own cut, unless the zoomed picture may run past it (`ZoomableView.overflows`; fixed for a view, so the
/// branch never switches and the player is never recreated).
private struct ClipsUnless: ViewModifier {
    let overflows: Bool

    func body(content: Content) -> some View {
        if overflows {
            content
        } else {
            content.clipped()
        }
    }
}

/// Keeps a camera's `ZoomState` in step with the framing remembered for it: restored when the camera (its stream)
/// changes or the app starts, saved when a gesture or a double tap ends.
struct RememberedFraming: ViewModifier {
    let zoom: ZoomState
    /// The stream's name; empty without a camera.
    let camera: String
    let settings: AppSettings

    func body(content: Content) -> some View {
        content
            .onChange(of: camera, initial: true) { _, camera in
                zoom.restore(ZoomState.Memory(saved: settings.cameraFraming[camera]) ?? ZoomState.Memory())
            }
            .onChange(of: zoom.memory) { _, memory in
                guard !camera.isEmpty, settings.cameraFraming[camera] != memory.saved else { return }
                settings.cameraFraming[camera] = memory.saved
            }
    }
}

/// A button in a corner of the camera picture, one form on every screen: dark and translucent, the picture shows
/// round it; 40 pt drawn, 44 pt to touch. The corner's own action — ⤢ «Только камера» before a training and after it,
/// «Приблизить» ↔ «Весь кадр» during one — is its sign and its words in a capsule (design council, round 10: words in
/// the training, the sign alone on the main screen, two forms of one button); a second one beside it (✥ «Повернуть
/// камеру») and every one at the accessibility text sizes is the sign alone in a circle, the words in the Large
/// Content Viewer on a long press (round 9: the words in AX type took half the picture's width and lay on the dog).
/// VoiceOver hears the same words.
struct CameraCornerButton: View {
    let systemImage: String
    let title: String
    /// A quiet note after the words («1.9×»).
    var note: String? = nil
    /// Off: the sign alone at every text size.
    var showsTitle = true
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            if showsTitle && !typeSize.isAccessibilitySize {
                capsule
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.55), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .padding(2)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }

    private var capsule: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            if let note {
                Text(note)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(2)
        .contentShape(Rectangle())
    }
}

/// The training's way to look closer or at all of it, without knowing the double tap: «Приблизить» over the whole
/// picture, «Весь кадр 1.9×» once zoomed in (the `ZoomableView` pill, moved down into the picture's corner with the
/// other corner buttons). Always there, whatever the card's height or the text size (`ZoomState.toggleZoomIn`: the
/// framing left last, the picture filling the area, or twice as close). A magnifier, not ⤢: the main screen's ⤢ is
/// «Только камера». The action is the label, the scale only a quiet note after it. The whole picture stays the
/// default: nothing is cropped until the owner asks (design council, round 10: «Заполнить» named the picture's
/// placement, the owner wants the dog closer).
struct CameraZoomButton: View {
    let zoom: ZoomState
    /// Off on a small picture (a 375-pt iPhone): the sign alone, so the words don't lie over the dog.
    var showsTitle = true

    static let zoomInIcon = "plus.magnifyingglass"
    static let wholePictureIcon = "minus.magnifyingglass"

    var body: some View {
        let zoomed = zoom.isZoomed
        CameraCornerButton(systemImage: zoomed ? Self.wholePictureIcon : Self.zoomInIcon,
                           title: zoomed ? String(localized: "Весь кадр") : String(localized: "Приблизить"),
                           note: zoomed ? String(format: "%.1f×", zoom.scale) : nil, showsTitle: showsTitle) {
            withAnimation(.spring(response: 0.3)) { zoom.toggleZoomIn() }
        }
    }
}

#if os(iOS)
/// Pinch around the fingers, drag when zoomed, double tap to the remembered framing (or in there) / back to 1×.
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
            // Simultaneous: when zoomed, the drag above starts on touch down and would swallow the taps.
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                withAnimation(.spring(response: 0.3)) { zoom.toggle(at: tap.location) }
            })
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
        withAnimation(.spring(response: 0.3)) { zoom.toggle(at: point(event)) }
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
            withAnimation(.spring(response: 0.3)) { zoom.toggle(at: point(event)) }
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
