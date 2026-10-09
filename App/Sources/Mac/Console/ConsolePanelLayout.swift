#if os(macOS)
import SwiftUI

/// Width of the «Пульт» panel on the right (the new training / the session readout) and the toolbar above it.
///
/// The panel is resized by its edge and folds away into «Только камера» when dragged past its narrowest. The toolbar
/// follows it: the panel's buttons (recording, sound, history…) sit over the panel at the window's edge, the camera's
/// group always on the camera's side of the panel's edge. The toolbar places items from the window's edge, so a
/// spacer item between the two groups as wide as the gap they leave decides where the camera's group lands; when the
/// panel's buttons don't fit over it with their titles, they drop the titles.
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

    /// The toolbar's own room around an item (macOS 26: 8 pt before it, 10 pt after), and the gap kept on each side
    /// of the panel's edge.
    static let itemSpacing: CGFloat = 18
    static let edgeInset: CGFloat = 8

    /// Width of the spacer item that puts the camera's group right before the panel's edge (`edge` in window
    /// coordinates). `buttonsWidth` is how much of the toolbar the panel's buttons take from the window's edge: the
    /// toolbar places them from there, so they stay put when the spacer changes, and their width doesn't change with
    /// the window's — a resize moves the spacer in the same layout pass as the panel, without waiting for the toolbar
    /// to be read again. (The spacer's own frame is no anchor: SwiftUI lays a wider spacer out centred in its old item
    /// before the toolbar resizes the item.)
    static func spacerWidth(buttonsWidth: CGFloat?, edge: CGFloat?, window: CGFloat) -> CGFloat {
        guard let buttonsWidth = plausible(buttonsWidth, window: window), let edge else { return 1 }
        return max(1, window - buttonsWidth - itemSpacing - (edge - edgeInset))
    }

    /// The first layout passes report items at the window's left: not yet where they will be.
    static func plausible(_ buttonsWidth: CGFloat?, window: CGFloat) -> CGFloat? {
        guard let buttonsWidth, window > 0, buttonsWidth > 0, buttonsWidth < window / 2 else { return nil }
        return buttonsWidth
    }

    /// Whether the panel's buttons fit over the panel. `buttonsWidth`: from their left end to the window's edge.
    static func fits(buttonsWidth: CGFloat, edge: CGFloat, window: CGFloat) -> Bool {
        window - buttonsWidth >= edge + edgeInset
    }
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
        .help(canFold ? "Потяните, чтобы изменить ширину; до упора вправо — только камера" : "Потяните, чтобы изменить ширину")
        .accessibilityHidden(true)
    }
}

/// Lives in the toolbar's spacer item and reads from AppKit where the toolbar items around it are: how much of the
/// toolbar the panel's buttons (the items after the spacer) take from the window's edge, and where the camera's group
/// (the items before it) ends. SwiftUI reports a toolbar item's place only when its size changes, and the first of the
/// panel's buttons moves without resizing when those after it change (titles dropped, «Завершить» appears): its
/// reported place went stale and the camera's group ran over the panel's edge. Read after every update of the item, as
/// the toolbar settles, and whenever AppKit lays the toolbar out again by itself (the window back from the Dock).
/// In full screen the toolbar moves into a window of its own (`NSToolbarFullScreenWindow`, without a `toolbar`): the
/// window the toolbar belongs to is found among the app's windows and places are compared on the screen.
struct ToolbarNeighboursProbe: NSViewRepresentable {
    /// Anything whose change may move the items (the probe re-reads on every update).
    var token: Int
    var onRead: (_ buttonsWidth: CGFloat, _ groupMaxX: CGFloat?) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onRead = onRead
        view.scheduleReads()
    }

    final class ProbeView: NSView {
        var onRead: ((CGFloat, CGFloat?) -> Void)?
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
            guard let buttonsMinX = frames(items[(index + 1)...]).map(\.minX).min() else { return }
            let frame = owner.window.frame
            onRead?(frame.maxX - buttonsMinX, frames(items[..<index]).map(\.maxX).max().map { $0 - frame.minX })
        }
    }
}

/// Title and icon, or the icon alone when the toolbar over the panel is short of room.
struct ToolbarFitLabelStyle: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}
#endif
