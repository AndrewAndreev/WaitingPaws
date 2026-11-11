#if os(macOS)
import SwiftUI

/// Width of the «Пульт» panel on the right (the new training / the session readout) and the toolbar above it.
///
/// The panel is resized by its edge and folds away into «Только камера» when dragged past its narrowest. The toolbar
/// follows it: the panel's groups (recording, sound, history…) sit over the panel at the window's edge, the camera's
/// island always on the camera's side of the panel's edge. The toolbar places items from the window's edge, so a clear
/// room after the island, as wide as the gap the groups leave, decides where the island lands; when the groups don't
/// fit over the panel with their words, the words drop one at a time.
enum ConsolePanelLayout {
    /// Enough for the timer, the two step buttons and «Начать тренировку и запись ⌘↩».
    static let minWidth: CGFloat = 340
    static let defaultWidth: CGFloat = 380
    static let maxWidth: CGFloat = 720
    /// The camera keeps at least this much of the window.
    static let minCameraWidth: CGFloat = 420
    /// Dragging the edge this far past `minWidth` folds the panel away.
    static let foldDistance: CGFloat = 80

    /// The panel's edge (`TrainingPanelEdge`).
    static let edgeWidth: CGFloat = 6

    /// The panel folding away and coming back (the header's shadows follow its edge: `HeaderShadowSweep`).
    static let foldDuration = 0.35 * slowMotion
    static var foldAnimation: Animation { .smooth(duration: foldDuration) }
    /// `--demo-slow=<factor>`: the panel's fold that many times slower (recording the header's shadows on video).
    static let slowMotion: Double = {
        #if DEBUG
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-slow=") })?.dropFirst(12),
           let factor = Double(raw), factor > 0 { return factor }
        #endif
        return 1
    }()

    static func widthRange(window: CGFloat) -> ClosedRange<CGFloat> {
        guard window > 0 else { return minWidth...maxWidth }
        return minWidth...max(minWidth, min(maxWidth, window - minCameraWidth))
    }

    /// The width that leaves the camera just the picture's width at its height, with no black above and below: the
    /// panel's width until its edge is dragged. A narrower window gets `minWidth` and the bars (the caller clamps to
    /// `widthRange`). `video` is nil until the player knows it: most cameras are 16:9.
    static func fittedWidth(window: CGFloat, cameraHeight: CGFloat, video: CGSize?) -> CGFloat {
        guard window > 0, cameraHeight > 0 else { return defaultWidth }
        let aspect = video.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 16 / 9
        return window - edgeWidth - cameraHeight * aspect
    }

    /// The gap kept on each side of the panel's edge: the camera's island ends this much before it, the panel's groups
    /// start no closer after it.
    static let edgeInset: CGFloat = 8
    /// Until the toolbar is read: its room between the camera's island's item and the panel's first group, and around
    /// the panel's groups (the spacers between them and the margin after the last).
    static let defaultItemGap: CGFloat = 8
    static func defaultButtonsGaps(groups: Int) -> CGFloat { 9.5 + CGFloat(groups - 1) * 17 }
    /// Without the panel the island keeps this much more from the panel's groups, as far as they are from each other.
    static let clipModePad: CGFloat = 8

    /// The clear room after the camera's island, in its own toolbar item, that puts the island right before the panel's
    /// edge (`edge` in window coordinates). Not a spacer item of its own: AppKit keeps a toolbar item at least 36 pt
    /// wide, and the island then stopped short of the edge or, wider than the room the panel's groups left, ran over it.
    /// `buttonsWidth` is how much of the toolbar the panel's groups take from the window's edge (their widths are known,
    /// `PanelButtons`, and the toolbar's gaps are read once): the toolbar places items from there, so a resize or a word
    /// dropped moves the island in the same layout pass as the panel, without waiting for the toolbar to be read again.
    /// `itemGap`: the toolbar's room between the island's item and the first group's (read from the toolbar).
    static func islandPad(buttonsWidth: CGFloat, itemGap: CGFloat, edge: CGFloat?, window: CGFloat) -> CGFloat {
        guard let edge, window > 0 else { return clipModePad }
        return max(0, window - buttonsWidth - itemGap - (edge - edgeInset))
    }

    /// Whether the panel's groups fit over the panel. `buttonsWidth`: from their left end to the window's edge.
    static func fits(buttonsWidth: CGFloat, edge: CGFloat, window: CGFloat) -> Bool {
        window - buttonsWidth >= edge + edgeInset
    }

    /// How many of the panel's words drop (`PanelButtons.words`, in order) for the groups to fit over the panel: the
    /// fewest. A word comes back only with 2 pt to spare, so a width right at the limit doesn't flip back and forth.
    static func foldLevel(current: Int, buttons: PanelButtons, gaps: CGFloat, edge: CGFloat, window: CGFloat) -> Int {
        let last = buttons.words.count
        return (0...last).first { level in
            let slack: CGFloat = level < current ? 2 : 0
            return fits(buttonsWidth: buttons.width(level: level) + gaps + slack, edge: edge, window: window)
        } ?? last
    }
}

/// Where the toolbar's items are, read from AppKit (`ToolbarNeighboursProbe`). Window coordinates.
struct ToolbarPlaces: Equatable {
    /// From the panel's first group to the window's edge.
    var buttonsWidth: CGFloat
    /// Of that, what isn't the groups themselves: the spacers between them and the margin after the last.
    var buttonsGaps: CGFloat
    /// Where the camera's island ends.
    var groupMaxX: CGFloat
    /// The toolbar's room between the island's item (its clear room after the island included) and the panel's first
    /// group.
    var itemGap: CGFloat?
    /// The panel's groups, left to right.
    var groups: [ClosedRange<CGFloat>]
}

/// The panel's left edge: a line with a few points to grab. Drag to resize; past the narrowest width the panel
/// folds away (`onFold`) when that is allowed.
struct TrainingPanelEdge: View {
    @Binding var width: Double
    var range: ClosedRange<CGFloat>
    var canFold: Bool
    var onFold: () -> Void
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: ConsolePanelLayout.edgeWidth)
            .overlay(alignment: .leading) { Divider() }
            // A background, not a view: like the panel's own, it runs up under the toolbar, so the panel's colour
            // starts at the same edge there as below.
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .gesture(
            // Window coordinates: the edge moves under the pointer while dragging.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    // From the width on screen: the stored one may be wider than a narrow window allows.
                    let start = startWidth ?? min(max(CGFloat(width), range.lowerBound), range.upperBound)
                    startWidth = start
                    let proposed = start - drag.translation.width
                    if canFold, proposed < range.lowerBound - ConsolePanelLayout.foldDistance {
                        // Opens again at the width it had before this drag.
                        width = Double(start)
                        startWidth = nil
                        onFold()
                        return
                    }
                    width = Double(min(max(proposed, range.lowerBound), range.upperBound))
                }
                .onEnded { _ in startWidth = nil }
        )
        .help(canFold ? "Drag to resize; all the way to the right for camera only" : "Drag to resize")
        .accessibilityHidden(true)
    }
}

/// Lives under the camera's island and reads from AppKit where the toolbar items around it are: how much of the toolbar
/// the panel's groups (the items after the island's) take from the window's edge and how much of that is the toolbar's
/// own gaps, where the island ends and the toolbar's room between its item and the groups. SwiftUI reports a toolbar
/// item's place only when its size changes, and the first of the panel's groups moves without resizing when those after
/// it change (words dropped, «Завершить» appears): its reported place went stale and the camera's group ran over the
/// panel's edge. Read after every update of the item, as the toolbar settles, and whenever AppKit lays the toolbar out
/// again by itself (the window back from the Dock). In full screen the toolbar moves into a window of its own
/// (`NSToolbarFullScreenWindow`, without a `toolbar`): the window the toolbar belongs to is found among the app's
/// windows and places are compared on the screen.
struct ToolbarNeighboursProbe: NSViewRepresentable {
    /// Anything whose change may move the items (the probe re-reads on every update).
    var token: Int
    var onRead: (ToolbarPlaces) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onRead = onRead
        view.scheduleReads()
    }

    final class ProbeView: NSView {
        var onRead: ((ToolbarPlaces) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        /// The toolbar's item views (`NSToolbarItemViewer`s), watched for moves.
        private var watched: [(view: Weak, observer: NSObjectProtocol)] = []
        /// Bumped by every round of reads: only the latest round reads again later.
        private var round = 0

        final class Weak {
            weak var view: NSView?
            init(_ view: NSView) { self.view = view }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
            // The toolbar's own window in full screen doesn't resize or go to the Dock: the owner's events too.
            var windows = [window].compactMap { $0 }
            if let owner = toolbarOwner()?.window, !windows.contains(where: { $0 === owner }) { windows.append(owner) }
            let names: [Notification.Name] = [NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification,
                                              NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
            windowObservers = windows.flatMap { window in
                names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleReads() }
                    }
                }
            }
            scheduleReads()
        }

        deinit {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            watched.forEach { NotificationCenter.default.removeObserver($0.observer) }
        }

        /// The window whose toolbar holds this item: the probe's own, or in full screen the one under the toolbar.
        private func toolbarOwner() -> (window: NSWindow, toolbar: NSToolbar)? {
            func holdsProbe(_ toolbar: NSToolbar) -> Bool {
                toolbar.items.contains { item in item.view.map { isDescendant(of: $0) } ?? false }
            }
            if let window, let toolbar = window.toolbar, holdsProbe(toolbar) { return (window, toolbar) }
            guard window != nil else { return nil }
            for candidate in NSApp.windows {
                if let toolbar = candidate.toolbar, holdsProbe(toolbar) { return (candidate, toolbar) }
            }
            return nil
        }

        /// Item views that move or resize (the toolbar laid out again) start another round of reads.
        private func watch(_ items: [NSToolbarItem]) {
            watched.removeAll { entry in
                guard entry.view.view == nil else { return false }
                NotificationCenter.default.removeObserver(entry.observer)
                return true
            }
            for viewer in items.compactMap({ $0.view?.superview }) where !watched.contains(where: { $0.view.view === viewer }) {
                viewer.postsFrameChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: viewer, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleReads() }
                }
                watched.append((Weak(viewer), observer))
            }
        }

        /// Now and over the next few hundred milliseconds: the toolbar lays items out after SwiftUI's update.
        func scheduleReads() {
            round += 1
            let current = round
            DispatchQueue.main.async { [weak self] in self?.read() }
            for delay in [0.05, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.round == current else { return }
                    self.read()
                }
            }
        }

        private func read() {
            guard let host = window, let owner = toolbarOwner(),
                  let index = owner.toolbar.items.firstIndex(where: { item in item.view.map { isDescendant(of: $0) } ?? false })
            else { return }
            let items = owner.toolbar.items
            watch(items)
            // On the screen: in full screen the items are in the toolbar's window over the owner. Items moved into the
            // overflow menu are in no window.
            func frames(_ slice: ArraySlice<NSToolbarItem>) -> [CGRect] {
                slice.compactMap { $0.view }.filter { $0.window === host }.map { host.convertToScreen($0.convert($0.bounds, to: nil)) }
            }
            // A crowded toolbar moves items into its overflow menu (in no window): nothing to measure the gaps by.
            guard items[(index + 1)...].allSatisfy({ $0.view == nil || $0.view?.window === host }) else { return }
            let buttons = frames(items[(index + 1)...])
            let frame = owner.window.frame
            // The first layout passes report items at the window's left: not yet where they will be.
            guard let buttonsMinX = buttons.map(\.minX).min(), frame.maxX - buttonsMinX < frame.width * 0.75 else { return }
            // The island's item: the island, then its clear room. Its own view lags a resize (SwiftUI lays a wider
            // item out centred in its old place), its viewer has the toolbar's width: as far in from the viewer's edge
            // as the first group's view is from its viewer's.
            let island = host.convertToScreen(convert(bounds, to: nil))
            let itemEnd: CGFloat? = {
                guard let viewer = items[index].view?.superview, let first = items[(index + 1)...].first(where: { $0.view != nil }),
                      let firstView = first.view, let firstViewer = firstView.superview, viewer.window === host else { return nil }
                let end = host.convertToScreen(viewer.convert(viewer.bounds, to: nil)).maxX
                return end - (firstViewer.bounds.width - firstView.frame.maxX)
            }()
            let buttonsWidth = frame.maxX - buttonsMinX
            #if DEBUG
            if CommandLine.arguments.contains("--demo-toolbar-log") {
                let views = items.map { item -> String in
                    guard let view = item.view else { return "·\(item.itemIdentifier.rawValue.suffix(12))" }
                    let viewer = view.superview
                    return String(format: "[%.1f+%.1f in %.1f+%.1f]", view.frame.minX, view.frame.width,
                                  viewer?.frame.minX ?? -1, viewer?.frame.width ?? -1)
                }
                print("[toolbar] items: \(views.joined(separator: " "))")
            }
            #endif
            onRead?(ToolbarPlaces(
                buttonsWidth: buttonsWidth,
                buttonsGaps: buttonsWidth - buttons.map(\.width).reduce(0, +),
                groupMaxX: island.maxX - frame.minX,
                itemGap: itemEnd.map { buttonsMinX - $0 },
                groups: buttons.map { ($0.minX - frame.minX)...($0.maxX - frame.minX) }))
        }
    }
}
#endif
